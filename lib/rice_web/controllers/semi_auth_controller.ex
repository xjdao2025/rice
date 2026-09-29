defmodule RiceWeb.SemiAuthController do
  @moduledoc """
  "Login with Semi" — the Authorization Code + PKCE flow.

  `login`    generates PKCE material, stashes `state` + `code_verifier` in the
             signed session, and redirects the browser to Semi's authorize page.
  `callback` (the registered redirect_uri, `/callback`) verifies `state`, swaps
             the code for tokens, fetches userinfo, and stores the resulting
             identity in the session. Semi tokens are deliberately NOT persisted
             in the browser cookie (the access token is long-lived); only the
             userinfo claims are kept.
  `logout`   clears the Semi identity from the session.
  """
  use RiceWeb, :controller

  alias Rice.SemiOAuth

  def options(conn, _params) do
    mock? = Rice.Notifications.impl() == Rice.Notifications.Log

    channels =
      Enum.filter(~w(sms email), &(mock? or Rice.Notifications.Dispatcher.available?(&1)))

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{
      semi_enabled: SemiOAuth.configured?(),
      verification_mode: if(mock?, do: "log", else: "live"),
      registration_channels: channels,
      handle_domain: Application.fetch_env!(:rice, :pds)[:handle_domain]
    })
  end

  def login(conn, params) do
    conn = put_session(conn, :semi_return_to, return_to(params["returnTo"]))

    if SemiOAuth.configured?() do
      verifier = SemiOAuth.gen_code_verifier()
      state = SemiOAuth.gen_state()
      challenge = SemiOAuth.code_challenge(verifier)

      conn
      |> put_session(:semi_pkce_verifier, verifier)
      |> put_session(:semi_oauth_state, state)
      |> redirect(external: SemiOAuth.authorize_url(state, challenge))
    else
      login_error(conn, "Semi 登录暂未开放，请使用账号密码登录。")
    end
  end

  # Semi returned an error instead of a code (e.g. user denied consent).
  def callback(conn, %{"error" => error}) do
    login_error(conn, if(error == "access_denied", do: "已取消 Semi 授权。", else: "Semi 授权失败，请重试。"))
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    expected_state = get_session(conn, :semi_oauth_state)
    verifier = get_session(conn, :semi_pkce_verifier)

    cond do
      is_nil(expected_state) or is_nil(verifier) ->
        login_error(conn, "会话已过期，请重新发起登录。")

      not secure_compare(state, expected_state) ->
        login_error(conn, "登录校验失败，请重新发起登录。")

      true ->
        complete_login(conn, code, verifier)
    end
  end

  def callback(conn, _params) do
    login_error(conn, "无效的登录回调，请重新发起登录。")
  end

  def logout(conn, _params) do
    conn
    |> delete_session(:semi_user)
    |> delete_session(:atproto)
    |> put_flash(:info, "已退出登录")
    |> redirect(to: ~p"/")
  end

  defp complete_login(conn, code, verifier) do
    with {:ok, tokens} <- SemiOAuth.exchange_code(code, verifier),
         {:ok, user} <- SemiOAuth.fetch_userinfo(tokens["access_token"]),
         {:ok, atproto} <- Rice.Bridge.session_for(user) do
      # Hand the minted PDS session to the front-end via a one-time ticket and
      # redirect there so the user lands logged in. rice's own session is also
      # set (a debug view at rice.together.li/), but the destination is the app.
      ticket = Rice.Handoff.put(handoff_payload(atproto))
      target = handoff_url(conn, %{ticket: ticket})

      conn
      |> reset_pkce()
      |> put_session(:semi_user, Map.take(user, semi_display_keys()))
      |> put_session(:atproto, %{"did" => atproto.did, "handle" => atproto.handle})
      |> redirect(external: target)
    else
      {:error, _reason} ->
        login_error(conn, "Semi 登录暂时失败，请稍后重试。")
    end
  end

  # Redeem a handoff ticket for the PDS session (one-time, CORS-scoped to the
  # front-end origin). Called cross-origin by the social-app /semi-callback screen.
  def session(conn, %{"ticket" => ticket}) do
    conn =
      conn
      |> put_resp_header("access-control-allow-origin", handoff_origin())
      |> put_resp_header("vary", "origin")
      |> put_resp_header("cache-control", "no-store")

    case Rice.Handoff.take(ticket) do
      {:ok, payload} -> json(conn, payload)
      :error -> conn |> put_status(:not_found) |> json(%{error: "invalid_or_expired_ticket"})
    end
  end

  defp handoff_payload(atproto) do
    payload = %{
      "service" => Application.fetch_env!(:rice, :pds)[:public_url],
      "did" => atproto.did,
      "handle" => atproto.handle,
      "accessJwt" => atproto.access_jwt,
      "refreshJwt" => atproto.refresh_jwt
    }

    # DAO backend token ("Bearer <jwt>") — present unless DAO integration is
    # disabled or failed; the app's DAO features (任务/商品/发帖) need it.
    payload =
      case Map.get(atproto, :dao_jwt) do
        nil -> payload
        dao_jwt -> Map.put(payload, "daoJwt", dao_jwt)
      end

    # rice 自己的 API 令牌。C 端搬到 rice 之后,`/api/*`(提案、评论、稻米、
    # 个人档案)认的是这个,不是上面那两个。缺了它 Semi 用户能登录但一进
    # 业务页面就是 401 —— 所以这一项才是现在最要紧的。
    case Map.get(atproto, :rice_token) do
      nil -> payload
      token -> Map.put(payload, "riceToken", token)
    end
  end

  defp handoff_target, do: Application.fetch_env!(:rice, :handoff)[:target_url]
  defp handoff_origin, do: Application.fetch_env!(:rice, :handoff)[:allowed_origin]

  defp handoff_url(conn, params) do
    query =
      URI.encode_query(Map.put(params, :returnTo, return_to(get_session(conn, :semi_return_to))))

    handoff_target() <> "?" <> query
  end

  defp login_error(conn, message) do
    target = handoff_url(conn, %{error: message})
    conn |> reset_pkce() |> redirect(external: target)
  end

  defp return_to(value) when is_binary(value) do
    if Regex.match?(~r{^/(?!/)(?!login(?:[/?#]|$))[^\\\x00-\x20]*$}, value), do: value, else: "/"
  end

  defp return_to(_), do: "/"

  defp semi_display_keys,
    do: ~w(sub handle wallet_address phone_verified email_verified scopes_granted)

  defp reset_pkce(conn) do
    conn
    |> delete_session(:semi_pkce_verifier)
    |> delete_session(:semi_oauth_state)
    |> delete_session(:semi_return_to)
  end

  # Constant-time-ish comparison for the state token.
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end

  defp secure_compare(_, _), do: false
end

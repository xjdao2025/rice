defmodule Rice.Bridge do
  @moduledoc """
  Turns a Semi identity into an AT Protocol PDS session.

  A known Semi subject reuses the account rice provisioned for it (decrypt the
  stored password → `createSession`). An unknown subject gets a fresh
  `*.<handle_domain>` account auto-provisioned, its generated password stored
  encrypted, and a session returned.

  Returns `{:ok, %{did, handle, access_jwt, refresh_jwt}}` or `{:error, reason}`.
  """
  alias Rice.{Accounts, Vault}
  require Logger

  # 和 Rice.Accounts 一样走可替换实现 —— 测试里换成 Mox,不依赖跑着的 PDS。
  defp pds, do: Rice.PDS.Api.impl()

  def session_for(%{"sub" => sub} = userinfo) when is_binary(sub) do
    result =
      case Accounts.get_link_by_sub(sub) do
        nil -> provision(sub, userinfo)
        link -> login_existing(link, userinfo)
      end

    with {:ok, identity} <- result do
      ensure_profile(identity, userinfo)

      {:ok,
       identity
       |> Map.put(:rice_token, rice_token(identity, userinfo))}
    end
  end

  # rice 档案 + rice API 令牌。**C 端的每个业务接口都要它** —— 提案、评论、
  # 稻米余额、改绑手机全走 `/api/*`,而那一层认的是 rice 自己的 Bearer 令牌,
  # 不是 PDS 的 accessJwt。桥接早期后端还是 core,只发 daoJwt 就够;C 端搬到
  # rice 之后不补这一步,Semi 用户能登录但一进任何页面都是 401。
  #
  # best-effort:建档或签令牌失败不该让登录失败 —— 用户至少还能用 AT Protocol
  # 那一半(时间线、发帖)。失败会记日志。
  defp rice_token(identity, userinfo) do
    attrs = Map.put(identity, :nickname, display_name(userinfo, identity.handle))

    with {:ok, user} <- Accounts.ensure_user_for_did(attrs),
         {:ok, token} <- Accounts.issue_token(user) do
      token
    else
      {:error, reason} ->
        Logger.warning("bridge: rice token failed for #{identity.did}: #{inspect(reason)}")
        nil
    end
  end

  # Write an initial app.bsky.actor.profile if the account has none — covers
  # both freshly provisioned accounts and older ones created before profile
  # bootstrap existed. Never overwrites an existing profile (the user may have
  # edited it in the app), and never fails the login: profile is cosmetic.
  defp ensure_profile(identity, userinfo) do
    case pds().get_profile(identity.access_jwt, identity.did) do
      :missing ->
        display_name = display_name(userinfo, identity.handle)

        case pds().put_profile(identity.access_jwt, identity.did, %{"displayName" => display_name}) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "bridge: profile bootstrap failed for #{identity.did}: #{inspect(reason)}"
            )
        end

      {:ok, _record} ->
        :ok

      {:error, reason} ->
        Logger.warning("bridge: profile check failed for #{identity.did}: #{inspect(reason)}")
    end
  end

  # Semi userinfo has no nickname/avatar; the best initial display name is the
  # Semi handle, falling back to the first label of the PDS handle.
  defp display_name(userinfo, pds_handle) do
    case String.trim(userinfo["handle"] || "") do
      "" -> pds_handle |> String.split(".") |> hd()
      s -> String.slice(s, 0, 64)
    end
  end

  defp login_existing(link, userinfo) do
    with {:ok, password} <- Vault.decrypt(link.account_password_ciphertext),
         {:ok, session} <- pds().create_session(link.did, password) do
      # 钱包每次登录都刷新 —— 用户可能是先用 Semi 注册、之后才绑的钱包,
      # 只在建链接时写一次的话那批人永远看不到地址。
      Accounts.update_link_wallet(link, userinfo["wallet_address"])
      {:ok, identity(session)}
    else
      {:error, reason} -> {:error, {:login, reason}}
    end
  end

  defp provision(sub, userinfo) do
    password = gen_password()
    base = handle_base(userinfo, sub)

    with {:ok, session} <- create_account(base, sub, password),
         attrs = %{
           semi_sub: sub,
           did: session["did"],
           handle: session["handle"],
           account_password_ciphertext: Vault.encrypt(password),
           wallet_address: userinfo["wallet_address"]
         },
         {:ok, _link} <- Accounts.create_link(attrs) do
      {:ok, identity(session)}
    else
      {:error, reason} -> {:error, {:provision, reason}}
    end
  end

  # Try `<base>.<domain>`; if the handle is taken, retry once with a short
  # sub-derived suffix (deterministic, effectively unique).
  defp create_account(base, sub, password) do
    domain = pds().handle_domain()

    case pds().create_account(%{
           email: email(base),
           handle: base <> "." <> domain,
           password: password
         }) do
      {:ok, session} ->
        {:ok, session}

      {:error, {:pds, _method, _status, _msg}} ->
        base2 = base <> "-" <> String.slice(sanitize(sub), 0, 6)

        pds().create_account(%{
          email: email(base2),
          handle: base2 <> "." <> domain,
          password: password
        })

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_base(userinfo, sub) do
    case sanitize(userinfo["handle"] || "") do
      "" -> "u" <> String.slice(sanitize(sub), 0, 8)
      s -> String.slice(s, 0, 30)
    end
  end

  # AT Protocol handle labels: lowercase [a-z0-9-], no leading/trailing hyphen.
  defp sanitize(s) do
    s
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp email(local), do: local <> "@" <> pds().email_domain()

  defp gen_password, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

  defp identity(session) do
    %{
      did: session["did"],
      handle: session["handle"],
      access_jwt: session["accessJwt"],
      refresh_jwt: session["refreshJwt"]
    }
  end
end

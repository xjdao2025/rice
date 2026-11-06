defmodule RiceWeb.Api.Auth do
  @moduledoc """
  Bearer 令牌认证。

  `fetch_current_user` 允许无令牌访客,但拒绝无效令牌。
  `require_authenticated_user` 拦住必须登录的接口。
  """
  import Plug.Conn
  import Phoenix.Controller, only: [put_view: 2, render: 2]

  alias Rice.Accounts

  def fetch_current_user(conn, _opts) do
    case bearer_token(conn) do
      :missing ->
        conn |> assign(:current_user, nil) |> assign(:current_token, nil)

      {:ok, token} ->
        case user_for(token) do
          %Accounts.User{} = user ->
            conn |> assign(:current_user, user) |> assign(:current_token, token)

          _ ->
            unauthorized(conn)
        end

      :error ->
        unauthorized(conn)
    end
  end

  # rice 自己签发的不透明令牌是正路;认不出来的再当 core 的 daoJwt 试一次。
  #
  # 为什么要这个兜底:2026-08-21 切到 rice 时,所有人浏览器里存的还是 core 签的
  # daoJwt,rice 不认 —— 表现是页面能浏览(PDS 会话没坏)但每个要登录的接口 401,
  # 等于**全员静默登出**。切换后一整天只有 5 个人(共 2028 个)拿到过 rice 令牌。
  # 认这张老票让人不必被迫重登。
  #
  # ⚠️ 这是过渡代码,2026-12-31 连同 Rice.Dao、旧票撤销名单和相关字段一起清理。
  # 退出会检查单票撤销名单；改密/禁用会永久关闭该用户的旧票兜底。
  defp user_for(token) do
    case Accounts.user_by_token(token) do
      %Accounts.User{} = user ->
        user

      _ ->
        case Rice.Dao.verify_jwt(token) do
          {:ok, uid} ->
            user =
              unless Accounts.legacy_token_revoked?(token),
                do: Accounts.get_user_by_legacy_id(uid)

            :telemetry.execute([:rice, :auth, :legacy], %{count: 1}, %{
              result: if(user, do: :accepted, else: :rejected)
            })

            user

          {:error, _} ->
            nil
        end
    end
  end

  def require_authenticated_user(conn, _opts) do
    case conn.assigns[:current_user] do
      %Accounts.User{} -> conn
      _ -> unauthorized(conn)
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> put_view(json: RiceWeb.Api.ErrorJSON)
    |> render(:"401")
    |> halt()
  end

  # core 那边 daoJwt 存的就是完整的 "Bearer xxx" 串,这里只认标准头。
  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [] -> :missing
      ["Bearer " <> token | _] when byte_size(token) > 0 -> {:ok, String.trim(token)}
      _ -> :error
    end
  end
end

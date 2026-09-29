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
  # ⚠️ 这是**过渡代码**:daoJwt 有效期 30 天,最迟 2026-09-20 全部过期,
  # 到时候连同 `Rice.Dao` 一起删。它也**不可撤销** —— 禁用用户在老票过期前
  # 只能靠这里的 `disabled_at` 检查拦住(见 `get_user_by_legacy_id/1`)。
  defp user_for(token) do
    case Accounts.user_by_token(token) do
      %Accounts.User{} = user ->
        user

      _ ->
        case Rice.Dao.verify_jwt(token) do
          {:ok, uid} -> Accounts.get_user_by_legacy_id(uid)
          {:error, _} -> nil
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

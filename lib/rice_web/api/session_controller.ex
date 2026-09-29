defmodule RiceWeb.Api.SessionController do
  @moduledoc "登录 / 登出。替代 core 的 /user/login。"
  use RiceWeb, :controller

  alias Rice.Accounts

  action_fallback RiceWeb.Api.FallbackController

  def create(conn, %{"identifier" => identifier, "password" => password})
      when is_binary(identifier) and is_binary(password) do
    case Accounts.login(identifier, password) do
      {:ok, result} ->
        conn |> put_view(json: RiceWeb.Api.SessionJSON) |> render(:show, result)

      {:error, :account_disabled} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "AccountDisabled", errors: %{detail: "该账号已被禁用"}})

      {:error, :invalid_credentials} ->
        # 不区分"账号不存在"和"密码错误" —— 区分了就等于一个账号枚举接口
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "InvalidCredentials", errors: %{detail: "账号或密码错误"}})

      {:error, :login_unavailable} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "LoginUnavailable", errors: %{detail: "登录服务暂时不可用，请稍后重试。"}})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "InvalidLoginRequest", errors: %{detail: "请输入账号和密码。"}})
  end

  def delete(conn, _params) do
    if token = conn.assigns[:current_token], do: Accounts.revoke_token(token)
    send_resp(conn, :no_content, "")
  end
end

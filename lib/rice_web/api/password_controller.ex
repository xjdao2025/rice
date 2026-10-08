defmodule RiceWeb.Api.PasswordController do
  @moduledoc """
  凭验证码重置密码。替代 core 的 /user/reset-password。

  **匿名可用** —— 忘了密码的人本来就登不进来。身份由验证码证明:
  验证码发到已登记的手机/邮箱,能收到就说明是本人。
  """
  use RiceWeb, :controller

  alias Rice.Accounts

  action_fallback RiceWeb.Api.FallbackController

  def create(conn, params) do
    channel = params["channel"]

    target =
      case channel do
        "sms" -> Accounts.phone_target(params["phone_region"] || "86", params["phone"] || "")
        "email" -> params["email"] || ""
        _ -> ""
      end

    case Accounts.reset_password(channel, target, params["code"] || "", params["password"] || "") do
      {:ok, _user} ->
        send_resp(conn, :no_content, "")

      {:error, :weak_password} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{password: ["密码至少 8 位"]}})

      # 用户不存在与验证码错误返回同样的东西 —— 否则这就是一个
      # "这个手机号注册过没有"的探测接口
      {:error, :user_not_found} ->
        {:error, :invalid_code}

      {:error, reason} when reason in [:too_many_attempts, :code_expired, :invalid_code] ->
        {:error, reason}

      {:error, _} ->
        conn |> put_status(:bad_gateway) |> json(%{errors: %{detail: "重置密码失败"}})
    end
  end
end

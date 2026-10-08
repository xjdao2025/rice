defmodule RiceWeb.Api.VerificationCodeController do
  @moduledoc "发短信 / 邮件验证码。替代 core 的 /sms/send 和 /email/send。"
  use RiceWeb, :controller

  alias Rice.Accounts

  action_fallback RiceWeb.Api.FallbackController

  # 管理端的码只能由管理端验过密码或登录态之后自己发,公开接口不代发
  @admin_purposes Rice.Admin.code_purposes()

  def create(conn, %{"purpose" => purpose}) when purpose in @admin_purposes, do: invalid(conn)

  def create(conn, params) do
    channel = params["channel"]
    purpose = params["purpose"]
    target = target_for(channel, params)

    case Accounts.send_verification_code(channel, target, purpose) do
      {:ok, _record} ->
        conn
        |> put_resp_header(
          "retry-after",
          to_string(Accounts.verification_retry_after(channel, target))
        )
        |> send_resp(:no_content, "")

      {:error, :too_many_requests} ->
        conn
        |> put_resp_header(
          "retry-after",
          to_string(Accounts.verification_retry_after(channel, target))
        )
        |> put_status(:too_many_requests)
        |> json(%{errors: %{detail: "发送太频繁,请稍后再试"}})

      {:error, reason} when reason in [:invalid_channel, :invalid_purpose, :invalid_target] ->
        invalid(conn)

      {:error, :channel_not_configured} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{errors: %{detail: "该验证码通道暂未开放，请选择其他方式或稍后再试。"}})

      {:error, _} ->
        conn |> put_status(:bad_gateway) |> json(%{errors: %{detail: "验证码发送失败"}})
    end
  end

  defp invalid(conn),
    do: conn |> put_status(:unprocessable_entity) |> json(%{errors: %{detail: "请求参数不合法"}})

  defp target_for("sms", params),
    do: Accounts.phone_target(params["phone_region"] || "86", params["phone"] || "")

  defp target_for("email", params), do: params["email"] || ""
  defp target_for(_, _), do: ""
end

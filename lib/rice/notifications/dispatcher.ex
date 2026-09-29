defmodule Rice.Notifications.Dispatcher do
  @moduledoc "真实验证码通道；缺少配置明确失败，日志模拟由运行配置显式选择。"
  @behaviour Rice.Notifications

  alias Rice.Notifications.{AliyunSms, Smtp}

  @impl true
  def send_sms(region, phone, text) do
    if available?("sms") do
      AliyunSms.send_sms(region, phone, text)
    else
      {:error, :channel_not_configured}
    end
  end

  @impl true
  def send_email(address, subject, body) do
    if available?("email") do
      Smtp.send_email(address, subject, body)
    else
      {:error, :channel_not_configured}
    end
  end

  @doc "四个必填项全都非空才算配好 —— 少一个签名就算不对,发出去是 400。"
  def configured?(mod, keys) do
    cfg = Application.get_env(:rice, mod, [])
    Enum.all?(keys, fn key -> cfg[key] not in [nil, ""] end)
  end

  def available?("sms"),
    do: configured?(AliyunSms, [:access_key_id, :access_key_secret, :sign_name, :template_code])

  def available?("email"),
    do:
      configured?(Rice.Mailer, [:relay, :username, :password]) and
        configured?(Smtp, [:sender_address])
end

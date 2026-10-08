defmodule Rice.Notifications do
  @moduledoc """
  外发通道(短信 / 邮件)。抽成 behaviour 是为了测试能打桩 ——
  单元测试不该真的给人发短信。
  """

  @callback send_sms(phone_region :: String.t(), phone :: String.t(), text :: String.t()) ::
              :ok | {:error, term()}
  @callback send_email(address :: String.t(), subject :: String.t(), body :: String.t()) ::
              :ok | {:error, term()}

  @spec impl() :: module()
  def impl, do: Application.get_env(:rice, :notifications, Rice.Notifications.Log)

  @spec send_sms(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def send_sms(region, phone, text), do: impl().send_sms(region, phone, text)
  @spec send_email(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def send_email(address, subject, body), do: impl().send_email(address, subject, body)
end

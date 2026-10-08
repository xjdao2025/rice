defmodule Rice.Accounts.VerificationCode do
  @moduledoc """
  短信 / 邮件验证码。

  相对 core 放在 Redis 的做法,这里多了两条 core 完全没有的约束:
  **发码频率限制**(core 无)和**尝试次数上限**(core 那边 6 位码可以无限次猜)。
  """
  use Rice.Schema

  @purposes ~w(register reset_password modify_phone modify_email delete_account
              admin_login admin_reset_password admin_grant)
  @channels ~w(sms email)
  @max_attempts 5
  @validity_minutes 30
  @resend_interval_seconds 60
  # 短信按条计费:同一联系方式每天封顶
  @daily_per_target 10

  schema "verification_codes" do
    field :channel, :string
    field :target, :string
    field :purpose, :string
    field :code_hash, :binary
    field :attempts, :integer, default: 0
    field :consumed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    timestamps()
  end

  def build(channel, target, purpose, code) do
    change(%__MODULE__{},
      channel: channel,
      target: target,
      purpose: purpose,
      code_hash: hash(code),
      expires_at: DateTime.add(DateTime.utc_now(), @validity_minutes * 60, :second)
    )
  end

  def changeset(code, attrs) do
    code
    |> cast(attrs, [:channel, :target, :purpose, :attempts, :consumed_at])
    |> validate_inclusion(:channel, @channels)
    |> validate_inclusion(:purpose, @purposes)
  end

  def hash(code), do: :crypto.hash(:sha256, code)

  @doc "6 位数字码。用 strong_rand_bytes 而不是 :rand —— 后者可预测。"
  def generate_code do
    :crypto.strong_rand_bytes(4)
    |> :binary.decode_unsigned()
    |> rem(1_000_000)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end

  def purposes, do: @purposes
  def channels, do: @channels
  def max_attempts, do: @max_attempts
  def validity_minutes, do: @validity_minutes
  def resend_interval_seconds, do: @resend_interval_seconds
  def daily_per_target, do: @daily_per_target
end

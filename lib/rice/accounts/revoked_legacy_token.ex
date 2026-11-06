defmodule Rice.Accounts.RevokedLegacyToken do
  @moduledoc "过渡期 daoJwt 的单会话撤销名单；只保留 SHA-256，不保存原始令牌。"
  use Ecto.Schema
  @primary_key {:token_hash, :binary, autogenerate: false}
  @type t :: %__MODULE__{}
  schema "revoked_legacy_tokens" do
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

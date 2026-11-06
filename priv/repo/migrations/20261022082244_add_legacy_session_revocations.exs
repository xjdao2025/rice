defmodule Rice.Repo.Migrations.AddLegacySessionRevocations do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :legacy_tokens_revoked, :boolean, null: false, default: false
    end

    create table(:revoked_legacy_tokens, primary_key: false) do
      add :token_hash, :binary, primary_key: true
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end
end

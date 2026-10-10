defmodule Rice.Repo.Migrations.CreateModerationPasses do
  @moduledoc "发布前审核通过的内容指纹,事后补审见到同样的内容就不再交给阿里云。"
  use Ecto.Migration
  import Rice.Migration

  def change do
    create table(:moderation_passes, primary_key: false) do
      tsid_primary_key()
      add :fingerprint, :string, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:moderation_passes, [:fingerprint])
  end
end

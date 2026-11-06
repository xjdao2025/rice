defmodule Rice.Repo.Migrations.AddPostScanCheckpoints do
  use Ecto.Migration

  def change do
    create table(:post_scan_states, primary_key: false) do
      add :id, :string, primary_key: true
      add :since, :utc_datetime_usec
      add :until, :utc_datetime_usec
      add :cursor, :text
      add :watermark, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end
  end
end

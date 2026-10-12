defmodule Rice.Repo.Migrations.CreatePostModerations do
  @moduledoc "事后补审的记录:每个贴文版本(uri + cid)只交给阿里云审一次。"
  use Ecto.Migration
  import Rice.Migration

  def change do
    create table(:post_moderations, primary_key: false) do
      tsid_primary_key()
      add :uri, :string, null: false
      add :cid, :string, null: false
      add :verdict, :string, null: false
      add :reasons, {:array, :string}, null: false, default: []
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:post_moderations, [:uri, :cid])
  end
end

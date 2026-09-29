defmodule Rice.Repo.Migrations.AddBusinessImages do
  use Ecto.Migration
  import Rice.Migration

  def change do
    alter table(:attachments) do
      add :user_id, tsid_references(:users, on_delete: :nilify_all)
    end

    create index(:attachments, [:user_id])

    create table(:task_images, primary_key: false) do
      tsid_primary_key()
      add :task_id, tsid_references(:tasks, on_delete: :delete_all), null: false
      add :attachment_id, tsid_references(:attachments), null: false
      add :position, :integer, null: false
    end

    create unique_index(:task_images, [:task_id, :attachment_id])
    create constraint(:task_images, :task_image_position, check: "position >= 0 AND position < 4")

    create table(:event_images, primary_key: false) do
      tsid_primary_key()
      add :event_id, tsid_references(:events, on_delete: :delete_all), null: false
      add :attachment_id, tsid_references(:attachments), null: false
      add :position, :integer, null: false
    end

    create unique_index(:event_images, [:event_id, :attachment_id])

    create constraint(:event_images, :event_image_position,
             check: "position >= 0 AND position < 4"
           )
  end
end

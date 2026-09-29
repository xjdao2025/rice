defmodule Rice.Repo.Migrations.CreateTaskNotifications do
  use Ecto.Migration
  import Rice.Migration

  def change do
    create table(:task_notifications, primary_key: false) do
      tsid_primary_key()
      add(:task_id, tsid_references(:tasks, on_delete: :delete_all), null: false)
      add(:recipient_id, tsid_references(:users, on_delete: :delete_all), null: false)
      add(:actor_id, tsid_references(:users), null: false)
      add(:event, :string, size: 32, null: false)
      add(:detail, :string, size: 512)
      add(:read_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:task_notifications, [:recipient_id, :id]))

    create(
      constraint(:task_notifications, :task_notifications_event,
        check:
          "event in ('application_created', 'assignee_appointed', 'application_not_selected', 'task_cancelled', 'result_submitted', 'result_approved', 'changes_requested')"
      )
    )
  end
end

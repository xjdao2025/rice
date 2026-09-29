defmodule Rice.Repo.Migrations.CompleteTaskV1 do
  use Ecto.Migration
  import Rice.Migration

  def up do
    create(
      unique_index(:tasks, [:creator_id],
        where: "status = 'draft'",
        name: :tasks_one_draft_per_creator
      )
    )

    execute("ALTER TABLE task_notifications DROP CONSTRAINT task_notifications_event")

    create(
      constraint(:task_notifications, :task_notifications_event,
        check:
          "event in ('application_created', 'assignee_appointed', 'application_not_selected', 'task_cancelled', 'task_expired', 'result_submitted', 'result_approved', 'changes_requested')"
      )
    )

    create table(:task_events, primary_key: false) do
      tsid_primary_key()
      add(:task_id, tsid_references(:tasks, on_delete: :delete_all), null: false)
      add(:actor_id, tsid_references(:users, on_delete: :nilify_all))
      add(:from_status, :string, size: 24)
      add(:to_status, :string, size: 24, null: false)
      add(:detail, :string, size: 512)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:task_events, [:task_id, :id]))

    create(
      constraint(:task_events, :task_events_statuses,
        check:
          "(from_status is null or from_status in ('draft', 'open', 'in_progress', 'under_review', 'completed', 'expired', 'cancelled')) and " <>
            "to_status in ('draft', 'open', 'in_progress', 'under_review', 'completed', 'expired', 'cancelled')"
      )
    )

    execute("""
    INSERT INTO task_events (id, task_id, from_status, to_status, detail, inserted_at)
    SELECT id, id, NULL, status, '状态记录从这里开始', NOW()
    FROM tasks
    """)
  end

  def down do
    drop(table(:task_events))
    drop(index(:tasks, [:creator_id], name: :tasks_one_draft_per_creator))

    execute("ALTER TABLE task_notifications DROP CONSTRAINT task_notifications_event")

    create(
      constraint(:task_notifications, :task_notifications_event,
        check:
          "event in ('application_created', 'assignee_appointed', 'application_not_selected', 'task_cancelled', 'result_submitted', 'result_approved', 'changes_requested')"
      )
    )
  end
end

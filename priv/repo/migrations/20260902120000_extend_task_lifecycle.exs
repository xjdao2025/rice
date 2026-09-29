defmodule Rice.Repo.Migrations.ExtendTaskLifecycle do
  use Ecto.Migration

  def up do
    alter table(:tasks) do
      add(:application_deadline, :utc_datetime_usec)
      add(:appointed_at, :utc_datetime_usec)
      add(:appointment_reason, :string, size: 512)
    end

    execute("ALTER TABLE tasks DROP CONSTRAINT IF EXISTS tasks_status")
    execute("ALTER TABLE tasks DROP CONSTRAINT IF EXISTS tasks_assignee_matches_status")

    execute("UPDATE tasks SET appointed_at = updated_at WHERE status <> 'open'")

    create(
      constraint(:tasks, :tasks_status,
        check:
          "status in ('draft', 'open', 'in_progress', 'under_review', 'completed', 'expired', 'cancelled')"
      )
    )

    create(
      constraint(:tasks, :tasks_assignee_matches_status,
        check:
          "(status in ('draft', 'open', 'expired', 'cancelled') and assignee_id is null and appointed_at is null) or " <>
            "(status in ('in_progress', 'under_review', 'completed') and assignee_id is not null and appointed_at is not null)"
      )
    )
  end

  def down do
    execute("ALTER TABLE tasks DROP CONSTRAINT IF EXISTS tasks_status")
    execute("ALTER TABLE tasks DROP CONSTRAINT IF EXISTS tasks_assignee_matches_status")
    execute("UPDATE tasks SET status = 'open' WHERE status in ('draft', 'expired', 'cancelled')")

    create(
      constraint(:tasks, :tasks_status,
        check: "status in ('open', 'in_progress', 'under_review', 'completed')"
      )
    )

    create(
      constraint(:tasks, :tasks_assignee_matches_status,
        check:
          "(status = 'open' and assignee_id is null) or " <>
            "(status <> 'open' and assignee_id is not null)"
      )
    )

    alter table(:tasks) do
      remove(:application_deadline)
      remove(:appointed_at)
      remove(:appointment_reason)
    end
  end
end

defmodule Rice.Repo.Migrations.AddTaskOverdueStatus do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE tasks DROP CONSTRAINT tasks_status")
    execute("ALTER TABLE tasks DROP CONSTRAINT tasks_assignee_matches_status")
    execute("ALTER TABLE tasks DROP CONSTRAINT tasks_reward_matches_status")
    execute("ALTER TABLE task_events DROP CONSTRAINT task_events_statuses")

    create(
      constraint(:tasks, :tasks_status,
        check:
          "status in ('draft', 'open', 'in_progress', 'overdue', 'under_review', 'completed', 'expired', 'cancelled')"
      )
    )

    create(
      constraint(:tasks, :tasks_assignee_matches_status,
        check:
          "(status in ('draft', 'open', 'expired', 'cancelled') and assignee_id is null and appointed_at is null) or " <>
            "(status in ('in_progress', 'overdue', 'under_review', 'completed') and assignee_id is not null and appointed_at is not null)"
      )
    )

    create(
      constraint(:tasks, :tasks_reward_matches_status,
        check:
          "(reward_status = 'none' and (reward_amount = 0 or status = 'draft')) or " <>
            "(reward_status = 'reserved' and reward_amount > 0 and status in ('open', 'in_progress', 'overdue', 'under_review')) or " <>
            "(reward_status = 'settled' and reward_amount > 0 and status = 'completed') or " <>
            "(reward_status = 'refunded' and reward_amount > 0 and status in ('expired', 'cancelled'))"
      )
    )

    create(
      constraint(:task_events, :task_events_statuses,
        check:
          "(from_status is null or from_status in ('draft', 'open', 'in_progress', 'overdue', 'under_review', 'completed', 'expired', 'cancelled')) and " <>
            "to_status in ('draft', 'open', 'in_progress', 'overdue', 'under_review', 'completed', 'expired', 'cancelled')"
      )
    )
  end

  def down do
    execute("ALTER TABLE tasks DROP CONSTRAINT tasks_status")
    execute("ALTER TABLE tasks DROP CONSTRAINT tasks_assignee_matches_status")
    execute("ALTER TABLE tasks DROP CONSTRAINT tasks_reward_matches_status")
    execute("ALTER TABLE task_events DROP CONSTRAINT task_events_statuses")

    execute("UPDATE tasks SET status = 'in_progress' WHERE status = 'overdue'")
    execute("UPDATE task_events SET from_status = 'in_progress' WHERE from_status = 'overdue'")
    execute("UPDATE task_events SET to_status = 'in_progress' WHERE to_status = 'overdue'")

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

    create(
      constraint(:tasks, :tasks_reward_matches_status,
        check:
          "(reward_status = 'none' and (reward_amount = 0 or status = 'draft')) or " <>
            "(reward_status = 'reserved' and reward_amount > 0 and status in ('open', 'in_progress', 'under_review')) or " <>
            "(reward_status = 'settled' and reward_amount > 0 and status = 'completed') or " <>
            "(reward_status = 'refunded' and reward_amount > 0 and status in ('expired', 'cancelled'))"
      )
    )

    create(
      constraint(:task_events, :task_events_statuses,
        check:
          "(from_status is null or from_status in ('draft', 'open', 'in_progress', 'under_review', 'completed', 'expired', 'cancelled')) and " <>
            "to_status in ('draft', 'open', 'in_progress', 'under_review', 'completed', 'expired', 'cancelled')"
      )
    )
  end
end

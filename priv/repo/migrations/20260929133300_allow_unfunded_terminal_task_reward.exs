defmodule Rice.Repo.Migrations.AllowUnfundedTerminalTaskReward do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE tasks DROP CONSTRAINT tasks_reward_matches_status")

    create(
      constraint(:tasks, :tasks_reward_matches_status,
        check:
          "(reward_status = 'none' and (reward_amount = 0 or status in ('draft', 'completed', 'expired', 'cancelled'))) or " <>
            "(reward_status = 'reserved' and reward_amount > 0 and status in ('open', 'in_progress', 'overdue', 'under_review')) or " <>
            "(reward_status = 'settled' and status = 'completed') or " <>
            "(reward_status = 'refunded' and status in ('expired', 'cancelled'))"
      )
    )
  end

  def down do
    raise "Task edit history may contain unfunded terminal reward terms; restore a database backup to roll back"
  end
end

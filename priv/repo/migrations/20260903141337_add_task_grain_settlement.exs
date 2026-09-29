defmodule Rice.Repo.Migrations.AddTaskGrainSettlement do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add(:grain_frozen_balance, :bigint, null: false, default: 0)
    end

    alter table(:tasks) do
      add(:reward_amount, :bigint, null: false, default: 0)
      add(:reward_status, :string, size: 16, null: false, default: "none")
    end

    create(
      constraint(:users, :users_grain_frozen_balance_non_negative,
        check: "grain_frozen_balance >= 0"
      )
    )

    create(constraint(:tasks, :tasks_reward_amount_non_negative, check: "reward_amount >= 0"))

    create(
      constraint(:tasks, :tasks_reward_status,
        check: "reward_status in ('none', 'reserved', 'settled', 'refunded')"
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

    execute("ALTER TABLE grain_transfers DROP CONSTRAINT grain_transfers_kind")

    create(
      constraint(:grain_transfers, :grain_transfers_kind,
        check: "kind in ('reward', 'gift', 'grant', 'task_reward')"
      )
    )
  end

  def down do
    execute("ALTER TABLE grain_transfers DROP CONSTRAINT grain_transfers_kind")
    execute("UPDATE grain_transfers SET kind = 'reward' WHERE kind = 'task_reward'")

    create(
      constraint(:grain_transfers, :grain_transfers_kind,
        check: "kind in ('reward', 'gift', 'grant')"
      )
    )

    drop(constraint(:tasks, :tasks_reward_matches_status))
    drop(constraint(:tasks, :tasks_reward_status))
    drop(constraint(:tasks, :tasks_reward_amount_non_negative))
    drop(constraint(:users, :users_grain_frozen_balance_non_negative))

    alter table(:tasks) do
      remove(:reward_status)
      remove(:reward_amount)
    end

    alter table(:users) do
      remove(:grain_frozen_balance)
    end
  end
end

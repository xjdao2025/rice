defmodule Rice.Repo.Migrations.AddTaskCapacity do
  use Ecto.Migration

  @max_capacity 1_000

  def up do
    alter table(:tasks) do
      add :capacity, :integer, null: false, default: 1
    end

    alter table(:task_applications) do
      add :appointed_at, :utc_datetime_usec
      add :appointment_reason, :string, size: 512
      add :reward_slot, :integer
    end

    create constraint(:tasks, :tasks_capacity_range,
             check: "capacity BETWEEN 1 AND #{@max_capacity}"
           )

    create constraint(:task_applications, :task_applications_reward_slot_positive,
             check: "reward_slot IS NULL OR reward_slot BETWEEN 1 AND #{@max_capacity}"
           )

    create unique_index(:task_applications, [:task_id, :round, :reward_slot],
             where: "reward_slot IS NOT NULL"
           )

    drop constraint(:tasks, :tasks_assignee_matches_status)

    create constraint(:tasks, :tasks_assignee_matches_status,
             check:
               "(capacity > 1 AND assignee_id IS NULL AND appointed_at IS NULL) OR " <>
                 "(capacity = 1 AND ((status IN ('draft', 'open', 'expired', 'cancelled') AND assignee_id IS NULL AND appointed_at IS NULL) OR " <>
                 "(status IN ('in_progress', 'overdue', 'under_review', 'completed') AND assignee_id IS NOT NULL AND appointed_at IS NOT NULL)))"
           )
  end

  def down do
    raise "Task participant assignments and Grain settlement evidence must be retained"
  end
end

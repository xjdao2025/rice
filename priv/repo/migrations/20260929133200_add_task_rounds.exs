defmodule Rice.Repo.Migrations.AddTaskRounds do
  use Ecto.Migration

  def up do
    alter table(:tasks) do
      add :round, :integer, null: false, default: 1
    end

    alter table(:task_applications) do
      add :round, :integer, null: false, default: 1
      add :final_status, :string
    end

    alter table(:task_submissions) do
      add :round, :integer, null: false, default: 1
      add :final_status, :string
    end

    drop unique_index(:task_applications, [:task_id, :user_id])
    create unique_index(:task_applications, [:task_id, :round, :user_id])

    create constraint(:tasks, :tasks_round_positive, check: "round > 0")
    create constraint(:task_applications, :task_applications_round_positive, check: "round > 0")
    create constraint(:task_submissions, :task_submissions_round_positive, check: "round > 0")
  end

  def down do
    raise "Task rounds and their application history cannot be discarded; restore a database backup to roll back"
  end
end

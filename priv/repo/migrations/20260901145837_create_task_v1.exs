defmodule Rice.Repo.Migrations.CreateTaskV1 do
  use Ecto.Migration
  import Rice.Migration

  def change do
    alter table(:users) do
      add(:can_publish_tasks, :boolean, null: false, default: false)
    end

    create table(:tasks, primary_key: false) do
      tsid_primary_key()
      add(:creator_id, tsid_references(:users), null: false)
      add(:assignee_id, tsid_references(:users, on_delete: :nilify_all))
      add(:title, :string, size: 128, null: false)
      add(:description, :text, null: false)
      add(:status, :string, size: 24, null: false, default: "open")

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:tasks, [:status, :id]))
    create(index(:tasks, [:creator_id, :id]))
    create(index(:tasks, [:assignee_id, :id]))

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

    create table(:task_applications, primary_key: false) do
      tsid_primary_key()
      add(:task_id, tsid_references(:tasks, on_delete: :delete_all), null: false)
      add(:user_id, tsid_references(:users), null: false)
      add(:reason, :string, size: 512, null: false, default: "")

      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:task_applications, [:task_id, :user_id]))

    create table(:task_submissions, primary_key: false) do
      tsid_primary_key()
      add(:task_id, tsid_references(:tasks, on_delete: :delete_all), null: false)
      add(:user_id, tsid_references(:users), null: false)
      add(:body, :text, null: false)
      add(:review_reason, :string, size: 512)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:task_submissions, [:task_id, :id]))

    create(
      constraint(:task_submissions, :task_submissions_review_reason,
        check: "review_reason is null or length(btrim(review_reason)) > 0"
      )
    )
  end
end

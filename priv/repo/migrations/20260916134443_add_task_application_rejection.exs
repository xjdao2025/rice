defmodule Rice.Repo.Migrations.AddTaskApplicationRejection do
  use Ecto.Migration

  def change do
    alter table(:task_applications) do
      add :rejected_at, :utc_datetime_usec
    end
  end
end

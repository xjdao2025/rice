defmodule Rice.Repo.Migrations.AddEventRounds do
  use Ecto.Migration

  def up do
    alter table(:events) do
      add :round, :integer, null: false, default: 1
    end

    alter table(:event_applications) do
      add :round, :integer, null: false, default: 1
    end

    alter table(:event_history) do
      add :round, :integer, null: false, default: 1
    end

    drop unique_index(:event_applications, [:event_id, :user_id])
    create unique_index(:event_applications, [:event_id, :round, :user_id])
    create constraint(:events, :events_round_positive, check: "round > 0")
    create constraint(:event_applications, :event_applications_round_positive, check: "round > 0")
  end

  def down do
    raise "Event rounds preserve paid application history; restore the database backup to roll back"
  end
end

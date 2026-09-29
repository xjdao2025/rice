defmodule Rice.Repo.Migrations.AddPublishedEditHistory do
  use Ecto.Migration
  import Rice.Migration

  def up do
    alter table(:tasks) do
      add :reward_subject_uri, :string
    end

    alter table(:task_events) do
      add :before, :map
      add :after, :map
    end

    alter table(:event_history) do
      add :before, :map
      add :after, :map
    end

    alter table(:event_applications) do
      add :settlement_node_id, tsid_references(:nodes)
    end

    execute("""
    UPDATE event_applications AS a
    SET settlement_node_id = e.settlement_node_id
    FROM events AS e WHERE a.event_id = e.id
    """)
  end

  def down do
    raise "Edit history and Grain ownership cannot be discarded; restore the database backup to roll back"
  end
end

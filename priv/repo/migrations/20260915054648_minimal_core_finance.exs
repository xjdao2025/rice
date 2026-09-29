defmodule Rice.Repo.Migrations.MinimalTaskAndReceipts do
  use Ecto.Migration
  import Rice.Migration

  def up do
    alter table(:tasks) do
      add :node_id, tsid_references(:nodes)
      add :requirement, :text, null: false, default: ""
      add :execution_deadline, :utc_datetime_usec
      add :client_request_id, :string, size: 128
    end

    create index(:tasks, [:node_id, :id])

    create unique_index(:tasks, [:creator_id, :client_request_id],
             where: "client_request_id IS NOT NULL"
           )

    create table(:grain_receipts, primary_key: false) do
      tsid_primary_key()
      add :kind, :string, null: false
      add :subject_uri, :string, size: 512, null: false
      add :amount, :bigint, null: false
      add :from_user_id, tsid_references(:users), null: false
      add :to_user_id, tsid_references(:users)
      add :transfer_id, tsid_references(:grain_transfers)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:grain_receipts, [:subject_uri, :kind])

    create unique_index(:grain_receipts, [:subject_uri],
             where: "kind IN ('refunded', 'settled')",
             name: :grain_receipts_one_outcome
           )

    create constraint(:grain_receipts, :grain_receipts_kind,
             check: "kind IN ('reserved', 'refunded', 'settled')"
           )

    create constraint(:grain_receipts, :grain_receipts_amount, check: "amount > 0")
    execute "ALTER TABLE grain_transfers DROP CONSTRAINT grain_transfers_kind"

    create constraint(:grain_transfers, :grain_transfers_kind,
             check: "kind IN ('reward', 'gift', 'grant', 'task_reward', 'event_fee')"
           )

    # Preserve existing reservations without touching balances or inventing old movements.
    execute """
    INSERT INTO grain_receipts (id, kind, subject_uri, amount, from_user_id, inserted_at)
    SELECT id, 'reserved', 'rice://tasks/' || id, reward_amount, creator_id, updated_at
    FROM tasks WHERE reward_status = 'reserved'
    """

    execute "ALTER TABLE task_notifications ALTER COLUMN task_id DROP NOT NULL"

    alter table(:task_notifications) do
      add :subject_type, :string
      add :subject_id, :string
    end

    execute "ALTER TABLE task_notifications DROP CONSTRAINT task_notifications_event"
  end

  def down do
    raise "Business receipts must be retained; restore the database backup to roll back this migration"
  end
end

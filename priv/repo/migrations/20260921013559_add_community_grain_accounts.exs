defmodule Rice.Repo.Migrations.AddCommunityGrainAccounts do
  use Ecto.Migration
  import Rice.Migration

  def up do
    alter table(:nodes) do
      add :grain_balance, :bigint, null: false, default: 0
      add :grain_frozen_balance, :bigint, null: false, default: 0
    end

    create constraint(:nodes, :nodes_grain_non_negative,
             check: "grain_balance >= 0 AND grain_frozen_balance >= 0"
           )

    # NULL keeps every existing business attached to its original personal account.
    # No balances or old reservations are moved by this migration.
    alter table(:tasks) do
      add :funding_node_id, tsid_references(:nodes)
    end

    alter table(:events) do
      add :settlement_node_id, tsid_references(:nodes)
    end

    for table <- [:grain_transfers, :grain_receipts] do
      alter table(table) do
        add :from_node_id, tsid_references(:nodes)
        add :to_node_id, tsid_references(:nodes)
      end

      create index(table, [:from_node_id, :id])
      create index(table, [:to_node_id, :id])
    end

    execute "ALTER TABLE grain_transfers ALTER COLUMN to_user_id DROP NOT NULL"
    execute "ALTER TABLE grain_receipts ALTER COLUMN from_user_id DROP NOT NULL"
    drop constraint(:grain_transfers, :grain_transfers_kind)
    drop constraint(:grain_transfers, :grain_transfers_from_matches_kind)

    create constraint(:grain_transfers, :grain_transfers_kind,
             check:
               "kind IN ('reward', 'gift', 'grant', 'task_reward', 'event_fee', 'community_fund')"
           )

    create constraint(:grain_transfers, :grain_transfers_from_matches_kind,
             check:
               "(kind = 'grant' AND num_nonnulls(from_user_id, from_node_id) = 0) OR (kind <> 'grant' AND num_nonnulls(from_user_id, from_node_id) = 1)"
           )

    create constraint(:grain_transfers, :grain_transfers_to_account,
             check: "num_nonnulls(to_user_id, to_node_id) = 1"
           )

    create constraint(:grain_receipts, :grain_receipts_from_account,
             check: "num_nonnulls(from_user_id, from_node_id) = 1"
           )

    create constraint(:grain_receipts, :grain_receipts_to_account,
             check:
               "(kind = 'settled' AND num_nonnulls(to_user_id, to_node_id) = 1) OR (kind <> 'settled' AND num_nonnulls(to_user_id, to_node_id) = 0)"
           )

    create unique_index(:grain_transfers, [:from_user_id, :subject_uri],
             where: "kind = 'community_fund'",
             name: :grain_transfers_community_fund_request
           )
  end

  def down do
    raise "Community ledger entries must be retained; restore the database backup to roll back"
  end
end

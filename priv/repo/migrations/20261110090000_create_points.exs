defmodule Rice.Repo.Migrations.CreatePoints do
  use Ecto.Migration

  def change do
    create table(:points, primary_key: false) do
      add :id, :string, primary_key: true
      add :issuer_community_id, :string, null: false
      add :code, :string, null: false
      add :status, :string, null: false, default: "active"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:points, [:issuer_community_id, :code])

    create constraint(:points, :point_asset_valid,
             check:
               "status IN ('active', 'disabled') AND btrim(code) <> '' AND btrim(issuer_community_id) <> ''"
           )

    create table(:point_accounts, primary_key: false) do
      add :id, :string, primary_key: true
      add :point_id, references(:points, type: :string, on_delete: :restrict), null: false
      add :owner_type, :string, null: false
      add :owner_id, :string, null: false
      add :status, :string, null: false, default: "active"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:point_accounts, [:point_id, :owner_type, :owner_id])
    create unique_index(:point_accounts, [:id, :point_id])
    create unique_index(:point_accounts, [:id, :owner_type])

    create constraint(:point_accounts, :point_account_owner_valid,
             check: "owner_type IN ('user', 'node', 'system')"
           )

    create table(:point_balances, primary_key: false) do
      add :id, :string, primary_key: true
      add :owner_type, :string, null: false

      add :account_id,
          references(:point_accounts,
            type: :string,
            with: [owner_type: :owner_type],
            on_delete: :restrict
          ),
          null: false

      add :available, :bigint, null: false, default: 0
      add :held, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:point_balances, [:account_id])

    create constraint(:point_balances, :point_held_nonnegative,
             check: "held >= 0 AND (available >= 0 OR owner_type = 'system')"
           )

    create table(:point_transactions, primary_key: false) do
      add :id, :string, primary_key: true
      add :point_id, references(:points, type: :string, on_delete: :restrict), null: false
      add :kind, :string, null: false
      add :public_note, :text
      add :private_note, :text
      add :actor_id, :string
      add :source_app_id, :string
      add :reference_type, :string
      add :reference_id, :string

      add :idempotency_scope, :string
      add :idempotency_key, :string
      add :request_hash, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:point_transactions, [:id, :point_id])

    alter table(:point_transactions) do
      add :reverses_transaction_id,
          references(:point_transactions,
            type: :string,
            with: [point_id: :point_id],
            on_delete: :restrict
          )
    end

    create unique_index(:point_transactions, [
             :point_id,
             :idempotency_scope,
             :kind,
             :idempotency_key
           ])

    create constraint(:point_transactions, :point_transaction_idempotency_valid,
             check: "num_nonnulls(idempotency_scope, idempotency_key, request_hash) IN (0, 3)"
           )

    create index(:point_transactions, [:point_id, :inserted_at])
    create index(:point_transactions, [:reverses_transaction_id])

    create table(:point_recipients, primary_key: false) do
      add :id, :string, primary_key: true
      add :point_id, :string, null: false

      add :transaction_id,
          references(:point_transactions,
            type: :string,
            with: [point_id: :point_id],
            on_delete: :restrict
          ),
          null: false

      add :account_id,
          references(:point_accounts,
            type: :string,
            with: [point_id: :point_id],
            on_delete: :restrict
          ),
          null: false

      add :amount, :bigint, null: false
      add :note, :text
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:point_recipients, [:transaction_id])
    create index(:point_recipients, [:account_id, :inserted_at])
    create constraint(:point_recipients, :point_recipient_amount_positive, check: "amount > 0")

    create table(:point_entries, primary_key: false) do
      add :id, :string, primary_key: true
      add :point_id, :string, null: false

      add :transaction_id,
          references(:point_transactions,
            type: :string,
            with: [point_id: :point_id],
            on_delete: :restrict
          ),
          null: false

      add :account_id,
          references(:point_accounts,
            type: :string,
            with: [point_id: :point_id],
            on_delete: :restrict
          ),
          null: false

      add :bucket, :string, null: false
      add :delta, :bigint, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:point_entries, [:transaction_id])
    create index(:point_entries, [:account_id, :inserted_at])

    create constraint(:point_entries, :point_entry_valid,
             check: "bucket IN ('available', 'held') AND delta <> 0"
           )

    create table(:point_holds, primary_key: false) do
      add :id, :string, primary_key: true
      add :point_id, :string, null: false

      add :payer_account_id,
          references(:point_accounts,
            type: :string,
            with: [point_id: :point_id],
            on_delete: :restrict
          ),
          null: false

      add :reservation_transaction_id,
          references(:point_transactions,
            type: :string,
            with: [point_id: :point_id],
            on_delete: :restrict
          ),
          null: false

      add :original_amount, :bigint, null: false
      add :remaining_amount, :bigint, null: false
      add :status, :string, null: false, default: "active"
      add :expires_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:point_holds, [:reservation_transaction_id])

    create constraint(:point_holds, :point_hold_amounts_valid,
             check:
               "original_amount > 0 AND remaining_amount BETWEEN 0 AND original_amount AND ((status = 'active' AND remaining_amount > 0) OR (status = 'closed' AND remaining_amount = 0))"
           )

    create table(:point_payment_intents, primary_key: false) do
      add :id, :string, primary_key: true
      add :app_id, :string, null: false
      add :external_order_id, :string, null: false
      add :point_id, references(:points, type: :string, on_delete: :restrict), null: false

      add :payee_account_id,
          references(:point_accounts,
            type: :string,
            with: [point_id: :point_id],
            on_delete: :restrict
          ),
          null: false

      add :amount, :bigint, null: false
      add :status, :string, null: false, default: "pending"
      add :expires_at, :utc_datetime_usec, null: false

      add :transaction_id,
          references(:point_transactions,
            type: :string,
            with: [point_id: :point_id],
            on_delete: :restrict
          )

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:point_payment_intents, [:app_id, :external_order_id])
    create unique_index(:point_payment_intents, [:transaction_id])

    create constraint(:point_payment_intents, :point_payment_valid,
             check:
               "amount > 0 AND status IN ('pending', 'succeeded', 'canceled', 'expired') AND ((status = 'succeeded') = (transaction_id IS NOT NULL))"
           )
  end
end

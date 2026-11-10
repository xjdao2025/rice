defmodule Rice.Repo.Migrations.CreatePointSpendApprovals do
  use Ecto.Migration

  def change do
    create table(:point_spend_policies, primary_key: false) do
      add :id, :string, primary_key: true
      add :point_id, :string, null: false

      add :account_id,
          references(:point_accounts,
            type: :string,
            with: [point_id: :point_id],
            on_delete: :restrict
          ),
          null: false

      add :version, :integer, null: false
      add :threshold, :integer, null: false
      add :current, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:point_spend_policies, [:id, :account_id, :point_id])
    create unique_index(:point_spend_policies, [:account_id, :version])
    create unique_index(:point_spend_policies, [:account_id], where: "current")

    create constraint(:point_spend_policies, :point_spend_policy_valid,
             check: "version > 0 AND threshold >= 2"
           )

    create table(:point_spend_policy_signers, primary_key: false) do
      add :id, :string, primary_key: true

      add :policy_id, references(:point_spend_policies, type: :string, on_delete: :restrict),
        null: false

      add :user_id, references(:users, type: :string, on_delete: :restrict), null: false
    end

    create unique_index(:point_spend_policy_signers, [:id, :policy_id])
    create unique_index(:point_spend_policy_signers, [:policy_id, :user_id])

    create table(:point_spend_proposals, primary_key: false) do
      add :id, :string, primary_key: true
      add :point_id, :string, null: false
      add :account_id, :string, null: false

      add :policy_id,
          references(:point_spend_policies,
            type: :string,
            with: [account_id: :account_id, point_id: :point_id],
            on_delete: :restrict
          ),
          null: false

      add :proposer_id, references(:users, type: :string, on_delete: :restrict), null: false
      add :action, :string, null: false
      add :amount, :bigint, null: false
      add :payload, :map, null: false
      add :request_hash, :string, null: false
      add :idempotency_key, :string, null: false
      add :expires_at, :utc_datetime_usec, null: false

      add :transaction_id,
          references(:point_transactions,
            type: :string,
            with: [point_id: :point_id],
            on_delete: :restrict
          )

      add :execution_error, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:point_spend_proposals, [:id, :policy_id])
    create unique_index(:point_spend_proposals, [:account_id, :proposer_id, :idempotency_key])
    create unique_index(:point_spend_proposals, [:transaction_id])

    create constraint(:point_spend_proposals, :point_spend_proposal_valid,
             check:
               "(action IN ('transfer', 'reserve') AND amount > 0) OR (action = 'policy_change' AND amount = 0)"
           )

    create table(:point_spend_approvals, primary_key: false) do
      add :id, :string, primary_key: true
      add :policy_id, :string, null: false

      add :proposal_id,
          references(:point_spend_proposals,
            type: :string,
            with: [policy_id: :policy_id],
            on_delete: :restrict
          ),
          null: false

      add :signer_id,
          references(:point_spend_policy_signers,
            type: :string,
            with: [policy_id: :policy_id],
            on_delete: :restrict
          ),
          null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:point_spend_approvals, [:proposal_id, :signer_id])
  end
end

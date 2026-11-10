defmodule Rice.Repo.Migrations.CreatePointIssuanceApprovals do
  use Ecto.Migration

  def change do
    create table(:point_issuance_policies, primary_key: false) do
      add :id, :string, primary_key: true
      add :point_id, references(:points, type: :string, on_delete: :restrict), null: false
      add :version, :integer, null: false
      add :threshold, :integer, null: false
      add :current, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:point_issuance_policies, [:id, :point_id])
    create unique_index(:point_issuance_policies, [:point_id, :version])
    create unique_index(:point_issuance_policies, [:point_id], where: "current")

    create constraint(:point_issuance_policies, :positive_issuance_policy,
             check: "version > 0 AND threshold > 0"
           )

    create table(:point_issuance_signers, primary_key: false) do
      add :id, :string, primary_key: true

      add :policy_id, references(:point_issuance_policies, type: :string, on_delete: :restrict),
        null: false

      add :user_id, references(:users, type: :string, on_delete: :restrict), null: false
    end

    create unique_index(:point_issuance_signers, [:id, :policy_id])
    create unique_index(:point_issuance_signers, [:policy_id, :user_id])

    create table(:point_issuances, primary_key: false) do
      add :id, :string, primary_key: true
      add :point_id, :string, null: false

      add :policy_id,
          references(:point_issuance_policies,
            type: :string,
            with: [point_id: :point_id],
            on_delete: :restrict
          ),
          null: false

      add :proposer_id, references(:users, type: :string, on_delete: :restrict), null: false
      add :kind, :string, null: false
      add :reason, :text, null: false
      add :recipients, :map, null: false
      add :total, :bigint, null: false
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

    create unique_index(:point_issuances, [:id, :policy_id])
    create unique_index(:point_issuances, [:point_id, :proposer_id, :idempotency_key])
    create unique_index(:point_issuances, [:transaction_id])

    create constraint(:point_issuances, :valid_point_issuance,
             check: "kind IN ('initial_allocation', 'mint') AND total > 0 AND btrim(reason) <> ''"
           )

    create table(:point_issuance_approvals, primary_key: false) do
      add :id, :string, primary_key: true
      add :policy_id, :string, null: false

      add :issuance_id,
          references(:point_issuances,
            type: :string,
            with: [policy_id: :policy_id],
            on_delete: :restrict
          ),
          null: false

      add :signer_id,
          references(:point_issuance_signers,
            type: :string,
            with: [policy_id: :policy_id],
            on_delete: :restrict
          ),
          null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:point_issuance_approvals, [:issuance_id, :signer_id])
  end
end

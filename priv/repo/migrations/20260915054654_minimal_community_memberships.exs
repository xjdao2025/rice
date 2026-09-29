defmodule Rice.Repo.Migrations.AddNodeMembershipApplications do
  use Ecto.Migration
  import Rice.Migration

  def change do
    create table(:node_memberships, primary_key: false) do
      tsid_primary_key()
      add :node_id, tsid_references(:nodes), null: false
      add :user_id, tsid_references(:users), null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:node_memberships, [:node_id, :user_id])
    create index(:node_memberships, [:user_id])

    create table(:node_join_applications, primary_key: false) do
      tsid_primary_key()
      add :node_id, tsid_references(:nodes), null: false
      add :user_id, tsid_references(:users), null: false
      add :reason, :text, null: false, default: ""
      add :status, :string, null: false, default: "pending"
      add :review_reason, :text
      add :reviewer_id, tsid_references(:users)
      add :reviewed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:node_join_applications, [:node_id, :user_id],
             name: :node_join_applications_one_pending,
             where: "status = 'pending'"
           )

    create index(:node_join_applications, [:user_id, :id])

    create constraint(:node_join_applications, :node_join_application_status,
             check: "status IN ('pending', 'approved', 'rejected')"
           )
  end
end

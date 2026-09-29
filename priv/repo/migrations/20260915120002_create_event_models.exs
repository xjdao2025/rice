defmodule Rice.Repo.Migrations.CreateEventModels do
  use Ecto.Migration
  import Rice.Migration

  def change do
    create table(:events, primary_key: false) do
      tsid_primary_key()
      add :creator_id, tsid_references(:users), null: false
      add :node_id, tsid_references(:nodes), null: false
      add :title, :string, size: 128, null: false
      add :description, :text, null: false
      add :location, :string, size: 256, null: false
      add :status, :string, size: 24, null: false, default: "draft"
      add :fee_amount, :bigint, null: false, default: 0
      add :capacity, :integer, null: false
      add :application_deadline, :utc_datetime_usec, null: false
      add :starts_at, :utc_datetime_usec, null: false
      add :ends_at, :utc_datetime_usec, null: false
      add :published_at, :utc_datetime_usec
      add :client_request_id, :string, size: 128
      timestamps(type: :utc_datetime_usec)
    end

    create index(:events, [:node_id, :id])
    create index(:events, [:creator_id, :id])
    create index(:events, [:status, :starts_at])
    create unique_index(:events, [:creator_id, :client_request_id])

    create unique_index(:events, [:creator_id],
             name: :events_one_draft_per_creator,
             where: "status = 'draft'"
           )

    create constraint(:events, :events_status,
             check: "status in ('draft','open','in_progress','completed','cancelled')"
           )

    create constraint(:events, :events_fee_capacity, check: "fee_amount >= 0 and capacity > 0")

    create constraint(:events, :events_times,
             check: "application_deadline <= starts_at and starts_at < ends_at"
           )

    create table(:event_applications, primary_key: false) do
      tsid_primary_key()
      add :event_id, tsid_references(:events), null: false
      add :user_id, tsid_references(:users), null: false
      add :reason, :string, size: 512, null: false, default: ""
      add :status, :string, size: 24, null: false, default: "pending"
      add :payment_status, :string, size: 16, null: false, default: "none"
      add :fee_amount, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:event_applications, [:event_id, :user_id])
    create index(:event_applications, [:user_id, :id])

    create constraint(:event_applications, :event_applications_status,
             check:
               "status in ('pending','approved','rejected','removed','not_selected','cancelled')"
           )

    create constraint(:event_applications, :event_applications_payment,
             check:
               "(fee_amount = 0 and payment_status = 'none') or " <>
                 "(fee_amount > 0 and payment_status = 'reserved' and status in ('pending','approved')) or " <>
                 "(fee_amount > 0 and payment_status = 'refunded' and status in ('rejected','removed','not_selected','cancelled')) or " <>
                 "(fee_amount > 0 and payment_status = 'settled' and status = 'approved')"
           )

    create table(:event_history, primary_key: false) do
      tsid_primary_key()
      add :event_id, tsid_references(:events), null: false
      add :application_id, tsid_references(:event_applications)
      add :actor_id, tsid_references(:users)
      add :action, :string, size: 40, null: false
      add :from_status, :string, size: 24
      add :to_status, :string, size: 24, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:event_history, [:event_id, :id])
  end
end

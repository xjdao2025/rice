defmodule Rice.Points.Issuance do
  use Rice.Schema

  schema "point_issuances" do
    belongs_to :point, Rice.Points.Point
    belongs_to :policy, Rice.Points.IssuancePolicy
    belongs_to :proposer, Rice.Accounts.User
    field :kind, :string
    field :reason, :string
    field :recipients, :map, redact: true
    field :total, :integer
    field :request_hash, :string
    field :idempotency_key, :string
    field :expires_at, :utc_datetime_usec
    belongs_to :transaction, Rice.Points.Transaction
    field :execution_error, :string
    timestamps()
  end
end

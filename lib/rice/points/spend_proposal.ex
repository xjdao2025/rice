defmodule Rice.Points.SpendProposal do
  use Rice.Schema

  schema "point_spend_proposals" do
    belongs_to :point, Rice.Points.Point
    belongs_to :account, Rice.Points.Account
    belongs_to :policy, Rice.Points.SpendPolicy
    belongs_to :proposer, Rice.Accounts.User
    field :action, :string
    field :amount, :integer
    field :payload, :map, redact: true
    field :request_hash, :string
    field :idempotency_key, :string
    field :expires_at, :utc_datetime_usec
    belongs_to :transaction, Rice.Points.Transaction
    field :execution_error, :string
    timestamps()
  end
end

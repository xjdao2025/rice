defmodule Rice.Points.Transaction do
  use Rice.Schema

  schema "point_transactions" do
    field :idempotency_scope, :string
    belongs_to :point, Rice.Points.Point
    field :kind, :string
    field :public_note, :string
    field :private_note, :string, redact: true
    has_many :recipients, Rice.Points.Recipient
    field :actor_id, :string
    field :source_app_id, :string
    field :reference_type, :string
    field :reference_id, :string
    field :business_outcome_uri, :string
    belongs_to :reverses_transaction, Rice.Points.Transaction
    field :idempotency_key, :string
    field :request_hash, :string
    timestamps(updated_at: false)
  end
end

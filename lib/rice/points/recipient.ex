defmodule Rice.Points.Recipient do
  use Rice.Schema

  schema "point_recipients" do
    belongs_to :point, Rice.Points.Point
    belongs_to :transaction, Rice.Points.Transaction
    belongs_to :account, Rice.Points.Account
    field :amount, :integer
    field :note, :string, redact: true
    timestamps(updated_at: false)
  end
end

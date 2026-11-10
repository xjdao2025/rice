defmodule Rice.Points.Entry do
  use Rice.Schema

  schema "point_entries" do
    belongs_to :point, Rice.Points.Point
    belongs_to :transaction, Rice.Points.Transaction
    belongs_to :account, Rice.Points.Account
    field :bucket, :string
    field :delta, :integer
    timestamps(updated_at: false)
  end
end

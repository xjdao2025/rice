defmodule Rice.Points.Balance do
  use Rice.Schema

  schema "point_balances" do
    field :owner_type, :string
    belongs_to :account, Rice.Points.Account
    field :available, :integer, default: 0
    field :held, :integer, default: 0
    timestamps()
  end
end

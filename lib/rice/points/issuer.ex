defmodule Rice.Points.Issuer do
  use Rice.Schema

  schema "point_issuers" do
    belongs_to :point, Rice.Points.Point
    belongs_to :account, Rice.Points.Account
    field :supply_cap, :integer
    field :issued, :integer, default: 0
    field :burned, :integer, default: 0
    timestamps()
  end
end

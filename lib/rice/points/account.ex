defmodule Rice.Points.Account do
  use Rice.Schema

  schema "point_accounts" do
    belongs_to :point, Rice.Points.Point
    field :owner_type, :string
    field :owner_id, :string
    field :status, :string, default: "active"
    timestamps()
  end
end

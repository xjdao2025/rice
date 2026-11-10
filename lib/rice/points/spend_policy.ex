defmodule Rice.Points.SpendPolicy do
  use Rice.Schema

  schema "point_spend_policies" do
    belongs_to :point, Rice.Points.Point
    belongs_to :account, Rice.Points.Account
    field :version, :integer
    field :threshold, :integer
    field :current, :boolean, default: false
    timestamps()
  end
end

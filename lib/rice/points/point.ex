defmodule Rice.Points.Point do
  use Rice.Schema

  schema "points" do
    field :issuer_community_id, :string
    field :code, :string
    field :status, :string, default: "active"
    timestamps()
  end
end

defmodule Rice.Points.IssuancePolicy do
  use Rice.Schema

  schema "point_issuance_policies" do
    belongs_to :point, Rice.Points.Point
    field :version, :integer
    field :threshold, :integer
    field :current, :boolean, default: false
    has_many :signers, Rice.Points.IssuanceSigner, foreign_key: :policy_id
    timestamps()
  end
end

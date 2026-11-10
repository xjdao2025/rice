defmodule Rice.Points.IssuanceApproval do
  use Rice.Schema

  schema "point_issuance_approvals" do
    belongs_to :policy, Rice.Points.IssuancePolicy
    belongs_to :issuance, Rice.Points.Issuance
    belongs_to :signer, Rice.Points.IssuanceSigner
    timestamps(updated_at: false)
  end
end

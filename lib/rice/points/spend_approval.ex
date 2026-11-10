defmodule Rice.Points.SpendApproval do
  use Rice.Schema

  schema "point_spend_approvals" do
    belongs_to :policy, Rice.Points.SpendPolicy
    belongs_to :proposal, Rice.Points.SpendProposal
    belongs_to :signer, Rice.Points.SpendSigner
    timestamps(updated_at: false)
  end
end

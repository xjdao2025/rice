defmodule Rice.Points.IssuanceSigner do
  use Rice.Schema

  schema "point_issuance_signers" do
    belongs_to :policy, Rice.Points.IssuancePolicy
    belongs_to :user, Rice.Accounts.User
  end
end

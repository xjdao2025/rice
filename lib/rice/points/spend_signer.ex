defmodule Rice.Points.SpendSigner do
  use Rice.Schema

  schema "point_spend_policy_signers" do
    belongs_to :policy, Rice.Points.SpendPolicy
    belongs_to :user, Rice.Accounts.User
  end
end

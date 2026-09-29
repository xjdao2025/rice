defmodule Rice.Community.Membership do
  @moduledoc "社区正式成员与管理员；nodes.user_id 始终保留创始管理员身份。"
  use Rice.Schema

  schema "node_memberships" do
    field :role, :string, default: "member"
    belongs_to :node, Rice.Community.Node
    belongs_to :user, Rice.Accounts.User
    timestamps()
  end

  def changeset(membership) do
    membership
    |> change()
    |> validate_required([:node_id, :user_id, :role])
    |> validate_inclusion(:role, ~w(member admin))
    |> unique_constraint([:node_id, :user_id])
    |> foreign_key_constraint(:node_id)
    |> foreign_key_constraint(:user_id)
  end
end

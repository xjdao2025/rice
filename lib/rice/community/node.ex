defmodule Rice.Community.Node do
  @moduledoc "节点(原 t_node)。删掉了 user_did —— 那是 users.did 的副本。"
  use Rice.Schema

  schema "nodes" do
    field :legacy_id, :string
    field :name, :string
    field :description, :string, default: ""
    field :position, :integer, default: 0
    field :grain_balance, :integer, default: 0
    field :grain_frozen_balance, :integer, default: 0

    belongs_to :user, Rice.Accounts.User
    belongs_to :logo, Rice.Files.Attachment
    has_many :memberships, Rice.Community.Membership
    has_many :applications, Rice.Community.JoinApplication

    timestamps()
  end

  def changeset(node, attrs) do
    node
    |> cast(attrs, [:legacy_id, :name, :description, :position, :user_id, :logo_id])
    |> validate_required([:name])
    |> validate_length(:name, max: 64)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:logo_id)
    |> unique_constraint(:legacy_id)
  end
end

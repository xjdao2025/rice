defmodule Rice.Grains.Receipt do
  @moduledoc "Immutable reserve/refund/settlement evidence for a single task or activity application."
  use Rice.Schema

  schema "grain_receipts" do
    field :kind, :string
    field :subject_uri, :string
    field :amount, :integer
    belongs_to :from_user, Rice.Accounts.User
    belongs_to :to_user, Rice.Accounts.User
    belongs_to :from_node, Rice.Community.Node
    belongs_to :to_node, Rice.Community.Node
    belongs_to :transfer, Rice.Grains.Transfer
    timestamps(updated_at: false)
  end

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :kind,
      :subject_uri,
      :amount,
      :from_user_id,
      :to_user_id,
      :from_node_id,
      :to_node_id,
      :transfer_id
    ])
    |> validate_required([:kind, :subject_uri, :amount])
    |> validate_inclusion(:kind, ~w(reserved refunded settled))
    |> validate_number(:amount, greater_than: 0)
    |> unique_constraint([:subject_uri, :kind])
    |> unique_constraint(:subject_uri, name: :grain_receipts_one_outcome)
    |> check_constraint(:from_user_id, name: :grain_receipts_from_account)
    |> check_constraint(:to_user_id, name: :grain_receipts_to_account)
  end
end

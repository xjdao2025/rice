defmodule Rice.Events.Application do
  @moduledoc "每人每期一份候选申请；录取状态和原冻结费用一起变更。"
  use Rice.Schema

  schema "event_applications" do
    field :reason, :string, default: ""
    field(:contact, :string)
    field :status, :string, default: "pending"
    field :payment_status, :string, default: "none"
    field :round, :integer, default: 1
    field :fee_amount, :integer, default: 0
    belongs_to :settlement_node, Rice.Community.Node
    belongs_to :event, Rice.Events.Event
    belongs_to :user, Rice.Accounts.User
    timestamps()
  end

  def changeset(application, attrs) do
    application
    |> cast(attrs, [:reason, :contact])
    |> update_change(:reason, &trim/1)
    |> update_change(:contact, &trim/1)
    |> validate_required([:contact])
    |> validate_length(:contact, max: 256)
    |> validate_length(:reason, max: 512)
    |> unique_constraint([:event_id, :round, :user_id])
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_), do: ""
end

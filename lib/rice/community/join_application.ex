defmodule Rice.Community.JoinApplication do
  @moduledoc "每次入会申请及其审批结果；拒绝后新建申请，保留旧记录。"
  use Rice.Schema

  schema "node_join_applications" do
    field :reason, :string, default: ""
    field :status, :string, default: "pending"
    field :review_reason, :string
    field :reviewed_at, :utc_datetime_usec
    belongs_to :node, Rice.Community.Node
    belongs_to :user, Rice.Accounts.User
    belongs_to :reviewer, Rice.Accounts.User
    timestamps()
  end

  def create_changeset(application, attrs) do
    application
    |> cast(attrs, [:reason])
    |> update_change(:reason, &trim/1)
    |> validate_length(:reason, max: 512)
    |> unique_constraint([:node_id, :user_id], name: :node_join_applications_one_pending)
    |> foreign_key_constraint(:node_id)
    |> foreign_key_constraint(:user_id)
  end

  def review_changeset(application, reviewer, status, attrs) do
    application
    |> cast(attrs, [:review_reason])
    |> update_change(:review_reason, &trim/1)
    |> validate_length(:review_reason, max: 512)
    |> put_change(:status, status)
    |> put_change(:reviewer_id, reviewer.id)
    |> put_change(:reviewed_at, DateTime.utc_now())
  end

  defp trim(nil), do: ""
  defp trim(value), do: String.trim(value)
end

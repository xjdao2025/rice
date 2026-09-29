defmodule Rice.Tasks.Application do
  @moduledoc "用户对任务的申请；可被发布者拒绝，任命一人后其余申请也显示为未入选。"
  use Rice.Schema

  schema "task_applications" do
    field(:reason, :string, default: "")
    field(:contact, :string)
    field(:rejected_at, :utc_datetime_usec)
    field(:round, :integer, default: 1)
    field(:final_status, :string)

    belongs_to(:task, Rice.Tasks.Task)
    belongs_to(:user, Rice.Accounts.User)

    timestamps()
  end

  def create_changeset(application, attrs) do
    application
    |> cast(attrs, [:reason, :contact])
    |> update_change(:reason, &trim/1)
    |> update_change(:contact, &trim/1)
    |> validate_required([:contact])
    |> validate_length(:contact, max: 256)
    |> validate_length(:reason, max: 512)
    |> unique_constraint([:task_id, :round, :user_id])
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_), do: ""
end

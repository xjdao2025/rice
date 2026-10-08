defmodule Rice.Tasks.Application do
  @moduledoc "用户对任务的申请；每轮接收者各占一个奖励名额。"
  use Rice.Schema

  schema "task_applications" do
    field(:reason, :string, default: "")
    field(:contact, :string)
    field(:rejected_at, :utc_datetime_usec)
    field(:round, :integer, default: 1)
    field(:final_status, :string)
    field(:appointed_at, :utc_datetime_usec)
    field(:appointment_reason, :string)
    field(:reward_slot, :integer)
    field(:status, :string, default: "pending")

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
end

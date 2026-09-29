defmodule Rice.Tasks.Event do
  @moduledoc "任务状态变化的公开、不可覆盖记录。"
  use Rice.Schema

  schema "task_events" do
    field(:from_status, :string)
    field(:to_status, :string)
    field(:detail, :string)
    field(:before, :map)
    field(:after, :map)

    belongs_to(:task, Rice.Tasks.Task)
    belongs_to(:actor, Rice.Accounts.User)

    timestamps(updated_at: false)
  end

  def create_changeset(event, attrs) do
    event
    |> cast(attrs, [:task_id, :actor_id, :from_status, :to_status, :detail, :before, :after])
    |> validate_required([:task_id, :to_status])
    |> update_change(:detail, &optional_trim/1)
    |> validate_length(:detail, max: 512)
    |> foreign_key_constraint(:task_id)
    |> foreign_key_constraint(:actor_id)
  end

  defp optional_trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp optional_trim(_), do: nil
end

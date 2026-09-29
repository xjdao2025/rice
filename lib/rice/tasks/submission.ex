defmodule Rice.Tasks.Submission do
  @moduledoc "承作人提交的结果与发布者的审核记录。每次重交都保留一行。"
  use Rice.Schema

  schema "task_submissions" do
    field(:body, :string)
    field(:review_reason, :string)
    field(:round, :integer, default: 1)
    field(:final_status, :string)

    belongs_to(:task, Rice.Tasks.Task)
    belongs_to(:user, Rice.Accounts.User)

    timestamps()
  end

  def create_changeset(submission, attrs) do
    submission
    |> cast(attrs, [:body])
    |> validate_required([:body])
    |> update_change(:body, &trim/1)
    |> validate_length(:body, min: 1, max: 4000)
  end

  def review_changeset(submission, reason) do
    submission
    |> change(review_reason: String.trim(reason))
    |> validate_required([:review_reason])
    |> validate_length(:review_reason, min: 1, max: 512)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_), do: ""
end

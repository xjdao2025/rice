defmodule Rice.Workers.ExpireTasks do
  @moduledoc "推进已到期任务的失效和交付超时状态。"
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl true
  def perform(_job) do
    case Rice.Tasks.check_due_tasks() do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end

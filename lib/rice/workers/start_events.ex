defmodule Rice.Workers.StartEvents do
  @moduledoc "启动到时活动并退还未入选候选费用；失败交给 Oban 重试。"
  use Oban.Worker, queue: :default, max_attempts: 10

  @impl true
  def perform(_job), do: Rice.Events.start_due_events()
end

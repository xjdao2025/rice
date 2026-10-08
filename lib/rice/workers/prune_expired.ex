defmodule Rice.Workers.PruneExpired do
  @moduledoc "清掉过期的 API 令牌和验证码。验证码会多留一天 —— 发码的每日上限按它计数。"
  use Oban.Worker, queue: :default, max_attempts: 3

  @impl true
  def perform(_job) do
    Rice.Accounts.prune_expired()
    :ok
  end
end

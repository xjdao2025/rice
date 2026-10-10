defmodule Rice.Workers.ModeratePosts do
  @moduledoc "每分钟补审一轮绕过发布前审核的新帖,见 `Rice.Moderation.Posts`。"
  use Oban.Worker, queue: :default, max_attempts: 1

  @impl true
  def perform(_job), do: Rice.Moderation.Posts.scan()
end

defmodule Rice.ObanTest.EchoWorker do
  @moduledoc false
  use Oban.Worker, queue: :default

  @impl true
  def perform(%Oban.Job{args: %{"to" => pid_b64, "msg" => msg}}) do
    pid = pid_b64 |> Base.decode64!() |> :erlang.binary_to_term()
    send(pid, {:echo, msg})
    :ok
  end
end

defmodule Rice.ObanTest do
  @moduledoc """
  Oban 接线的冒烟测试:任务能入队、能执行、能和业务写入放进同一个事务。
  这是替代 core 那套 Hangfire + Redis 的基础(见 docs/backend-migration-plan.md §4.5)。
  """
  use Rice.DataCase, async: true
  use Oban.Testing, repo: Rice.Repo

  alias Rice.ObanTest.EchoWorker

  defp self_ref, do: self() |> :erlang.term_to_binary() |> Base.encode64()

  test "drain 后任务被执行" do
    {:ok, _} = Oban.insert(EchoWorker.new(%{to: self_ref(), msg: "跑起来了"}))

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
    assert_received {:echo, "跑起来了"}
  end

  # 这是选 Oban 而不是外部消息队列的核心理由:任务表和业务表在同一个数据库,
  # 业务写入回滚时任务也一起回滚,不会出现"库里没数据但任务已经发出去"的空档。
  # core 用 CAP outbox 想解决的就是这个问题,而 CAP 至今一条消息都没发过。
  test "任务与业务写入共享同一个事务:回滚时任务不残留" do
    assert {:error, :nope, :boom, _} =
             Ecto.Multi.new()
             |> Oban.insert(:job, EchoWorker.new(%{to: self_ref(), msg: "不该发生"}))
             |> Ecto.Multi.run(:nope, fn _repo, _changes -> {:error, :boom} end)
             |> Rice.Repo.transaction()

    refute_enqueued(worker: EchoWorker)
  end

  test "任务与业务写入共享同一个事务:提交时任务落库" do
    assert {:ok, %{job: _}} =
             Ecto.Multi.new()
             |> Oban.insert(:job, EchoWorker.new(%{to: self_ref(), msg: "该发生"}))
             |> Ecto.Multi.run(:ok, fn _repo, _changes -> {:ok, :fine} end)
             |> Rice.Repo.transaction()

    assert_enqueued(worker: EchoWorker, args: %{"msg" => "该发生"})
  end
end

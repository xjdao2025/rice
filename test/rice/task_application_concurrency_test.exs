defmodule Rice.TaskApplicationConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Rice.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias Rice.{Repo, Tasks}
  alias Rice.Tasks.{Application, Notification}

  test "独立连接并发拒绝不会重复通知，拒绝与任命只有一个成功" do
    supervisor = start_supervised!(Task.Supervisor)

    Sandbox.unboxed_run(Repo, fn ->
      publisher = task_publisher_fixture()
      worker = user_fixture()
      ids = [publisher.id, worker.id]

      try do
        node = funded_node_fixture(publisher, 100)

        {:ok, task} =
          Tasks.create_task(publisher, %{
            organizer_contact: "社区服务台",
            title: "并发拒绝",
            description: "候选处理",
            reward_amount: 20
          })

        {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})

        results =
          race(supervisor, [
            fn -> Tasks.reject_application(publisher, task, application.id) end,
            fn -> Tasks.reject_application(publisher, task, application.id) end
          ])

        assert Enum.all?(results, &match?({:ok, _}, &1))

        assert Repo.aggregate(
                 from(n in Notification, where: n.recipient_id == ^worker.id),
                 :count
               ) == 1

        {:ok, competing} =
          Tasks.create_task(publisher, %{
            organizer_contact: "社区服务台",
            title: "拒绝与任命竞争",
            description: "不允许已拒者被选定",
            reward_amount: 20
          })

        {:ok, application} = Tasks.apply(worker, competing, %{contact: "测试联系方式"})

        outcomes =
          race(supervisor, [
            fn -> Tasks.reject_application(publisher, competing, application.id) end,
            fn -> Tasks.appoint(publisher, competing, application.id) end
          ])

        assert Enum.count(outcomes, &match?({:ok, _}, &1)) == 1
        assert Enum.count(outcomes, &(&1 == {:error, :conflict})) == 1
        final_task = Repo.get!(Rice.Tasks.Task, competing.id)
        final_application = Repo.get!(Application, application.id)

        if final_task.status == "open" do
          assert is_nil(final_task.assignee_id)
          assert %DateTime{} = final_application.rejected_at
        else
          assert final_task.status == "in_progress"
          assert final_task.assignee_id == worker.id
          assert is_nil(final_application.rejected_at)
        end

        assert Repo.aggregate(
                 from(n in Notification,
                   where: n.task_id == ^competing.id and n.recipient_id == ^worker.id
                 ),
                 :count
               ) == 1

        assert %{grain_balance: 60, grain_frozen_balance: 40} =
                 Repo.get!(Rice.Community.Node, node.id)

        assert Repo.aggregate(
                 from(r in Rice.Grains.Receipt, where: r.from_node_id == ^node.id),
                 :count
               ) == 2

        # The shared community account, not a creator's wallet, serializes spending.
        reserves =
          race(
            supervisor,
            for _ <- 1..2 do
              uri = "rice://tasks/#{Rice.Tsid.generate()}"

              fn ->
                Repo.transaction(fn ->
                  case Rice.Grains.reserve_business(Repo, {:node, node.id}, 40, uri) do
                    {:ok, receipt} -> receipt
                    {:error, reason} -> Repo.rollback(reason)
                  end
                end)
              end
            end
          )

        assert Enum.count(reserves, &match?({:ok, _}, &1)) == 1
        assert Enum.count(reserves, &(&1 == {:error, :insufficient_balance})) == 1
        {:ok, reserved} = Enum.find(reserves, &match?({:ok, _}, &1))

        refunds =
          race(
            supervisor,
            for _ <- 1..2 do
              fn ->
                Repo.transaction(fn ->
                  Rice.Grains.refund_business(Repo, {:node, node.id}, 40, reserved.subject_uri)
                end)
              end
            end
          )

        assert Enum.all?(refunds, &match?({:ok, {:ok, _}}, &1))

        assert %{grain_balance: 60, grain_frozen_balance: 40} =
                 Repo.get!(Rice.Community.Node, node.id)

        assert Rice.Grains.reconcile().ok?
      after
        cleanup(ids)
      end
    end)
  end

  defp race(supervisor, actions) do
    parent = self()

    tasks =
      Enum.map(actions, fn action ->
        Task.Supervisor.async_nolink(supervisor, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:ready, self()})

            receive do
              :run -> action.()
            after
              5_000 -> raise "concurrency test barrier timed out"
            end
          end)
        end)
      end)

    workers =
      Enum.map(tasks, fn _ ->
        assert_receive {:ready, worker}, 5_000
        worker
      end)

    Enum.each(workers, &send(&1, :run))
    Enum.map(tasks, &Task.await(&1, 15_000))
  end

  defp cleanup(ids) do
    node_ids = Repo.all(from(n in Rice.Community.Node, where: n.user_id in ^ids, select: n.id))
    task_ids = Repo.all(from(t in Rice.Tasks.Task, where: t.creator_id in ^ids, select: t.id))
    Repo.delete_all(from(n in Notification, where: n.recipient_id in ^ids or n.actor_id in ^ids))

    Repo.delete_all(
      from(r in Rice.Grains.Receipt,
        where:
          r.from_user_id in ^ids or r.to_user_id in ^ids or r.from_node_id in ^node_ids or
            r.to_node_id in ^node_ids
      )
    )

    Repo.delete_all(
      from(t in Rice.Grains.Transfer, where: t.from_user_id in ^ids or t.to_user_id in ^ids)
    )

    Repo.delete_all(from(t in Rice.Tasks.Task, where: t.id in ^task_ids))
    Repo.delete_all(from(n in Rice.Community.Node, where: n.user_id in ^ids))
    Repo.delete_all(from(u in Rice.Accounts.User, where: u.id in ^ids))
  end
end

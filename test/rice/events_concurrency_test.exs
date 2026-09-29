defmodule Rice.EventsConcurrencyTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import Rice.Fixtures
  alias Ecto.Adapters.SQL.Sandbox
  alias Rice.{Events, Repo}
  alias Rice.Events.{Application, Event, EventHistory}

  test "独立数据库连接并发申请、录取、开始及结束不会重复冻退付或超额" do
    supervisor = start_supervised!(Task.Supervisor)

    # Separate committed connections exercise real row locks, not a shared sandbox connection.
    Sandbox.unboxed_run(Repo, fn ->
      users = for _ <- 1..4, do: user_fixture()
      [host, first, second, late] = users
      ids = Enum.map(users, & &1.id)

      try do
        node = node_fixture(%{user_id: host.id})
        for user <- [first, second, late], do: Rice.Grains.grant(user, 100)
        event = event!(host, node)

        duplicates =
          race(supervisor, [
            fn -> Events.apply(first, event, %{contact: "测试联系方式"}) end,
            fn -> Events.apply(first, event, %{contact: "测试联系方式"}) end
          ])

        assert Enum.all?(duplicates, &match?({:ok, _}, &1))
        assert Repo.aggregate(from(a in Application, where: a.event_id == ^event.id), :count) == 1
        assert balance(first).grain_frozen_balance == 20

        {:ok, event} = Events.apply(second, event, %{contact: "测试联系方式"})
        [a, b] = event.applications

        approval =
          race(supervisor, [
            fn -> Events.approve_application(host, event, a.id) end,
            fn -> Events.approve_application(host, event, b.id) end
          ])

        assert Enum.count(approval, &match?({:ok, _}, &1)) == 1
        assert Enum.count(approval, &(&1 == {:error, :capacity_full})) == 1

        assert Repo.aggregate(
                 from(a in Application, where: a.event_id == ^event.id and a.status == "approved"),
                 :count
               ) == 1

        late_applications =
          race(supervisor, [
            fn -> Events.apply(late, event, %{contact: "测试联系方式"}) end,
            fn -> Events.apply(late, event, %{contact: "测试联系方式"}) end
          ])

        assert late_applications == [{:error, :capacity_full}, {:error, :capacity_full}]
        refute Repo.get_by(Application, event_id: event.id, user_id: late.id)
        assert balance(late).grain_balance == 100
        assert balance(late).grain_frozen_balance == 0
        refute Repo.exists?(from r in Rice.Grains.Receipt, where: r.from_user_id == ^late.id)

        now = DateTime.utc_now()

        Repo.update_all(from(e in Event, where: e.id == ^event.id),
          set: [
            application_deadline: DateTime.add(now, -30),
            starts_at: DateTime.add(now, -20),
            ends_at: DateTime.add(now, -10)
          ]
        )

        starts =
          race(supervisor, [
            fn -> Events.start_event(event.id) end,
            fn -> Events.start_event(event.id) end
          ])

        assert Enum.all?(starts, &match?({:ok, _}, &1))

        assert Repo.aggregate(
                 from(h in EventHistory, where: h.event_id == ^event.id and h.action == "started"),
                 :count
               ) == 1

        finishes =
          race(supervisor, [
            fn -> Events.finish(host, event) end,
            fn -> Events.finish(host, event) end
          ])

        assert Enum.all?(finishes, &match?({:ok, _}, &1))
        assert balance(host).grain_balance == 0
        assert Repo.get!(Rice.Community.Node, node.id).grain_balance == 20
        assert balance(first).grain_frozen_balance == 0
        assert balance(second).grain_frozen_balance == 0
        assert balance(first).grain_balance + balance(second).grain_balance == 180

        assert Repo.aggregate(
                 from(t in Rice.Grains.Transfer,
                   where: t.to_node_id == ^node.id and t.kind == "event_fee"
                 ),
                 :count
               ) == 1

        # Cancellation and settlement compete for the same frozen fee; exactly one wins.
        before_balance = balance(first).grain_balance

        competing = event!(host, node)
        {:ok, competing} = Events.apply(first, competing, %{contact: "测试联系方式"})
        application = hd(competing.applications)
        {:ok, competing} = Events.approve_application(host, competing, application.id)
        now = DateTime.utc_now()

        Repo.update_all(from(e in Event, where: e.id == ^competing.id),
          set: [
            application_deadline: DateTime.add(now, -30),
            starts_at: DateTime.add(now, -20),
            ends_at: DateTime.add(now, -10)
          ]
        )

        outcomes =
          race(supervisor, [
            fn -> Events.finish(host, competing) end,
            fn -> Events.cancel(host, competing) end
          ])

        assert Enum.count(outcomes, &match?({:ok, _}, &1)) == 1
        assert Enum.count(outcomes, &(&1 == {:error, :conflict})) == 1
        final_application = Repo.get!(Application, application.id)
        assert final_application.payment_status in ["settled", "refunded"]
        assert balance(first).grain_frozen_balance == 0

        expected =
          if final_application.payment_status == "settled",
            do: before_balance - 20,
            else: before_balance

        assert balance(first).grain_balance == expected
        uri = "rice://event_applications/#{application.id}"

        assert Repo.aggregate(
                 from(r in Rice.Grains.Receipt,
                   where: r.subject_uri == ^uri and r.kind in ["settled", "refunded"]
                 ),
                 :count
               ) == 1
      after
        cleanup(ids)
      end
    end)
  end

  test "并发撤销只退款一次，撤销与审批互斥", _ctx do
    supervisor = start_supervised!(Task.Supervisor)

    Sandbox.unboxed_run(Repo, fn ->
      host = user_fixture()
      applicant = user_fixture()
      ids = [host.id, applicant.id]

      try do
        node = node_fixture(%{user_id: host.id})
        {:ok, _} = Rice.Grains.grant(applicant, 100)
        event = event!(host, node)
        {:ok, event} = Events.apply(applicant, event, %{contact: "测试联系方式"})
        own = hd(event.applications)

        repeated =
          race(supervisor, [
            fn -> Events.withdraw_application(applicant, event, own.id) end,
            fn -> Events.withdraw_application(applicant, event, own.id) end
          ])

        assert Enum.all?(repeated, &match?({:ok, _}, &1))
        assert balance(applicant).grain_balance == 100
        assert balance(applicant).grain_frozen_balance == 0
        assert Repo.get!(Application, own.id).status == "withdrawn"
        uri = "rice://event_applications/#{own.id}"

        assert Repo.aggregate(
                 from(r in Rice.Grains.Receipt,
                   where: r.subject_uri == ^uri and r.kind == "refunded"
                 ),
                 :count
               ) == 1

        assert Repo.aggregate(
                 from(h in EventHistory,
                   where: h.application_id == ^own.id and h.action == "application_withdrawn"
                 ),
                 :count
               ) == 1

        event = event!(host, node)
        {:ok, event} = Events.apply(applicant, event, %{contact: "测试联系方式"})
        own = hd(event.applications)

        competing =
          race(supervisor, [
            fn -> Events.withdraw_application(applicant, event, own.id) end,
            fn -> Events.approve_application(host, event, own.id) end
          ])

        assert Enum.count(competing, &match?({:ok, _}, &1)) == 1
        assert Enum.count(competing, &(&1 == {:error, :conflict})) == 1
        final = Repo.get!(Application, own.id)

        if final.status == "withdrawn" do
          assert final.payment_status == "refunded"
          assert balance(applicant).grain_balance == 100
          assert balance(applicant).grain_frozen_balance == 0
        else
          assert final.status == "approved"
          assert final.payment_status == "reserved"
          assert balance(applicant).grain_balance == 80
          assert balance(applicant).grain_frozen_balance == 20
        end
      after
        cleanup(ids)
      end
    end)
  end

  defp event!(host, node) do
    now = DateTime.utc_now()

    {:ok, event} =
      Events.create_event(host, %{
        organizer_contact: "社区服务台",
        node_id: node.id,
        title: "并发活动",
        description: "独立数据库连接",
        location: "测试地点",
        fee_amount: 20,
        capacity: 1,
        client_request_id: "race-#{System.unique_integer([:positive])}",
        application_deadline: DateTime.add(now, 1800),
        starts_at: DateTime.add(now, 3600),
        ends_at: DateTime.add(now, 7200)
      })

    event
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

  defp balance(user), do: Repo.get!(Rice.Accounts.User, user.id)

  defp cleanup(ids) do
    event_ids = Repo.all(from(e in Event, where: e.creator_id in ^ids, select: e.id))
    Repo.delete_all(from(h in EventHistory, where: h.event_id in ^event_ids))

    Repo.delete_all(
      from(n in Rice.Tasks.Notification, where: n.recipient_id in ^ids or n.actor_id in ^ids)
    )

    Repo.delete_all(
      from(r in Rice.Grains.Receipt, where: r.from_user_id in ^ids or r.to_user_id in ^ids)
    )

    Repo.delete_all(
      from(t in Rice.Grains.Transfer, where: t.from_user_id in ^ids or t.to_user_id in ^ids)
    )

    Repo.delete_all(from(a in Application, where: a.event_id in ^event_ids))
    Repo.delete_all(from(e in Event, where: e.id in ^event_ids))
    Repo.delete_all(from(n in Rice.Community.Node, where: n.user_id in ^ids))
    Repo.delete_all(from(u in Rice.Accounts.User, where: u.id in ^ids))
  end
end

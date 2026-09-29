defmodule RiceWeb.Api.CommunityWalletTest do
  use RiceWeb.ConnCase, async: true
  import Ecto.Query
  alias Rice.{Events, Grains, Repo, Tasks}
  alias Rice.Community.Node

  test "社区账户独立，转入要授权且幂等，错误金额不改写" do
    {owner, token} = user_with_token()
    {_other, other_token} = user_with_token()
    node = node_fixture(%{user_id: owner.id})
    {:ok, _} = Grains.grant(owner, 100)
    path = "/api/nodes/#{node.id}/fund"
    request = %{amount: 40, client_request_id: "once"}

    assert build_conn() |> get("/api/nodes/#{node.id}/wallet") |> json_response(401)

    assert build_conn()
           |> authed(other_token)
           |> get("/api/nodes/#{node.id}/wallet")
           |> json_response(403)

    assert build_conn() |> authed(other_token) |> post(path, request) |> json_response(403)

    for invalid <- [-1, 1.5, "1.5", 0, 1_000_000_000, 9_223_372_036_854_775_808] do
      assert build_conn()
             |> authed(token)
             |> post(path, %{request | amount: invalid})
             |> json_response(422)
    end

    assert Grains.wallet(node).balance == 0
    assert Grains.wallet(owner).balance == 100

    for _ <- 1..2 do
      result = build_conn() |> authed(token) |> post(path, request) |> json_response(200)
      assert result["data"]["balance"] == 40
    end

    assert build_conn()
           |> authed(token)
           |> post(path, %{request | amount: 41})
           |> json_response(409)

    assert build_conn()
           |> authed(token)
           |> post(path, %{amount: 61, client_request_id: "too-much"})
           |> json_response(422)

    assert Grains.wallet(owner).balance == 60
    assert Grains.wallet(node).balance == 40
    assert [%{kind: "community_fund", to_node: %{id: node_id}} | _] = Grains.wallet(owner).entries
    assert node_id == node.id
    assert Grains.reconcile().ok?
  end

  test "旧个人冻结任务依原账户退款和结算，社区余额不被迁移" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    node = Repo.get_by!(Node, user_id: publisher.id)
    {:ok, _} = Grains.grant(publisher, 100)

    for action <- [:cancel, :complete] do
      task = task_fixture(publisher)

      {:ok, task} =
        Repo.transaction(fn ->
          task =
            Repo.update!(
              Ecto.Changeset.change(task, reward_amount: 30, reward_status: "reserved")
            )

          {:ok, _} = Grains.reserve_business(Repo, publisher.id, 30, "rice://tasks/#{task.id}")
          task
        end)

      assert is_nil(task.funding_node_id)

      if action == :cancel do
        assert {:ok, _} = Tasks.cancel(publisher, task)
        assert {:error, :conflict} = Tasks.cancel(publisher, task)
        assert Grains.wallet(publisher).balance == 100
      else
        {:ok, application} = Tasks.apply(worker, task, %{contact: "参与者电话"})
        {:ok, task} = Tasks.appoint(publisher, task, application.id)
        {:ok, task} = Tasks.submit_result(worker, task, %{body: "已完成"})
        assert {:ok, _} = Tasks.approve_result(publisher, task, hd(task.submissions).id)
        assert Grains.wallet(publisher).balance == 70
        assert Grains.wallet(worker).balance == 30
      end

      assert Grains.wallet(node).balance == 0
      assert Grains.wallet(node).frozen == 0
      assert Grains.wallet(publisher).frozen == 0
      assert Grains.reconcile().ok?
    end
  end

  test "旧活动收费结算仍归原个人，不回填为社区收入" do
    host = user_fixture()
    participant = user_fixture()
    node = node_fixture(%{user_id: host.id})
    {:ok, _} = Grains.grant(participant, 100)
    now = DateTime.utc_now()

    {:ok, event} =
      Events.create_event(host, %{
        node_id: node.id,
        organizer_contact: "服务台",
        title: "历史活动",
        description: "原约定",
        location: "客厅",
        fee_amount: 10,
        capacity: 1,
        client_request_id: "legacy",
        application_deadline: DateTime.add(now, 60),
        starts_at: DateTime.add(now, 120),
        ends_at: DateTime.add(now, 180)
      })

    event = Repo.update!(Ecto.Changeset.change(event, settlement_node_id: nil))
    {:ok, event} = Events.apply(participant, event, %{contact: "参与者电话"})
    {:ok, event} = Events.approve_application(host, event, hd(event.applications).id)

    Repo.update_all(from(e in Rice.Events.Event, where: e.id == ^event.id),
      set: [
        application_deadline: DateTime.add(now, -30),
        starts_at: DateTime.add(now, -20),
        ends_at: DateTime.add(now, -10)
      ]
    )

    assert {:ok, _} = Events.finish(host, event)
    assert {:ok, _} = Events.finish(host, event)
    assert Grains.wallet(host).balance == 10
    assert Grains.wallet(participant).balance == 90
    assert Grains.wallet(node).balance == 0
    assert Grains.reconcile().ok?
  end
end

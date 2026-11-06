defmodule RiceWeb.Api.ListPerformanceTest do
  use RiceWeb.ConnCase, async: true

  alias Rice.{Community, Events, Repo, Tasks}
  alias RiceWeb.Api.{EventJSON, TaskJSON}

  test "批量作者资料只返回公开字段，加载头像并排除注销/停用账号" do
    avatar = attachment_fixture()
    author = user_fixture(%{email: "author@example.test", phone: "13800138000"})
    Repo.update!(Ecto.Changeset.change(author, avatar_id: avatar.id))
    deleted = user_fixture()
    disabled = user_fixture()
    Repo.update!(Ecto.Changeset.change(deleted, deleted_at: DateTime.utc_now()))
    Repo.update!(Ecto.Changeset.change(disabled, disabled_at: DateTime.utc_now()))

    data =
      build_conn()
      |> post("/api/users/profiles", %{
        dids: [author.did, author.did, deleted.did, disabled.did, "did:unknown"]
      })
      |> json_response(200)
      |> Map.fetch!("data")

    assert [profile] = data
    assert profile["did"] == author.did
    assert profile["avatar"]["id"] == avatar.id

    assert MapSet.new(Map.keys(profile)) ==
             MapSet.new(~w(id did handle nickname bio avatar node_member))
  end

  test "批量作者资料拒绝越界或畸形输入，空批次无查询" do
    for attrs <- [
          %{},
          %{dids: "did:bad"},
          %{dids: [nil]},
          %{dids: ["handle.test"]},
          %{dids: ["did:" <> String.duplicate("a", 257)]},
          %{dids: List.duplicate("did:author", 101)}
        ] do
      assert build_conn() |> post("/api/users/profiles", attrs) |> json_response(422)
    end

    assert build_conn() |> post("/api/users/profiles", %{dids: []}) |> json_response(200) == %{
             "data" => []
           }
  end

  test "批量作者读取的查询数不随作者数量增加，也不查钱包" do
    avatar = attachment_fixture()

    authors =
      for _ <- 1..12 do
        user_fixture() |> Ecto.Changeset.change(avatar_id: avatar.id) |> Repo.update!()
      end

    read = fn users ->
      queries(fn ->
        build_conn()
        |> post("/api/users/profiles", %{dids: Enum.map(users, & &1.did)})
        |> json_response(200)
      end)
    end

    first = read.([hd(authors)])
    many = read.(authors)
    assert length(first) == 2
    assert length(many) == 2
    refute Enum.any?(many, &String.contains?(&1, "semi_links"))
  end

  test "任务列表只加载本期承接者和本人申请，聚合计数/动作与详情一致" do
    host = task_publisher_fixture()
    task = task_fixture(host, %{capacity: 3}) |> Ecto.Changeset.change(round: 2) |> Repo.update!()
    worker = user_fixture()
    {:ok, application} = Tasks.apply(worker, task, %{contact: "私人联系方式", reason: "参与"})
    {:ok, task} = Tasks.appoint(host, task, application.id)
    {:ok, task} = Tasks.submit_result(worker, task, %{body: "本期成果"})

    applicants =
      for _ <- 1..12 do
        person = user_fixture()
        {:ok, _} = Tasks.apply(person, task, %{contact: "其他申请人的联系方式"})
        person
      end

    # Older rounds and reviewed submissions must not inflate list reads.
    for _ <- 1..12 do
      Repo.insert!(%Rice.Tasks.Application{
        task_id: task.id,
        user_id: user_fixture().id,
        round: 1,
        status: "expired",
        final_status: "expired"
      })

      Repo.insert!(%Rice.Tasks.Submission{
        task_id: task.id,
        user_id: worker.id,
        round: 1,
        body: String.duplicate("历史成果", 200),
        final_status: "approved"
      })
    end

    for user <- [nil, host, worker, hd(applicants)] do
      assert [listed] = Tasks.list_tasks(user).entries
      assert length(listed.applications) <= 2
      assert Enum.all?(listed.applications, &(&1.round == task.round))
      refute Ecto.assoc_loaded?(listed.submissions)
      refute Ecto.assoc_loaded?(listed.events)
      assert listed.list_summary.application_count == 13
      assert listed.list_summary.pending_results
      {:ok, detail} = Tasks.fetch_task(task.id, user)

      list_json =
        TaskJSON.index(%{page: %{entries: [listed], next_cursor: nil}, current_user: user}).data
        |> hd()

      detail_json = TaskJSON.show(%{task: detail, current_user: user}).data

      for key <- [
            :application_count,
            :appointed_count,
            :assignees,
            :my_status,
            :my_application_status,
            :allowed_actions,
            :can_manage,
            :published_at,
            :application_closed
          ] do
        assert list_json[key] == detail_json[key],
               "task #{key} differs for #{inspect(user && user.id)}"
      end
    end
  end

  test "活动列表只加载本人最新本期申请，人数与容量动作使用全量聚合" do
    host = user_fixture()
    node = node_fixture(%{user_id: host.id})
    now = DateTime.utc_now()

    {:ok, event} =
      Events.create_event(host, %{
        node_id: node.id,
        title: "列表活动",
        description: "活动说明",
        location: "活动地点",
        organizer_contact: "服务台",
        capacity: 2,
        fee_amount: 0,
        application_deadline: DateTime.add(now, 1800),
        starts_at: DateTime.add(now, 3600),
        ends_at: DateTime.add(now, 7200),
        client_request_id: "list-performance"
      })

    event = event |> Ecto.Changeset.change(round: 2) |> Repo.update!()

    applicants =
      for _ <- 1..12 do
        person = user_fixture()
        {:ok, _} = Events.apply(person, event, %{contact: "私人联系方式", reason: "本期申请"})
        person
      end

    reader = hd(applicants)
    {:ok, detail} = Events.fetch_event(event.id, reader)
    first = Events.own_application(detail, reader)
    {:ok, event} = Events.withdraw_application(reader, event, first.id)
    {:ok, event} = Events.apply(reader, event, %{contact: "新的私人联系方式"})
    {:ok, detail} = Events.fetch_event(event.id, reader)
    latest = Events.own_application(detail, reader)
    {:ok, event} = Events.approve_application(host, event, latest.id)
    second = Enum.find(event.applications, &(&1.user_id == Enum.at(applicants, 1).id))
    {:ok, event} = Events.approve_application(host, event, second.id)

    Repo.insert!(%Rice.Events.Application{
      event_id: event.id,
      user_id: reader.id,
      round: 1,
      contact: "往届私密数据",
      status: "withdrawn",
      payment_status: "none",
      fee_amount: 0
    })

    for user <- [nil, host, reader, List.last(applicants)] do
      assert [listed] = Events.list_events(user).entries
      assert length(listed.applications) <= 1
      refute Ecto.assoc_loaded?(listed.history)
      assert listed.list_summary == %{application_count: 13, approved_count: 2}
      {:ok, detail} = Events.fetch_event(event.id, user)

      list_json =
        EventJSON.index(%{page: %{entries: [listed], next_cursor: nil}, current_user: user}).data
        |> hd()

      detail_json = EventJSON.show(%{event: detail, current_user: user}).data

      for key <- [:application_count, :approved_count, :allowed_actions, :can_manage] do
        assert list_json[key] == detail_json[key], "event #{key} differs"
      end

      assert list_json.applications == []
      assert list_json.past_applications == []
      assert list_json.history == []
      if user && user.id == reader.id, do: assert(list_json.my_application.id == latest.id)
    end
  end

  test "节点目录不加载成员用户/管理员申请队列，仅本人身份和最新申请" do
    host = user_fixture()
    reader = user_fixture()
    node = node_fixture(%{user_id: host.id})

    for _ <- 1..12 do
      member = user_fixture()
      Repo.insert!(%Rice.Community.Membership{node_id: node.id, user_id: member.id})

      Repo.insert!(%Rice.Community.JoinApplication{
        node_id: node.id,
        user_id: member.id,
        reason: "其他人的私密理由"
      })
    end

    Repo.insert!(%Rice.Community.Membership{node_id: node.id, user_id: reader.id, role: "admin"})

    Repo.insert!(%Rice.Community.JoinApplication{
      node_id: node.id,
      user_id: reader.id,
      status: "rejected"
    })

    latest = Repo.insert!(%Rice.Community.JoinApplication{node_id: node.id, user_id: reader.id})

    for user <- [nil, host, reader] do
      assert [listed] = Community.list_nodes(user)
      assert length(listed.memberships) <= 1
      assert length(listed.applications) <= 1
      assert Enum.all?(listed.memberships, &(not Ecto.assoc_loaded?(&1.user)))
      assert Enum.all?(listed.applications, &(not Ecto.assoc_loaded?(&1.user)))
      assert Community.admin?(listed, user) == user in [host, reader]
      if user == reader, do: assert(hd(listed.applications).id == latest.id)
    end

    {:ok, detail} = Community.fetch_node(node.id, host)
    assert length(detail.memberships) == 13
    assert length(detail.applications) == 14
  end

  defp queries(fun) do
    ref = make_ref()
    owner = self()

    :ok =
      :telemetry.attach(
        ref,
        [:rice, :repo, :query],
        fn _, _, metadata, _ ->
          if self() == owner, do: send(owner, {ref, metadata.query})
        end,
        nil
      )

    try do
      fun.()

      Stream.repeatedly(fn -> receive do: ({^ref, query} -> query), after: (0 -> nil) end)
      |> Enum.take_while(& &1)
    after
      :telemetry.detach(ref)
    end
  end
end

defmodule RiceWeb.Api.TaskFlowTest do
  @moduledoc """
  多人任务从发布到收尾的完整 HTTP 流程,每一步都以五个身份各看一次详情。

  设 `TASK_FLOW_FIXTURE_DIR=<目录>` 运行时,会把每一步各身份看到的响应写成
  `multi-task-flow.json`(id 换成固定标签),给 rice-front 的集成测试当真实数据用:

      TASK_FLOW_FIXTURE_DIR=../rice-front/src/features/tasks/__fixtures__ \\
        mix test test/rice_web/api/task_flow_test.exs
  """
  use RiceWeb.ConnCase, async: true

  alias Rice.Accounts.User
  alias Rice.Community.Node
  alias Rice.Repo
  alias Rice.Tasks.Application

  @labels ~w(manager worker_a worker_b worker_c guest)
  @nicknames %{
    "manager" => "管理员",
    "worker_a" => "阿青",
    "worker_b" => "小林",
    "worker_c" => "小周",
    "guest" => "路人"
  }

  defp actor(label) do
    attrs = %{nickname: @nicknames[label], handle: "#{label}.flow.test"}

    user =
      if label == "manager",
        do: task_publisher_fixture(attrs),
        else: user_fixture(attrs)

    {:ok, token} = Rice.Accounts.issue_token(user)
    {user, token}
  end

  defp authed(token), do: build_conn() |> put_req_header("authorization", "Bearer " <> token)

  defp post_as(token, path, body \\ %{}), do: authed(token) |> post(path, body)

  defp detail(nil, task_id), do: build_conn() |> get(~p"/api/tasks/#{task_id}")
  defp detail(token, task_id), do: authed(token) |> get(~p"/api/tasks/#{task_id}")

  defp node_balance(publisher) do
    %{grain_balance: b, grain_frozen_balance: f} = Repo.get_by!(Node, user_id: publisher.id)
    {b, f}
  end

  defp balance(%User{id: id}), do: Repo.get!(User, id).grain_balance

  test "多人任务:发布、申请、指派、撤销、补位、交付、验收、提前结束,五个身份各自看到什么" do
    actors = Map.new(@labels, &{&1, actor(&1)})
    {manager, manager_token} = actors["manager"]
    {worker_a, token_a} = actors["worker_a"]
    {worker_b, token_b} = actors["worker_b"]
    {worker_c, token_c} = actors["worker_c"]
    {_guest, guest_token} = actors["guest"]
    funded_node_fixture(manager, 100)

    tokens = %{
      "manager" => manager_token,
      "worker_a" => token_a,
      "worker_b" => token_b,
      "worker_c" => token_c,
      "guest" => guest_token,
      "anonymous" => nil
    }

    recorder = start_recorder(actors)

    snapshot = fn name, task_id ->
      views =
        Map.new(tokens, fn {label, token} ->
          {label, json_response(detail(token, task_id), 200)["data"]}
        end)

      recorder.(name, views)
      views
    end

    # ── 1. 发布 ────────────────────────────────────────────────────────
    created =
      post_as(manager_token, ~p"/api/tasks", %{
        client_request_id: "multi-flow",
        title: "清理步道",
        description: "分三段各自清理",
        organizer_contact: "节点服务台",
        requirement: "拍照为证",
        capacity: 2,
        reward_amount: 30,
        application_deadline: "2099-09-21T09:00:00Z",
        execution_deadline: "2099-09-22T09:00:00Z"
      })
      |> json_response(201)

    task_id = created["data"]["id"]
    assert node_balance(manager) == {40, 60}

    views = snapshot.("published", task_id)
    assert views["manager"]["total_reward_amount"] == 60
    assert views["manager"]["reward_status"] == "reserved"
    assert "cancel" in views["manager"]["allowed_actions"]
    assert views["worker_a"]["allowed_actions"] == ["apply"]
    assert views["anonymous"]["allowed_actions"] == []
    assert views["anonymous"]["applications"] == nil

    # ── 2. 三个人申请 ──────────────────────────────────────────────────
    for {token, reason} <- [{token_a, "住得近"}, {token_b, "有工具"}, {token_c, "周末有空"}] do
      assert post_as(token, ~p"/api/tasks/#{task_id}/applications", %{
               contact: "微信 #{reason}",
               reason: reason
             })
             |> json_response(201)
    end

    views = snapshot.("applied", task_id)
    assert views["worker_c"]["my_application_status"] == "pending"
    assert views["worker_c"]["allowed_actions"] == []
    assert length(views["manager"]["applications"]) == 3
    assert "appoint" in views["manager"]["allowed_actions"]
    # 申请人之间看不到彼此的申请
    assert views["worker_a"]["applications"] == nil

    app_ids =
      Map.new(views["manager"]["applications"], &{&1["user"]["id"], &1["id"]})

    app_a = app_ids[worker_a.id]
    app_b = app_ids[worker_b.id]
    app_c = app_ids[worker_c.id]

    # ── 3. 指派两人,名额满 ────────────────────────────────────────────
    assert post_as(manager_token, ~p"/api/tasks/#{task_id}/applications/#{app_a}/appoint", %{
             appointment_reason: "住得近"
           })
           |> json_response(200)

    assert post_as(manager_token, ~p"/api/tasks/#{task_id}/applications/#{app_b}/appoint")
           |> json_response(200)

    views = snapshot.("appointed", task_id)
    assert views["manager"]["status"] == "in_progress"
    assert views["manager"]["appointed_count"] == 2
    assert views["manager"]["application_closed"] == true
    assert "release_assignee" in views["manager"]["allowed_actions"]
    assert "close" in views["manager"]["allowed_actions"]
    refute "appoint" in views["manager"]["allowed_actions"]
    assert views["worker_a"]["my_status"] == "in_progress"
    assert views["worker_a"]["allowed_actions"] == ["submit_result"]
    assert views["worker_c"]["my_application_status"] == "not_selected"
    assert views["guest"]["allowed_actions"] == []

    # 名额满了,路人申请不进来;承作人不能撤别人
    assert post_as(guest_token, ~p"/api/tasks/#{task_id}/applications", %{contact: "x"})
           |> json_response(409)

    assert post_as(token_b, ~p"/api/tasks/#{task_id}/applications/#{app_a}/release")
           |> json_response(403)

    # ── 4. 撤销阿青,小周重新排队 ──────────────────────────────────────
    assert post_as(manager_token, ~p"/api/tasks/#{task_id}/applications/#{app_a}/release", %{
             reason: "联系不上"
           })
           |> json_response(200)

    views = snapshot.("released", task_id)
    assert views["worker_a"]["my_application_status"] == "released"
    assert views["worker_a"]["my_application"]["state"] == "released"
    assert views["worker_a"]["allowed_actions"] == []
    assert views["worker_c"]["my_application_status"] == "pending"
    assert views["manager"]["appointed_count"] == 1
    assert views["manager"]["application_closed"] == false
    assert "appoint" in views["manager"]["allowed_actions"]
    assert node_balance(manager) == {40, 60}

    assert Enum.any?(
             Rice.Tasks.list_notifications(worker_a),
             &(&1.event == "appointment_released" and &1.detail == "联系不上")
           )

    # ── 5. 补位:小周拿到让出来的 1 号名额 ────────────────────────────
    assert post_as(manager_token, ~p"/api/tasks/#{task_id}/applications/#{app_c}/appoint")
           |> json_response(200)

    assert Repo.get!(Application, app_c).reward_slot == 1
    assert Repo.get!(Application, app_a).reward_slot == nil
    views = snapshot.("reappointed", task_id)
    assert views["manager"]["appointed_count"] == 2
    assert Enum.sort(Enum.map(views["manager"]["assignees"], & &1["nickname"])) == ["小周", "小林"]

    # ── 6. 小林交付 ───────────────────────────────────────────────────
    assert post_as(token_b, ~p"/api/tasks/#{task_id}/submissions", %{body: "第一段清完了"})
           |> json_response(201)

    views = snapshot.("submitted", task_id)
    assert views["manager"]["status"] == "under_review"
    assert views["worker_b"]["my_status"] == "under_review"
    assert views["worker_c"]["my_status"] == "in_progress"
    assert "approve_result" in views["manager"]["allowed_actions"]
    # 有成果待验收,不能提前结束
    refute "close" in views["manager"]["allowed_actions"]
    assert post_as(manager_token, ~p"/api/tasks/#{task_id}/close") |> json_response(409)
    # 小周看不到小林的成果
    assert views["worker_c"]["submissions"] == []
    submission_b = hd(views["manager"]["submissions"])["id"]

    # ── 7. 验收小林:只结算他那一份 ──────────────────────────────────
    assert post_as(manager_token, ~p"/api/tasks/#{task_id}/submissions/#{submission_b}/approve")
           |> json_response(200)

    views = snapshot.("approved", task_id)
    assert views["manager"]["status"] == "in_progress"
    assert views["manager"]["reward_status"] == "reserved"
    assert views["worker_b"]["my_status"] == "completed"
    assert views["worker_b"]["allowed_actions"] == []
    assert views["worker_c"]["allowed_actions"] == ["submit_result"]
    assert balance(worker_b) == 30
    assert node_balance(manager) == {40, 30}

    # ── 8. 提前结束:小周撤销,剩下一份退回节点 ──────────────────────
    closed = post_as(manager_token, ~p"/api/tasks/#{task_id}/close") |> json_response(200)
    assert closed["data"]["status"] == "completed"

    views = snapshot.("closed", task_id)
    assert views["manager"]["reward_status"] == "settled"
    assert views["manager"]["allowed_actions"] == []
    assert views["worker_c"]["my_application_status"] == "released"
    assert views["worker_b"]["my_status"] == "completed"

    assert Map.new(views["manager"]["applications"], &{&1["user"]["nickname"], &1["state"]}) ==
             %{"阿青" => "released", "小林" => "completed", "小周" => "released"}

    assert node_balance(manager) == {70, 0}
    assert balance(worker_c) == 0
    assert Rice.Grains.reconcile().ok?

    # 结束后什么都不能再做
    assert post_as(token_c, ~p"/api/tasks/#{task_id}/submissions", %{body: "晚了"})
           |> json_response(403)

    assert post_as(manager_token, ~p"/api/tasks/#{task_id}/applications/#{app_c}/appoint")
           |> json_response(409)

    recorder.(:flush, task_id)
  end

  # ── fixture 导出 ────────────────────────────────────────────────────

  defp start_recorder(actors) do
    case System.get_env("TASK_FLOW_FIXTURE_DIR") do
      nil ->
        fn _name, _views -> :ok end

      dir ->
        {:ok, agent} = Agent.start_link(fn -> [] end)

        fn
          :flush, task_id ->
            steps = agent |> Agent.get(&Enum.reverse/1)
            write_fixture(dir, actors, task_id, steps)

          name, views ->
            Agent.update(agent, &[%{"name" => name, "viewers" => views} | &1])
        end
    end
  end

  defp write_fixture(dir, actors, task_id, steps) do
    node = Repo.get_by!(Node, user_id: elem(actors["manager"], 0).id)

    replacements =
      [{task_id, "task-1"}, {node.id, "node-1"}] ++
        Enum.flat_map(actors, fn {label, {user, _}} ->
          [{user.id, "user-#{label}"}, {user.did, "did:example:#{label}"}]
        end) ++
        Enum.map(Repo.all(Application), &{&1.id, "application-#{&1.user_id}"}) ++
        Enum.map(Repo.all(Rice.Tasks.Submission), &{&1.id, "submission-#{&1.user_id}"})

    # application/submission 标签里的 user_id 也要换成用户标签,所以分两轮替换
    replacements = Enum.sort_by(replacements, fn {from, _} -> -byte_size(from) end)

    json =
      %{
        "generated_by" => "rice/test/rice_web/api/task_flow_test.exs",
        "actors" =>
          Map.new(actors, fn {label, {user, _}} ->
            {label,
             %{
               "id" => user.id,
               "did" => user.did,
               "handle" => user.handle,
               "nickname" => user.nickname
             }}
          end),
        "steps" => steps
      }
      |> Jason.encode!(pretty: true)

    normalized =
      Enum.reduce(replacements ++ replacements, json, fn {from, to}, acc ->
        String.replace(acc, from, to)
      end)

    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "multi-task-flow.json"), normalized <> "\n")
  end
end

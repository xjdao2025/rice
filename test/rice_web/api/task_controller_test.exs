defmodule RiceWeb.Api.TaskControllerTest do
  use RiceWeb.ConnCase, async: true

  test "个人列表允许访客，但拒绝无效或过期的 Bearer 令牌" do
    {:ok, expired} = Rice.Accounts.issue_token(user_fixture(), validity_days: -1)

    for path <- ["/api/tasks?mine=applied", "/api/events?mine=applied"] do
      assert %{"data" => []} = build_conn() |> get(path) |> json_response(200)

      for token <- ["invalid", expired] do
        assert %{"errors" => %{"detail" => "未认证"}} =
                 build_conn() |> authed(token) |> get(path) |> json_response(401)
      end
    end
  end

  test "公开读取任务，只有社区管理员可发布", %{conn: conn} do
    publisher = task_publisher_fixture()
    task = task_fixture(publisher, %{title: "村史整理"})

    assert %{"data" => [%{"id" => id, "status" => "open"}]} =
             conn |> get(~p"/api/tasks") |> json_response(200)

    assert id == task.id

    assert %{"data" => %{"allowed_actions" => []}} =
             build_conn() |> get(~p"/api/tasks/#{task.id}") |> json_response(200)

    assert build_conn()
           |> post(~p"/api/tasks", %{
             organizer_contact: "社区服务台",
             title: "未登录",
             description: "不能发布"
           })
           |> json_response(401)

    {_user, token} = user_with_token()

    assert build_conn()
           |> authed(token)
           |> post(~p"/api/tasks", %{
             organizer_contact: "社区服务台",
             title: "普通用户任务",
             description: "不能发布",
             client_request_id: "ordinary-user"
           })
           |> json_response(403)
  end

  test "公开履历隐藏未录取申请，已承接任务和已发布任务可见", %{conn: conn} do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)
    assert {:ok, application} = Rice.Tasks.apply(worker, task, %{contact: "测试联系方式"})

    assert %{"data" => []} =
             build_conn()
             |> get(~p"/api/tasks?participant_did=#{worker.did}")
             |> json_response(200)

    assert {:ok, _} = Rice.Tasks.appoint(publisher, task, application.id)

    assert %{"data" => [%{"id" => task_id}]} =
             conn
             |> get(~p"/api/tasks?participant_did=#{worker.did}")
             |> json_response(200)

    assert task_id == task.id

    assert %{"data" => [%{"id" => ^task_id}]} =
             build_conn()
             |> get(~p"/api/tasks?creator_did=#{publisher.did}")
             |> json_response(200)
  end

  test "发布者拒绝候选后返回未入选，动作及可见范围同步更新" do
    publisher = task_publisher_fixture()
    {:ok, publisher_token} = Rice.Accounts.issue_token(publisher)
    {worker, worker_token} = user_with_token()
    {other, other_token} = user_with_token()
    task = task_fixture(publisher)
    {:ok, application} = Rice.Tasks.apply(worker, task, %{contact: "测试联系方式"})

    initial =
      build_conn()
      |> authed(publisher_token)
      |> get(~p"/api/tasks/#{task.id}")
      |> json_response(200)

    assert "reject_application" in initial["data"]["allowed_actions"]

    assert build_conn()
           |> post(~p"/api/tasks/#{task.id}/applications/#{application.id}/reject", %{})
           |> json_response(401)

    assert build_conn()
           |> authed(worker_token)
           |> post(~p"/api/tasks/#{task.id}/applications/#{application.id}/reject", %{})
           |> json_response(403)

    rejected =
      build_conn()
      |> authed(publisher_token)
      |> post(~p"/api/tasks/#{task.id}/applications/#{application.id}/reject", %{})
      |> json_response(200)

    assert rejected["data"]["status"] == "open"
    assert hd(rejected["data"]["applications"])["status"] == "not_selected"
    refute "appoint" in rejected["data"]["allowed_actions"]
    refute "reject_application" in rejected["data"]["allowed_actions"]

    own =
      build_conn()
      |> authed(worker_token)
      |> get(~p"/api/tasks/#{task.id}")
      |> json_response(200)

    assert own["data"]["my_application_status"] == "not_selected"
    assert own["data"]["my_application"]["status"] == "not_selected"
    assert is_nil(own["data"]["applications"])
    refute "apply" in own["data"]["allowed_actions"]
    refute "reject_application" in own["data"]["allowed_actions"]

    public = build_conn() |> get(~p"/api/tasks/#{task.id}") |> json_response(200)
    assert is_nil(public["data"]["applications"])
    assert is_nil(public["data"]["my_application"])
    assert public["data"]["allowed_actions"] == []

    assert build_conn()
           |> authed(publisher_token)
           |> post(~p"/api/tasks/#{task.id}/applications/#{application.id}/appoint", %{})
           |> json_response(409)

    other_task = task_fixture(publisher)
    {:ok, other_application} = Rice.Tasks.apply(other, other_task, %{contact: "测试联系方式"})

    assert build_conn()
           |> authed(publisher_token)
           |> post(~p"/api/tasks/#{task.id}/applications/#{other_application.id}/reject", %{})
           |> json_response(404)

    applied =
      build_conn()
      |> authed(other_token)
      |> post(~p"/api/tasks/#{task.id}/applications", %{contact: "测试联系方式"})
      |> json_response(201)

    assert applied["data"]["my_application_status"] == "pending"

    reopened =
      build_conn()
      |> authed(publisher_token)
      |> get(~p"/api/tasks/#{task.id}")
      |> json_response(200)

    assert "appoint" in reopened["data"]["allowed_actions"]
    assert "reject_application" in reopened["data"]["allowed_actions"]
  end

  test "接口跑通申请、任命、提交、驳回与审核通过", %{conn: conn} do
    publisher = task_publisher_fixture()
    node = funded_node_fixture(publisher, 100)
    {:ok, publisher_token} = Rice.Accounts.issue_token(publisher)
    {worker, worker_token} = user_with_token()

    created =
      conn
      |> authed(publisher_token)
      |> post(~p"/api/tasks", %{
        organizer_contact: "社区服务台",
        title: "整理村史",
        description: "完成文字稿",
        client_request_id: "task-main-flow",
        reward_amount: 60
      })
      |> json_response(201)

    task_id = created["data"]["id"]
    assert created["data"]["reward_amount"] == 60
    assert created["data"]["reward_status"] == "reserved"
    assert created["data"]["funding_node_id"] == node.id

    applied =
      build_conn()
      |> authed(worker_token)
      |> post(~p"/api/tasks/#{task_id}/applications", %{contact: "测试联系方式", reason: "有经验"})
      |> json_response(201)

    assert applied["data"]["my_application_status"] == "pending"

    detail =
      build_conn()
      |> authed(publisher_token)
      |> get(~p"/api/tasks/#{task_id}")
      |> json_response(200)

    application_id = hd(detail["data"]["applications"])["id"]

    appointed =
      build_conn()
      |> authed(publisher_token)
      |> post(~p"/api/tasks/#{task_id}/applications/#{application_id}/appoint", %{
        appointment_reason: "经验最匹配"
      })
      |> json_response(200)

    assert appointed["data"]["status"] == "in_progress"
    assert appointed["data"]["assignee"]["id"] == worker.id
    assert appointed["data"]["appointment_reason"] == "经验最匹配"
    assert is_binary(appointed["data"]["appointed_at"])
    assert hd(appointed["data"]["applications"])["status"] == "appointed"

    assert %{"data" => []} =
             build_conn()
             |> authed(worker_token)
             |> get(~p"/api/tasks?mine=applied")
             |> json_response(200)

    assert %{"data" => [%{"id" => ^task_id}]} =
             build_conn()
             |> authed(worker_token)
             |> get(~p"/api/tasks?mine=assigned")
             |> json_response(200)

    submitted =
      build_conn()
      |> authed(worker_token)
      |> post(~p"/api/tasks/#{task_id}/submissions", %{body: "第一版"})
      |> json_response(201)

    submission_id = hd(submitted["data"]["submissions"])["id"]

    rejected =
      build_conn()
      |> authed(publisher_token)
      |> post(~p"/api/tasks/#{task_id}/submissions/#{submission_id}/request_changes", %{
        reason: "请补齐校对"
      })
      |> json_response(200)

    assert rejected["data"]["status"] == "in_progress"
    assert hd(rejected["data"]["submissions"])["review_reason"] == "请补齐校对"

    resubmitted =
      build_conn()
      |> authed(worker_token)
      |> post(~p"/api/tasks/#{task_id}/submissions", %{body: "补齐后的版本"})
      |> json_response(201)

    pending = Enum.find(resubmitted["data"]["submissions"], &(&1["status"] == "pending"))

    completed =
      build_conn()
      |> authed(publisher_token)
      |> post(~p"/api/tasks/#{task_id}/submissions/#{pending["id"]}/approve")
      |> json_response(200)

    assert completed["data"]["status"] == "completed"
    assert completed["data"]["reward_status"] == "settled"
    assert Rice.Repo.get!(Rice.Accounts.User, worker.id).grain_balance == 60

    assert Enum.map(completed["data"]["events"], &{&1["from_status"], &1["to_status"]}) == [
             {nil, "open"},
             {"open", "open"},
             {"open", "in_progress"},
             {"in_progress", "under_review"},
             {"under_review", "in_progress"},
             {"in_progress", "under_review"},
             {"under_review", "completed"}
           ]

    mine =
      build_conn()
      |> authed(worker_token)
      |> get(~p"/api/tasks?mine=assigned")
      |> json_response(200)

    assert Enum.map(mine["data"], & &1["id"]) == [task_id]

    notifications =
      build_conn()
      |> authed(worker_token)
      |> get(~p"/api/task_notifications")
      |> json_response(200)

    assert Enum.sort(Enum.map(notifications["notifications"], & &1["reason"])) ==
             Enum.sort(~w(task-assignee_appointed task-changes_requested task-result_approved))

    assert build_conn()
           |> authed(worker_token)
           |> post(~p"/api/task_notifications/read")
           |> response(204)
  end

  test "交付超时后仍可通过接口补交" do
    publisher = task_publisher_fixture()
    {:ok, publisher_token} = Rice.Accounts.issue_token(publisher)
    {worker, worker_token} = user_with_token()
    task = task_fixture(publisher)
    {:ok, application} = Rice.Tasks.apply(worker, task, %{contact: "测试联系方式"})
    {:ok, appointed} = Rice.Tasks.appoint(publisher, task, application.id)

    appointed
    |> Ecto.Changeset.change(execution_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Rice.Repo.update!()

    assert {:ok, [_]} = Rice.Tasks.check_due_tasks()

    overdue =
      build_conn()
      |> authed(worker_token)
      |> get(~p"/api/tasks/#{task.id}")
      |> json_response(200)

    assert overdue["data"]["status"] == "overdue"
    assert overdue["data"]["overdue"] == true
    assert "submit_result" in overdue["data"]["allowed_actions"]

    submitted =
      build_conn()
      |> authed(worker_token)
      |> post(~p"/api/tasks/#{task.id}/submissions", %{body: "补交成果"})
      |> json_response(201)

    assert submitted["data"]["status"] == "under_review"
    assert submitted["data"]["overdue"] == false
    submission_id = hd(submitted["data"]["submissions"])["id"]

    assert %{"data" => %{"status" => "completed"}} =
             build_conn()
             |> authed(publisher_token)
             |> post(~p"/api/tasks/#{task.id}/submissions/#{submission_id}/approve")
             |> json_response(200)
  end

  test "定时任务处理前申请已截止时，申请状态立即显示已失效" do
    publisher = task_publisher_fixture()
    {_worker, worker_token} = user_with_token()
    task = task_fixture(publisher)

    assert build_conn()
           |> authed(worker_token)
           |> post(~p"/api/tasks/#{task.id}/applications", %{contact: "测试联系方式"})
           |> json_response(201)

    task
    |> Ecto.Changeset.change(application_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Rice.Repo.update!()

    assert Rice.Repo.get!(Rice.Tasks.Task, task.id).status == "open"

    assert %{
             "data" => %{
               "my_application_status" => "expired",
               "my_application" => %{"status" => "expired"}
             }
           } =
             build_conn()
             |> authed(worker_token)
             |> get(~p"/api/tasks/#{task.id}")
             |> json_response(200)
  end

  test "任务状态被推进后重复动作返回 409", %{conn: conn} do
    publisher = task_publisher_fixture()
    {:ok, publisher_token} = Rice.Accounts.issue_token(publisher)
    {worker, worker_token} = user_with_token()
    task = task_fixture(publisher)
    {:ok, application} = Rice.Tasks.apply(worker, task, %{contact: "测试联系方式"})
    {:ok, _} = Rice.Tasks.appoint(publisher, task, application.id)

    assert conn
           |> authed(worker_token)
           |> post(~p"/api/tasks/#{task.id}/applications", %{contact: "测试联系方式"})
           |> json_response(409)

    assert build_conn()
           |> authed(publisher_token)
           |> post(~p"/api/tasks/#{task.id}/applications/#{application.id}/appoint")
           |> json_response(409)
  end

  test "草稿不公开，发布者可以发布或取消开放任务", %{conn: conn} do
    publisher = task_publisher_fixture()
    {:ok, token} = Rice.Accounts.issue_token(publisher)

    draft =
      conn
      |> authed(token)
      |> post(~p"/api/tasks", %{
        organizer_contact: "社区服务台",
        title: "任务草稿",
        description: "发布前不可见",
        client_request_id: "task-draft-flow",
        status: "draft"
      })
      |> json_response(201)

    task_id = draft["data"]["id"]
    assert draft["data"]["status"] == "draft"
    assert draft["data"]["published_at"] == nil

    assert %{"data" => []} = build_conn() |> get(~p"/api/tasks") |> json_response(200)
    assert build_conn() |> get(~p"/api/tasks/#{task_id}") |> json_response(404)

    updated =
      build_conn()
      |> authed(token)
      |> patch(~p"/api/tasks/#{task_id}", %{
        title: "更新后的任务草稿",
        description: "继续编辑同一条草稿"
      })
      |> json_response(200)

    assert updated["data"]["id"] == task_id
    assert updated["data"]["title"] == "更新后的任务草稿"

    published =
      build_conn()
      |> authed(token)
      |> post(~p"/api/tasks/#{task_id}/publish")
      |> json_response(200)

    assert published["data"]["status"] == "open"

    open_event = Enum.find(published["data"]["events"], &(&1["to_status"] == "open"))
    assert published["data"]["published_at"] == open_event["inserted_at"]

    assert %{"data" => [%{"published_at" => published_at}]} =
             build_conn() |> get(~p"/api/tasks") |> json_response(200)

    assert published_at == open_event["inserted_at"]

    cancelled =
      build_conn()
      |> authed(token)
      |> post(~p"/api/tasks/#{task_id}/cancel")
      |> json_response(200)

    assert cancelled["data"]["status"] == "cancelled"
  end

  test "申请人的取消历史保持可见并标记为已取消", %{conn: conn} do
    publisher = task_publisher_fixture()
    {:ok, publisher_token} = Rice.Accounts.issue_token(publisher)
    {_worker, worker_token} = user_with_token()
    task = task_fixture(publisher)

    assert build_conn()
           |> authed(worker_token)
           |> post(~p"/api/tasks/#{task.id}/applications", %{contact: "测试联系方式"})
           |> json_response(201)

    assert build_conn()
           |> authed(publisher_token)
           |> post(~p"/api/tasks/#{task.id}/cancel")
           |> json_response(200)

    assert %{
             "data" => [
               %{"id" => task_id, "my_application_status" => "cancelled"}
             ]
           } =
             conn
             |> authed(worker_token)
             |> get(~p"/api/tasks?mine=applied")
             |> json_response(200)

    assert task_id == task.id
  end

  test "发布必须带请求标识，重复同一发布请求不会创建新任务或重复冻结" do
    publisher = task_publisher_fixture()
    node = funded_node_fixture(publisher, 100)
    {:ok, token} = Rice.Accounts.issue_token(publisher)

    attrs = %{
      organizer_contact: "社区服务台",
      title: "网络重试的任务",
      description: "重试同一次发布",
      reward_amount: 60
    }

    assert build_conn() |> authed(token) |> post(~p"/api/tasks", attrs) |> json_response(422)
    request = Map.put(attrs, :client_request_id, "publish-once")
    first = build_conn() |> authed(token) |> post(~p"/api/tasks", request) |> json_response(201)
    second = build_conn() |> authed(token) |> post(~p"/api/tasks", request) |> json_response(201)
    assert first["data"]["id"] == second["data"]["id"]
    assert Rice.Repo.aggregate(Rice.Tasks.Task, :count) == 1

    assert %{grain_balance: 40, grain_frozen_balance: 60} =
             Rice.Repo.get!(Rice.Community.Node, node.id)

    assert Rice.Repo.aggregate(Rice.Grains.Receipt, :count) == 1
  end
end

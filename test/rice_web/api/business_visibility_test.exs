defmodule RiceWeb.Api.BusinessVisibilityTest do
  use RiceWeb.ConnCase, async: true

  test "承接者可以看任务进展，但不能借进展查看其他候选身份" do
    {host, host_token} = user_with_token()
    {worker, worker_token} = user_with_token()
    other = user_fixture()
    node_fixture(%{user_id: host.id})

    {:ok, task} =
      Rice.Tasks.create_task(host, %{organizer_contact: "社区服务台", title: "任务", description: "交付内容"})

    {:ok, selected} = Rice.Tasks.apply(worker, task, %{contact: "测试联系方式", reason: "本人申请"})
    {:ok, _} = Rice.Tasks.apply(other, task, %{contact: "测试联系方式", reason: "其他人的申请"})
    {:ok, _} = Rice.Tasks.appoint(host, task, selected.id, %{appointment_reason: "内部选人说明"})

    own =
      build_conn() |> authed(worker_token) |> get(~p"/api/tasks/#{task.id}") |> json_response(200)

    assert Enum.any?(own["data"]["events"], &(&1["to_status"] == "in_progress"))
    refute inspect(own) =~ other.did
    public = build_conn() |> get(~p"/api/tasks/#{task.id}") |> json_response(200)
    assert public["data"]["appointment_reason"] == nil
    refute inspect(public) =~ other.did

    manager =
      build_conn() |> authed(host_token) |> get(~p"/api/tasks/#{task.id}") |> json_response(200)

    assert Enum.count(manager["data"]["events"], &(&1["detail"] == "收到任务申请")) == 2
  end

  test "钱包与业务通知只返回当前登录账号的内容" do
    {first, first_token} = user_with_token()
    {second, second_token} = user_with_token()
    {:ok, _} = Rice.Grains.grant(first, 100)

    {:ok, _} =
      Rice.Inbox.notify(
        Rice.Repo,
        first.id,
        second.id,
        "community_approved",
        "加入申请已通过",
        "node",
        Rice.Tsid.generate()
      )

    assert build_conn() |> get(~p"/api/wallet") |> json_response(401)
    assert build_conn() |> get(~p"/api/notifications") |> json_response(401)
    own = build_conn() |> authed(first_token) |> get(~p"/api/wallet") |> json_response(200)
    assert own["data"]["earned"] == 100
    other = build_conn() |> authed(second_token) |> get(~p"/api/wallet") |> json_response(200)
    assert other["data"]["entries"] == []

    assert %{"notifications" => []} =
             build_conn()
             |> authed(second_token)
             |> get(~p"/api/notifications")
             |> json_response(200)

    received =
      build_conn() |> authed(first_token) |> get(~p"/api/notifications") |> json_response(200)

    assert length(received["notifications"]) == 1
    assert hd(received["notifications"])["subjectType"] == "node"
  end

  test "已有活动通知补齐各自名称和退款结算金额，免费活动不显示金额" do
    {host, _} = user_with_token()
    {recipient, token} = user_with_token()
    node = node_fixture(%{user_id: host.id})
    now = DateTime.utc_now()

    for {title, fee} <- [{"木工活动", 20}, {"社区散步", 0}] do
      {:ok, event} =
        Rice.Events.create_event(host, %{
          title: title,
          description: "活动说明",
          organizer_contact: "社区服务台",
          location: "社区",
          node_id: node.id,
          fee_amount: fee,
          capacity: 2,
          client_request_id: "notification-#{fee}",
          application_deadline: DateTime.add(now, 1800),
          starts_at: DateTime.add(now, 3600),
          ends_at: DateTime.add(now, 7200)
        })

      for {action, detail} <- [
            {"event_application_created", "有新的活动申请"},
            {"event_application_approved", "活动申请已通过"},
            {"event_application_rejected", "活动申请未通过"},
            {"event_application_removed", "活动报名已移除"},
            {"event_application_withdrawn", "活动申请已撤销"},
            {"event_application_not_selected", "活动已开始，本次未入选"},
            {"event_application_cancelled", "活动已取消"},
            {"event_completed", "活动已结束"}
          ] do
        refund? =
          action not in [
            "event_application_created",
            "event_application_approved",
            "event_completed"
          ]

        stored_detail = if fee > 0 and refund?, do: detail <> "，报名费已退回", else: detail

        {:ok, notification} =
          Rice.Inbox.notify(
            Rice.Repo,
            recipient.id,
            host.id,
            action,
            stored_detail,
            "event",
            event.id
          )

        expected_detail =
          cond do
            fee > 0 and refund? -> detail <> "，报名费 20 稻米已退回"
            fee > 0 and action == "event_completed" -> detail <> "，报名费 20 稻米已结算"
            true -> detail
          end

        response =
          build_conn() |> authed(token) |> get(~p"/api/notifications") |> json_response(200)

        item =
          Enum.find(
            response["notifications"],
            &(&1["uri"] == "business-notification:#{notification.id}")
          )

        assert item["record"]["text"] == "#{title} · #{expected_detail}"
        assert item["subjectType"] == "event"
        assert item["subjectId"] == event.id
        refute item["isRead"]
        assert Rice.Repo.get!(Rice.Tasks.Notification, notification.id).detail == stored_detail
      end
    end

    # A stale or malformed subject remains readable and keeps its original detail.
    {:ok, _} =
      Rice.Inbox.notify(
        Rice.Repo,
        recipient.id,
        host.id,
        "event_completed",
        "历史活动已结束",
        "event",
        "old-event-id"
      )

    response = build_conn() |> authed(token) |> get(~p"/api/notifications") |> json_response(200)
    assert hd(response["notifications"])["record"]["text"] == "历史活动已结束"
  end

  test "历史任务通知保留名称和已有结算金额，退款明确退回社区" do
    host = task_publisher_fixture()
    {recipient, token} = user_with_token()
    funded_node_fixture(host, 120)
    attrs = %{title: "整理村史", description: "交付内容", organizer_contact: "社区服务台", reward_amount: 60}
    {:ok, task} = Rice.Tasks.create_task(host, attrs)
    {:ok, application} = Rice.Tasks.apply(recipient, task, %{contact: "测试联系方式"})
    {:ok, task} = Rice.Tasks.appoint(host, task, application.id)
    {:ok, task} = Rice.Tasks.submit_result(recipient, task, %{body: "已完成"})
    {:ok, task} = Rice.Tasks.approve_result(host, task, hd(task.submissions).id)

    {:ok, cancelled} = Rice.Tasks.create_task(host, %{attrs | title: "修整步道"})
    {:ok, _} = Rice.Tasks.apply(recipient, cancelled, %{contact: "测试联系方式"})
    {:ok, _} = Rice.Tasks.cancel(host, cancelled)

    response = build_conn() |> authed(token) |> get(~p"/api/notifications") |> json_response(200)
    items = Map.new(response["notifications"], &{&1["reason"], &1})
    assert items["task-result_approved"]["record"]["text"] == "整理村史 · 已向承作人发放 60 稻米"
    assert items["task-task_cancelled"]["record"]["text"] == "修整步道 · 已向社区退回 60 稻米"

    assert Enum.all?(
             response["notifications"],
             &(&1["subjectType"] == "task" and &1["subjectId"] == &1["taskId"])
           )

    assert items["task-result_approved"]["subjectId"] == task.id
    assert items["task-task_cancelled"]["subjectId"] == cancelled.id
  end
end

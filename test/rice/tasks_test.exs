defmodule Rice.TasksTest do
  use Rice.DataCase, async: true

  alias Rice.Tasks

  test "多人任务按名额冻结，每人独立退回、交付、验收及幂等发放" do
    publisher = task_publisher_fixture()
    [first, second, third, visitor] = for _ <- 1..4, do: user_fixture()
    node = funded_node_fixture(publisher, 120)

    {:ok, task} =
      Tasks.create_task(publisher, %{
        title: "多人交付",
        description: "分别交付",
        organizer_contact: "节点服务台",
        capacity: 2,
        reward_amount: 30
      })

    assert %{grain_balance: 60, grain_frozen_balance: 60} =
             Repo.get!(Rice.Community.Node, node.id)

    applications =
      for worker <- [first, second, third] do
        {:ok, application} = Tasks.apply(worker, task, %{contact: "联系人#{worker.id}"})
        application
      end

    [a, b, c] = applications

    {:ok, task} =
      Tasks.appoint(publisher, task, a.id, %{appointment_reason: String.duplicate("人", 512)})

    assert task.status == "in_progress"
    assert is_nil(task.assignee_id)

    assert Enum.any?(
             Tasks.list_tasks(visitor, %{"available" => true}).entries,
             &(&1.id == task.id)
           )

    assert Tasks.list_tasks(first, %{"mine" => "applied"}).entries == []
    assert [assigned] = Tasks.list_tasks(first, %{"mine" => "assigned"}).entries
    assert assigned.id == task.id

    assert Tasks.list_notifications(second)
           |> Enum.all?(&(&1.event != "application_not_selected"))

    {:ok, task} = Tasks.appoint(publisher, task, b.id)
    assert {:error, :capacity_full} = Tasks.appoint(publisher, task, c.id)
    assert Tasks.list_tasks(visitor, %{"available" => true}).entries == []

    assert Enum.count(Tasks.list_notifications(third), &(&1.event == "application_not_selected")) ==
             1

    assert {:error, :conflict} = Tasks.cancel(publisher, task)

    {:ok, task} = Tasks.submit_result(first, task, %{body: "第一位的成果"})
    assert Tasks.my_status(task, first) == "under_review"
    assert Tasks.my_status(task, second) == "in_progress"

    assert [%{id: id}] =
             Tasks.list_tasks(second, %{"mine" => "assigned", "status" => "in_progress"}).entries

    assert id == task.id

    assert Tasks.list_tasks(first, %{"mine" => "assigned", "status" => "in_progress"}).entries ==
             []

    first_submission = Enum.find(task.submissions, &(&1.user_id == first.id))
    {:ok, task} = Tasks.request_changes(publisher, task, first_submission.id, "补充一个附件")
    {:ok, task} = Tasks.submit_result(second, task, %{body: "第二位的成果"})
    second_submission = Enum.find(task.submissions, &(&1.user_id == second.id))
    {:ok, task} = Tasks.approve_result(publisher, task, second_submission.id)
    assert task.status == "in_progress"
    assert Tasks.my_status(task, second) == "completed"
    assert Tasks.my_status(task, first) == "in_progress"
    assert {:ok, _} = Tasks.approve_result(publisher, task, second_submission.id)
    assert %{grain_balance: 30} = Repo.get!(Rice.Accounts.User, second.id)
    assert %{grain_frozen_balance: 30} = Repo.get!(Rice.Community.Node, node.id)
    {:ok, task} = Tasks.submit_result(first, task, %{body: "补充后的成果"})
    latest = Enum.find(task.submissions, &(&1.user_id == first.id and is_nil(&1.review_reason)))
    {:ok, task} = Tasks.approve_result(publisher, task, latest.id)
    assert task.status == "completed"
    assert task.reward_status == "settled"
    assert %{grain_balance: 30} = Repo.get!(Rice.Accounts.User, first.id)
    assert %{grain_balance: 60, grain_frozen_balance: 0} = Repo.get!(Rice.Community.Node, node.id)

    assert Repo.aggregate(from(t in Rice.Grains.Transfer, where: t.kind == "task_reward"), :count) ==
             2

    assert Enum.count(Tasks.list_notifications(third), &(&1.event == "application_not_selected")) ==
             1

    assert Rice.Grains.reconcile().ok?
  end

  test "未设申请截止时，部分承作人验收通过仍保留空缺名额的冻结" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    node = funded_node_fixture(publisher, 50)

    {:ok, task} =
      Tasks.create_task(publisher, %{
        title: "持续招募",
        description: "独立验收",
        organizer_contact: "节点服务台",
        capacity: 2,
        reward_amount: 10
      })

    {:ok, application} = Tasks.apply(worker, task, %{contact: "联系方式"})
    {:ok, task} = Tasks.appoint(publisher, task, application.id)
    {:ok, task} = Tasks.submit_result(worker, task, %{body: "成果"})
    {:ok, task} = Tasks.approve_result(publisher, task, hd(task.submissions).id)
    assert task.status == "in_progress"
    assert Tasks.my_status(task, worker) == "completed"
    assert Tasks.accepting_applications?(task)

    assert %{grain_balance: 30, grain_frozen_balance: 10} =
             Repo.get!(Rice.Community.Node, node.id)

    assert %{grain_balance: 10} = Repo.get!(Rice.Accounts.User, worker.id)
    assert Rice.Grains.reconcile().ok?
  end

  test "延长多人交付期限复用个人状态汇总，奖励和人数只可原值回传" do
    publisher = task_publisher_fixture()
    [first, second] = for _ <- 1..2, do: user_fixture()
    now = DateTime.utc_now()

    {:ok, task} =
      Tasks.create_task(publisher, %{
        title: "延长交付",
        description: "独立验收",
        organizer_contact: "节点服务台",
        capacity: 2,
        application_deadline: DateTime.add(now, 1800),
        execution_deadline: DateTime.add(now, 3600)
      })

    task =
      Enum.reduce([first, second], task, fn worker, current ->
        {:ok, application} = Tasks.apply(worker, current, %{contact: "联系方式"})
        {:ok, updated} = Tasks.appoint(publisher, current, application.id)
        updated
      end)

    {:ok, task} = Tasks.submit_result(first, task, %{body: "等待验收"})

    {:ok, task} =
      Tasks.update_task(publisher, task, %{
        application_deadline: DateTime.add(now, -3600),
        execution_deadline: DateTime.add(now, -1)
      })

    assert task.status == "overdue"
    assert Tasks.my_status(task, first) == "under_review"
    assert Tasks.my_status(task, second) == "overdue"

    {:ok, task} =
      Tasks.update_task(publisher, task, %{
        execution_deadline: DateTime.add(now, 7200),
        reward_amount: 0,
        capacity: 2
      })

    assert task.status == "under_review"
    assert Tasks.my_status(task, second) == "in_progress"
    assert List.last(task.events).to_status == "under_review"
    assert {:error, reward_changeset} = Tasks.update_task(publisher, task, %{reward_amount: 1})
    assert errors_on(reward_changeset).reward_amount != []
    assert {:error, capacity_changeset} = Tasks.update_task(publisher, task, %{capacity: 3})
    assert errors_on(capacity_changeset).capacity != []
    assert Repo.aggregate(Rice.Grains.Receipt, :count) == 0
  end

  test "未招满且已接收者都通过，截止时自动完成并退还未使用名额" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    node = funded_node_fixture(publisher, 50)

    {:ok, task} =
      Tasks.create_task(publisher, %{
        title: "未招满",
        description: "按名额奖励",
        organizer_contact: "节点服务台",
        capacity: 3,
        reward_amount: 7,
        application_deadline: DateTime.add(DateTime.utc_now(), 3600)
      })

    {:ok, application} = Tasks.apply(worker, task, %{contact: "联系方式"})
    {:ok, task} = Tasks.appoint(publisher, task, application.id)
    {:ok, task} = Tasks.submit_result(worker, task, %{body: "已完成"})
    {:ok, task} = Tasks.approve_result(publisher, task, hd(task.submissions).id)
    assert task.status == "in_progress"
    assert Tasks.my_status(task, worker) == "completed"
    assert %{grain_frozen_balance: 14} = Repo.get!(Rice.Community.Node, node.id)
    now = DateTime.add(task.application_deadline, 1)
    assert {:ok, [completed]} = Tasks.check_due_tasks(now)
    assert completed.status == "completed"
    assert %{grain_balance: 43, grain_frozen_balance: 0} = Repo.get!(Rice.Community.Node, node.id)

    assert Repo.aggregate(from(r in Rice.Grains.Receipt, where: r.kind == "refunded"), :count) ==
             2

    assert {:ok, []} = Tasks.check_due_tasks(now)
    assert Rice.Grains.reconcile().ok?
  end

  test "多人零奖励沿用状态，交付超时不失效、不重复写入或退还" do
    publisher = task_publisher_fixture()
    worker = user_fixture()

    {:ok, task} =
      Tasks.create_task(publisher, %{
        title: "零奖励",
        description: "多人参与",
        organizer_contact: "节点服务台",
        capacity: 2,
        execution_deadline: DateTime.add(DateTime.utc_now(), 3600)
      })

    {:ok, application} = Tasks.apply(worker, task, %{contact: "联系方式"})
    {:ok, task} = Tasks.appoint(publisher, task, application.id)
    now = DateTime.add(task.execution_deadline, 1)
    assert {:ok, [overdue]} = Tasks.check_due_tasks(now)
    assert overdue.status == "overdue"
    before = Repo.get!(Rice.Tasks.Task, task.id).updated_at
    # 已经记成超期的任务不再被定时任务拿出来
    assert {:ok, []} = Tasks.check_due_tasks(now)
    assert Repo.get!(Rice.Tasks.Task, task.id).updated_at == before
    assert Repo.aggregate(Rice.Grains.Receipt, :count) == 0
    assert Enum.count(Tasks.list_notifications(worker), &(&1.event == "task_overdue")) == 1
  end

  test "取消、失效与重开各按本轮名额冻结退还，人数与单价在活动中只读" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    node = funded_node_fixture(publisher, 90)

    {:ok, task} =
      Tasks.create_task(publisher, %{
        title: "新一轮",
        description: "保留旧记录",
        organizer_contact: "节点服务台",
        capacity: 2,
        reward_amount: 10
      })

    assert {:error, changeset} = Tasks.update_task(publisher, task, %{capacity: 3})
    assert Map.has_key?(errors_on(changeset), :capacity)
    {:ok, old_application} = Tasks.apply(worker, task, %{contact: "联系方式"})
    {:ok, task} = Tasks.cancel(publisher, task)
    assert %{grain_balance: 90, grain_frozen_balance: 0} = Repo.get!(Rice.Community.Node, node.id)
    deadline = DateTime.add(DateTime.utc_now(), 3600)

    {:ok, task} =
      Tasks.update_task(publisher, task, %{
        capacity: 3,
        reward_amount: 5,
        application_deadline: deadline
      })

    assert task.round == 2
    assert task.capacity == 3
    assert Repo.get!(Rice.Tasks.Application, old_application.id).final_status == "cancelled"

    assert %{grain_balance: 75, grain_frozen_balance: 15} =
             Repo.get!(Rice.Community.Node, node.id)

    assert {:ok, [expired]} = Tasks.check_due_tasks(DateTime.add(deadline, 1))
    assert expired.status == "expired"
    assert %{grain_balance: 90, grain_frozen_balance: 0} = Repo.get!(Rice.Community.Node, node.id)
    assert Rice.Grains.reconcile().ok?
  end

  test "人数范围与总额检查先于发布，余额不足时所有名额一起回滚" do
    publisher = task_publisher_fixture()
    node = funded_node_fixture(publisher, 20)
    attrs = %{title: "容量限制", description: "需要全部冻结", organizer_contact: "节点服务台", reward_amount: 10}

    for capacity <- [0, Rice.Tasks.Task.max_capacity() + 1, 1.5] do
      assert {:error, %Ecto.Changeset{}} =
               Tasks.create_task(publisher, Map.put(attrs, :capacity, capacity))
    end

    assert {:error, :insufficient_balance} =
             Tasks.create_task(publisher, Map.put(attrs, :capacity, 3))

    assert Repo.aggregate(Rice.Tasks.Task, :count) == 0
    assert Repo.aggregate(Rice.Grains.Receipt, :count) == 0
    assert %{grain_balance: 20, grain_frozen_balance: 0} = Repo.get!(Rice.Community.Node, node.id)
  end

  test "任务奖励在发布时冻结，在认可结果时发给承作人" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    node = funded_node_fixture(publisher, 300)

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "有奖励的任务",
               description: "完成后发放",
               reward_amount: 120
             })

    assert task.reward_status == "reserved"

    assert %{grain_balance: 180, grain_frozen_balance: 120} =
             Repo.get!(Rice.Community.Node, node.id)

    assert {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})
    assert {:ok, task} = Tasks.appoint(publisher, task, application.id)
    assert {:ok, task} = Tasks.submit_result(worker, task, %{body: "已完成"})
    submission = Enum.find(task.submissions, &is_nil(&1.review_reason))
    assert {:ok, completed} = Tasks.approve_result(publisher, task, submission.id)

    assert completed.reward_status == "settled"

    assert %{grain_balance: 180, grain_frozen_balance: 0} =
             Repo.get!(Rice.Community.Node, node.id)

    assert %{grain_balance: 120} = Repo.get!(Rice.Accounts.User, worker.id)

    assert %{kind: "task_reward", amount: 120, subject_uri: subject_uri} =
             Repo.one!(from(t in Rice.Grains.Transfer, where: t.kind == "task_reward"))

    assert subject_uri == "rice://tasks/#{task.id}"
    assert Rice.Grains.reconcile().ok?
  end

  test "草稿不冻结，发布时才冻结；取消后自动退回" do
    publisher = task_publisher_fixture()
    node = funded_node_fixture(publisher, 200)

    assert {:ok, draft} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "奖励草稿",
               description: "发布后冻结",
               status: "draft",
               reward_amount: 80
             })

    assert draft.reward_status == "none"

    assert %{grain_balance: 200, grain_frozen_balance: 0} =
             Repo.get!(Rice.Community.Node, node.id)

    assert {:ok, task} = Tasks.publish_draft(publisher, draft)
    assert task.reward_status == "reserved"

    assert %{grain_balance: 120, grain_frozen_balance: 80} =
             Repo.get!(Rice.Community.Node, node.id)

    assert {:ok, cancelled} = Tasks.cancel(publisher, task)
    assert cancelled.reward_status == "refunded"

    assert %{grain_balance: 200, grain_frozen_balance: 0} =
             Repo.get!(Rice.Community.Node, node.id)

    assert Rice.Grains.reconcile().ok?
  end

  test "余额不足时任务发布与冻结一起回滚" do
    publisher = task_publisher_fixture()
    {:ok, _} = Rice.Grains.grant(publisher, 100)

    assert {:error, :insufficient_balance} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "余额不足",
               description: "不能公开",
               reward_amount: 1
             })

    assert Repo.aggregate(Rice.Tasks.Task, :count) == 0
    assert %{balance: 100, frozen: 0} = Rice.Grains.wallet(publisher)
  end

  test "发布重读草稿，冻结当前金额并可按同一金额退款" do
    publisher = task_publisher_fixture()
    node = funded_node_fixture(publisher, 200)

    {:ok, stale_draft} =
      Tasks.create_task(publisher, %{
        organizer_contact: "社区服务台",
        title: "更新中的草稿",
        description: "发布时以当前约定为准",
        status: "draft",
        reward_amount: 80
      })

    assert {:ok, _} = Tasks.update_task(publisher, stale_draft, %{reward_amount: 120})

    assert {:ok, published} = Tasks.publish_draft(publisher, stale_draft)
    assert published.reward_amount == 120

    assert %{grain_balance: 80, grain_frozen_balance: 120} =
             Repo.get!(Rice.Community.Node, node.id)

    assert %{amount: 120, kind: "reserved"} = Repo.one!(Rice.Grains.Receipt)
    assert {:ok, _} = Tasks.cancel(publisher, published)

    assert %{grain_balance: 200, grain_frozen_balance: 0} =
             Repo.get!(Rice.Community.Node, node.id)
  end

  test "草稿交付期限已过时不能发布，保留草稿且不冻结" do
    publisher = task_publisher_fixture()
    node = funded_node_fixture(publisher, 100)

    {:ok, stale_draft} =
      Tasks.create_task(publisher, %{
        organizer_contact: "社区服务台",
        title: "有交付期限的草稿",
        description: "过期应先修改",
        status: "draft",
        reward_amount: 60,
        execution_deadline: DateTime.add(DateTime.utc_now(), 60, :second)
      })

    stale_draft
    |> change(execution_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, changeset} = Tasks.publish_draft(publisher, stale_draft)
    assert Map.has_key?(errors_on(changeset), :execution_deadline)
    assert Repo.get!(Rice.Tasks.Task, stale_draft.id).status == "draft"

    assert %{grain_balance: 100, grain_frozen_balance: 0} =
             Repo.get!(Rice.Community.Node, node.id)

    assert Repo.aggregate(Rice.Grains.Receipt, :count) == 0
  end

  test "重复申请保留同一记录，不重复事件和通知" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)
    assert {:ok, first} = Tasks.apply(worker, task, %{contact: "测试联系方式", reason: "可以参与"})
    assert {:ok, repeated} = Tasks.apply(worker, task, %{contact: "测试联系方式", reason: "重试请求"})
    assert repeated.id == first.id
    assert repeated.reason == "可以参与"
    assert Repo.aggregate(Rice.Tasks.Application, :count) == 1
    assert Repo.aggregate(from(e in Rice.Tasks.Event, where: e.detail == "收到任务申请"), :count) == 1
    assert [%{event: "application_created"}] = Tasks.list_notifications(publisher)
  end

  test "完整状态机保留驳回原因与承作人的完成历史" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    other = user_fixture()

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "整理访谈",
               description: "完成文字稿"
             })

    assert task.status == "open"
    assert {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式", reason: "有口述史经验"})
    assert {:ok, _} = Tasks.apply(other, task, %{contact: "测试联系方式", reason: "也可以承做"})

    assert [pending] = Tasks.list_tasks(worker, %{"mine" => "applied"}).entries
    assert pending.id == task.id

    assert {:ok, task} =
             Tasks.appoint(publisher, task, application.id, %{
               appointment_reason: "相关经验最匹配"
             })

    assert task.status == "in_progress"
    assert task.assignee_id == worker.id
    assert task.appointment_reason == "相关经验最匹配"
    assert %DateTime{} = task.appointed_at
    assert Tasks.list_tasks(worker, %{"mine" => "applied"}).entries == []

    assert [assigned] = Tasks.list_tasks(worker, %{"mine" => "assigned"}).entries
    assert assigned.id == task.id

    assert {:ok, task} = Tasks.submit_result(worker, task, %{body: "第一版文字稿"})
    pending = Enum.find(task.submissions, &is_nil(&1.review_reason))
    assert task.status == "under_review"

    assert {:ok, task} =
             Tasks.request_changes(publisher, task, pending.id, "缺少第二位受访者确认")

    rejected = Enum.find(task.submissions, &(&1.id == pending.id))
    assert task.status == "in_progress"
    assert task.assignee_id == worker.id
    assert rejected.review_reason == "缺少第二位受访者确认"

    assert {:ok, task} = Tasks.submit_result(worker, task, %{body: "补齐后的文字稿"})
    resubmission = Enum.find(task.submissions, &is_nil(&1.review_reason))
    assert {:ok, completed} = Tasks.approve_result(publisher, task, resubmission.id)
    assert completed.status == "completed"

    assert Enum.map(completed.events, &{&1.from_status, &1.to_status}) == [
             {nil, "open"},
             {"open", "open"},
             {"open", "open"},
             {"open", "in_progress"},
             {"in_progress", "under_review"},
             {"under_review", "in_progress"},
             {"in_progress", "under_review"},
             {"under_review", "completed"}
           ]

    assert Enum.find(
             completed.events,
             &(&1.from_status == "under_review" and &1.to_status == "in_progress")
           )
           |> Map.fetch!(:detail) == "缺少第二位受访者确认"

    assigned = Tasks.list_tasks(worker, %{"mine" => "assigned"}).entries
    assert Enum.map(assigned, & &1.id) == [completed.id]

    assert MapSet.new(Enum.map(Tasks.list_notifications(worker), & &1.event)) ==
             MapSet.new(~w(assignee_appointed changes_requested result_approved))

    assert [%{event: "application_not_selected"}] = Tasks.list_notifications(other)
    assert [not_selected] = Tasks.list_tasks(other, %{"mine" => "applied"}).entries
    assert not_selected.id == completed.id
    assert :ok = Rice.Inbox.mark_read(worker)
    assert Enum.all?(Tasks.list_notifications(worker), &match?(%DateTime{}, &1.read_at))
  end

  test "只有社区唯一管理员可发布，管理员不能申请自己的任务" do
    user = user_fixture()

    assert {:error, :forbidden} =
             Tasks.create_task(user, %{
               organizer_contact: "社区服务台",
               title: "普通用户任务",
               description: "不能发布"
             })

    publisher = task_publisher_fixture()

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "社区任务",
               description: "公开参与"
             })

    assert {:error, :forbidden} = Tasks.apply(publisher, task, %{contact: "测试联系方式"})

    assert {:error, :forbidden} =
             Tasks.create_task(user, %{
               organizer_contact: "社区服务台",
               title: "冒用社区",
               description: "不能发布",
               node_id: task.node_id
             })

    assert {:ok, _application} = Tasks.apply(user, task, %{contact: "测试联系方式"})
  end

  test "公开履历只列已承接任务，不暴露待选申请" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    other = user_fixture()
    task = task_fixture(publisher)
    other_task = task_fixture(task_publisher_fixture())

    assert {:ok, _draft} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "未公开草稿",
               description: "不进入公开履历",
               status: "draft"
             })

    assert {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})
    assert {:ok, _application} = Tasks.apply(other, other_task, %{contact: "测试联系方式"})

    assert Tasks.list_tasks(nil, %{"participant_did" => worker.did}).entries == []
    assert {:ok, _appointed} = Tasks.appoint(publisher, task, application.id)

    participant_tasks =
      Tasks.list_tasks(nil, %{"participant_did" => worker.did}).entries

    created_tasks =
      Tasks.list_tasks(nil, %{"creator_did" => publisher.did}).entries

    assert Enum.map(participant_tasks, & &1.id) == [task.id]
    assert Enum.map(created_tasks, & &1.id) == [task.id]
    assert Tasks.list_tasks(nil, %{"participant_did" => other.did}).entries == []
  end

  test "驳回必须填写原因" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)
    {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})
    {:ok, task} = Tasks.appoint(publisher, task, application.id)
    {:ok, task} = Tasks.submit_result(worker, task, %{body: "已完成"})
    submission = Enum.find(task.submissions, &is_nil(&1.review_reason))

    assert {:error, changeset} = Tasks.request_changes(publisher, task, submission.id, "   ")
    assert Map.has_key?(errors_on(changeset), :review_reason)
  end

  test "新一轮交付不能被旧结果的验收或驳回请求推进" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    node = funded_node_fixture(publisher, 100)

    {:ok, task} =
      Tasks.create_task(publisher, %{
        organizer_contact: "社区服务台",
        title: "反复校对",
        description: "以本轮交付为准",
        reward_amount: 60
      })

    {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})
    {:ok, task} = Tasks.appoint(publisher, task, application.id)
    {:ok, first_review} = Tasks.submit_result(worker, task, %{body: "旧版本"})
    first_submission = Enum.find(first_review.submissions, &is_nil(&1.review_reason))
    {:ok, returned} = Tasks.request_changes(publisher, first_review, first_submission.id, "需要补充")
    {:ok, second_review} = Tasks.submit_result(worker, returned, %{body: "新版本"})
    second_submission = Enum.find(second_review.submissions, &is_nil(&1.review_reason))

    assert {:error, :conflict} =
             Tasks.approve_result(publisher, first_review, first_submission.id)

    assert {:error, :conflict} =
             Tasks.request_changes(publisher, first_review, first_submission.id, "迟到的旧驳回")

    assert Repo.get!(Rice.Tasks.Task, task.id).status == "under_review"
    assert is_nil(Repo.get!(Rice.Tasks.Submission, second_submission.id).review_reason)

    assert %{grain_balance: 40, grain_frozen_balance: 60} =
             Repo.get!(Rice.Community.Node, node.id)

    assert Repo.get!(Rice.Accounts.User, worker.id).grain_balance == 0
    assert {:ok, completed} = Tasks.approve_result(publisher, second_review, second_submission.id)
    assert completed.status == "completed"
    assert Repo.get!(Rice.Accounts.User, worker.id).grain_balance == 60
  end

  test "任务取消通知所有申请人" do
    publisher = task_publisher_fixture()
    applicants = [user_fixture(), user_fixture()]
    task = task_fixture(publisher)

    Enum.each(applicants, fn user ->
      assert {:ok, _} = Tasks.apply(user, task, %{contact: "测试联系方式"})
    end)

    assert {:ok, %{status: "cancelled"}} = Tasks.cancel(publisher, task)

    Enum.each(applicants, fn user ->
      assert [%{event: "task_cancelled", actor_id: actor_id}] = Tasks.list_notifications(user)
      assert actor_id == publisher.id
      assert [history] = Tasks.list_tasks(user, %{"mine" => "applied"}).entries
      assert history.id == task.id
    end)
  end

  test "过期或状态已变化的旧快照不能再写入申请" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)

    assert {:ok, _cancelled} = Tasks.cancel(publisher, task)
    assert {:error, :conflict} = Tasks.apply(worker, task, %{contact: "测试联系方式"})

    expiring = task_fixture(publisher)

    expiring
    |> change(application_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :conflict} = Tasks.apply(worker, expiring, %{contact: "测试联系方式"})
  end

  test "每位发布者只能保留一份草稿" do
    publisher = task_publisher_fixture()

    assert {:ok, _draft} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "第一份草稿",
               description: "继续编辑这一份",
               status: "draft"
             })

    assert {:error, changeset} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "第二份草稿",
               description: "不应创建",
               status: "draft"
             })

    assert Map.has_key?(errors_on(changeset), :creator_id)
  end

  test "草稿只有发布者可见，发布后进入公开列表" do
    publisher = task_publisher_fixture()
    viewer = user_fixture()

    assert {:ok, draft} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "尚未发布",
               description: "只对发布者可见",
               status: "draft"
             })

    assert draft.status == "draft"
    assert Tasks.list_tasks(nil).entries == []
    assert {:error, :not_found} = Tasks.fetch_task(draft.id, viewer)
    assert {:ok, _} = Tasks.fetch_task(draft.id, publisher)
    assert [mine] = Tasks.list_tasks(publisher, %{"mine" => "created"}).entries
    assert mine.id == draft.id

    assert {:error, :forbidden} =
             Tasks.update_task(viewer, draft, %{title: "不该被修改"})

    assert {:ok, updated} =
             Tasks.update_task(publisher, draft, %{
               title: "更新后的草稿",
               description: "仍然只对发布者可见"
             })

    assert updated.id == draft.id
    assert updated.title == "更新后的草稿"

    assert {:ok, published} = Tasks.publish_draft(publisher, updated)
    assert published.status == "open"
    assert [public] = Tasks.list_tasks(nil).entries
    assert public.id == draft.id
  end

  test "发布者只能在任命前取消任务" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)

    assert {:error, :forbidden} = Tasks.cancel(worker, task)
    assert {:ok, cancelled} = Tasks.cancel(publisher, task)
    assert cancelled.status == "cancelled"
    assert {:error, :conflict} = Tasks.apply(worker, cancelled, %{contact: "测试联系方式"})
    assert Tasks.list_tasks(nil).entries == []
    assert {:error, :not_found} = Tasks.fetch_task(task.id, worker)
    assert {:ok, %{status: "cancelled"}} = Tasks.fetch_task(task.id, publisher)
    assert [mine] = Tasks.list_tasks(publisher, %{"mine" => "created"}).entries
    assert mine.id == task.id
  end

  test "进行中任务不能换社区，取消后可用新金额和社区开启新一期" do
    publisher = task_publisher_fixture()
    first_node = funded_node_fixture(publisher, 100)
    second_node = node_fixture(%{user_id: publisher.id})
    {:ok, _} = Rice.Grains.grant(publisher, 80)
    {:ok, _} = Rice.Grains.fund_node(publisher, second_node, 80, "edit-node-fund")
    worker = user_fixture()

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               node_id: first_node.id,
               title: "旧任务",
               description: "旧说明",
               organizer_contact: "旧联系方式",
               reward_amount: 40,
               application_deadline: DateTime.add(DateTime.utc_now(), 3600)
             })

    assert {:ok, old_application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})

    assert {:error, changeset} =
             Tasks.update_task(publisher, task, %{reward_amount: 60})

    assert "已发布任务不能修改任务奖励" in errors_on(changeset).reward_amount

    assert {:error, changeset} =
             Tasks.update_task(publisher, task, %{node_id: second_node.id})

    assert "已发布任务不能修改所属节点" in errors_on(changeset).node_id

    assert {:ok, edited} =
             Tasks.update_task(publisher, task, %{
               title: "新任务",
               description: "新说明",
               organizer_contact: "新联系方式"
             })

    assert edited.id == task.id
    assert edited.funding_node_id == first_node.id
    assert edited.reward_amount == 40
    assert edited.reward_subject_uri == nil
    assert length(edited.applications) == 1
    [history] = Enum.filter(edited.events, &(&1.before != nil))
    assert history.actor_id == publisher.id
    assert history.before["title"] == "旧任务"
    assert history.after["title"] == "新任务"
    assert history.before["reward_amount"] == 40
    assert history.after["reward_amount"] == 40
    assert history.before["funding_node_id"] == first_node.id
    assert history.after["funding_node_id"] == first_node.id
    assert history.before["node_name"] == first_node.name
    assert history.after["node_name"] == first_node.name
    assert history.before["attachment_ids"] == []

    old_uri = "rice://tasks/#{task.id}"
    assert Repo.get_by!(Rice.Grains.Receipt, subject_uri: old_uri, kind: "reserved").amount == 40
    assert Repo.aggregate(Rice.Grains.Receipt, :count) == 1
    assert {:ok, _} = Tasks.update_task(publisher, edited, %{title: "新任务"})
    assert {:error, :forbidden} = Tasks.update_task(worker, edited, %{title: "不能修改"})
    assert Repo.aggregate(from(e in Rice.Tasks.Event, where: not is_nil(e.before)), :count) == 1

    assert {:error, changeset} =
             Tasks.update_task(publisher, edited, %{reward_amount: 200})

    assert "已发布任务不能修改任务奖励" in errors_on(changeset).reward_amount
    assert Repo.aggregate(from(e in Rice.Tasks.Event, where: not is_nil(e.before)), :count) == 1
    assert Repo.aggregate(Rice.Grains.Receipt, :count) == 1

    assert {:ok, cancelled} = Tasks.cancel(publisher, edited)
    assert cancelled.reward_status == "refunded"
    assert Repo.get_by!(Rice.Grains.Receipt, subject_uri: old_uri, kind: "refunded").amount == 40

    assert {:ok, reopened} =
             Tasks.update_task(publisher, cancelled, %{
               node_id: second_node.id,
               reward_amount: 70,
               title: "重新开放的任务"
             })

    assert reopened.status == "open"
    assert reopened.round == 2
    assert reopened.reward_amount == 70
    assert reopened.funding_node_id == second_node.id
    assert Enum.map(reopened.applications, & &1.id) == [old_application.id]
    assert Enum.count(reopened.applications, &(&1.round == 2)) == 0

    assert Repo.get_by!(Rice.Grains.Receipt,
             subject_uri: reopened.reward_subject_uri,
             kind: "reserved"
           ).from_node_id == second_node.id

    assert Rice.Grains.reconcile().ok?
  end

  test "同社区管理员可编辑已发布任务，编辑记录和到期通知记实际操作者" do
    publisher = task_publisher_fixture()
    node = Repo.get_by!(Rice.Community.Node, user_id: publisher.id)
    editor = user_fixture()
    outsider = user_fixture()
    worker = user_fixture()
    node_fixture(%{user_id: outsider.id})

    membership =
      Repo.insert!(
        Rice.Community.Membership.changeset(%Rice.Community.Membership{
          node_id: node.id,
          user_id: editor.id,
          role: "admin"
        })
      )

    assert {:ok, draft} =
             Tasks.create_task(publisher, %{
               status: "draft",
               title: "原任务",
               description: "原说明",
               organizer_contact: "社区服务台"
             })

    refute Tasks.can_edit?(draft, editor)
    assert {:error, :forbidden} = Tasks.update_task(editor, draft, %{title: "越权草稿"})

    assert {:ok, published} = Tasks.publish_draft(publisher, draft)
    assert Tasks.can_edit?(published, editor)
    assert {:error, :forbidden} = Tasks.update_task(outsider, published, %{title: "其他社区"})
    assert {:ok, edited} = Tasks.update_task(editor, published, %{title: "管理员修订"})

    [history] = Enum.filter(edited.events, &(&1.before != nil))
    assert history.actor_id == editor.id
    assert history.actor.nickname == editor.nickname
    assert history.after["title"] == "管理员修订"

    rendered = RiceWeb.Api.TaskJSON.show(%{task: edited, current_user: editor}).data
    [rendered_history] = Enum.filter(rendered.events, &(&1.action == "edited"))
    assert rendered_history.actor.id == editor.id
    assert rendered_history.actor.nickname == editor.nickname

    assert {:ok, _} = Tasks.apply(worker, edited, %{contact: "测试联系方式"})

    assert {:ok, expired} =
             Tasks.update_task(editor, edited, %{
               application_deadline: DateTime.add(DateTime.utc_now(), -60)
             })

    assert expired.status == "expired"

    assert Repo.get_by!(Rice.Tasks.Notification,
             task_id: published.id,
             recipient_id: worker.id,
             event: "task_expired"
           ).actor_id == editor.id

    Repo.update!(Ecto.Changeset.change(membership, role: "member"))
    refute Tasks.can_edit?(expired, editor)
    assert {:error, :forbidden} = Tasks.update_task(editor, expired, %{title: "撤权后编辑"})
  end

  test "已失效任务重新开放须提供将来的申请截止时间" do
    publisher = task_publisher_fixture()

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               title: "原任务",
               description: "原说明",
               organizer_contact: "社区服务台",
               application_deadline: DateTime.add(DateTime.utc_now(), 3600)
             })

    past = DateTime.add(DateTime.utc_now(), -60)
    Repo.update!(change(task, application_deadline: past))
    assert {:ok, edited} = Tasks.update_task(publisher, task, %{title: "修正后的任务"})
    assert edited.title == "修正后的任务"
    assert edited.application_deadline == past
    assert edited.status == "expired"

    assert {:error, changeset} = Tasks.update_task(publisher, edited, %{})
    assert "重新开放需要将来的申请截止时间" in errors_on(changeset).application_deadline

    assert {:error, changeset} =
             Tasks.update_task(publisher, edited, %{application_deadline: DateTime.add(past, -60)})

    assert "重新开放需要将来的申请截止时间" in errors_on(changeset).application_deadline
    assert Repo.get!(Rice.Tasks.Task, task.id).round == 1
  end

  test "取消后重新开放空白新轮次，旧申请仍可私下查看且不能操作" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    other = user_fixture()
    funded_node_fixture(publisher, 100)

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               title: "两轮任务",
               description: "保留旧记录",
               organizer_contact: "社区服务台",
               reward_amount: 40,
               application_deadline: DateTime.add(DateTime.utc_now(), 3600)
             })

    assert {:ok, old_application} = Tasks.apply(worker, task, %{contact: "旧联系方式"})
    assert {:ok, rejected_application} = Tasks.apply(other, task, %{contact: "另一联系方式"})
    assert {:ok, task} = Tasks.reject_application(publisher, task, rejected_application.id)
    assert {:ok, cancelled} = Tasks.cancel(publisher, task)

    assert {:ok, reopened} =
             Tasks.update_task(publisher, cancelled, %{
               application_deadline: DateTime.add(DateTime.utc_now(), 7200)
             })

    assert reopened.status == "open"
    assert reopened.round == 2
    assert length(reopened.applications) == 2
    assert Repo.get!(Rice.Tasks.Application, old_application.id).final_status == "cancelled"

    assert Repo.get!(Rice.Tasks.Application, rejected_application.id).final_status ==
             "not_selected"

    assert Enum.filter(reopened.applications, &(&1.round == 2)) == []
    assert {:error, :not_found} = Tasks.appoint(publisher, reopened, old_application.id)

    assert {:ok, fresh_application} =
             Tasks.apply(worker, reopened, %{contact: "新一期联系方式"})

    assert fresh_application.id != old_application.id
    assert fresh_application.round == 2

    assert {:ok, fresh} = Tasks.fetch_task(reopened.id, worker)
    worker_data = RiceWeb.Api.TaskJSON.show(%{task: fresh, current_user: worker}).data

    assert worker_data.application_count == 1
    assert worker_data.my_application.id == fresh_application.id
    assert [%{id: old_id, status: "cancelled", round: 1}] = worker_data.past_applications
    assert old_id == old_application.id
    assert Rice.Grains.reconcile().ok?
  end

  test "已完成任务不允许再编辑，原交付和发放流水保持不变" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    node = funded_node_fixture(publisher, 100)

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               title: "可续办任务",
               description: "第一轮完成后再开放",
               organizer_contact: "社区服务台",
               reward_amount: 40,
               application_deadline: DateTime.add(DateTime.utc_now(), 3600)
             })

    assert {:ok, old_application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})
    assert {:ok, assigned} = Tasks.appoint(publisher, task, old_application.id)
    assert {:ok, review} = Tasks.submit_result(worker, assigned, %{body: "第一轮成果"})
    [old_submission] = review.submissions
    assert {:ok, completed} = Tasks.approve_result(publisher, review, old_submission.id)
    assert completed.reward_status == "settled"

    assert {:error, :conflict} =
             Tasks.update_task(publisher, completed, %{
               application_deadline: DateTime.add(DateTime.utc_now(), 7200)
             })

    assert {:error, :conflict} = Tasks.update_task(publisher, completed, %{title: "新标题"})
    assert {:error, :conflict} = Tasks.update_task(publisher, completed, %{reward_amount: 0})
    assert Repo.get!(Rice.Tasks.Task, task.id).status == "completed"
    assert Repo.get!(Rice.Tasks.Task, task.id).round == 1
    assert Repo.get!(Rice.Tasks.Submission, old_submission.id).final_status == nil
    assert Repo.get!(Rice.Tasks.Application, old_application.id).final_status == nil
    assert Repo.aggregate(Rice.Grains.Receipt, :count) == 2

    assert Enum.any?(
             Tasks.list_tasks(worker, %{"mine" => "assigned"}).entries,
             &(&1.id == task.id)
           )

    old_uri = "rice://tasks/#{task.id}"
    assert Repo.get_by!(Rice.Grains.Receipt, subject_uri: old_uri, kind: "settled").amount == 40

    assert Repo.get!(Rice.Community.Node, node.id).grain_frozen_balance == 0
    publisher_data = RiceWeb.Api.TaskJSON.show(%{task: completed, current_user: publisher}).data
    refute "edit" in publisher_data.allowed_actions
    assert Rice.Grains.reconcile().ok?
  end

  test "编辑任务使申请截止成为过去时，按旧约退款并结束当前轮次" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    old_node = funded_node_fixture(publisher, 100)

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               node_id: old_node.id,
               title: "临近截止任务",
               description: "改期限时结束",
               organizer_contact: "社区服务台",
               reward_amount: 40,
               application_deadline: DateTime.add(DateTime.utc_now(), 3600)
             })

    assert {:ok, _} = Tasks.apply(worker, task, %{contact: "测试联系方式"})

    assert {:ok, expired} =
             Tasks.update_task(publisher, task, %{
               application_deadline: DateTime.add(DateTime.utc_now(), -60)
             })

    assert expired.status == "expired"
    assert expired.round == 1
    assert expired.reward_status == "refunded"
    assert expired.reward_amount == 40
    assert expired.funding_node_id == old_node.id

    assert Repo.get_by!(Rice.Grains.Receipt,
             subject_uri: "rice://tasks/#{task.id}",
             kind: "refunded"
           ).amount == 40

    assert Repo.aggregate(Rice.Grains.Receipt, :count) == 2
    assert Repo.get!(Rice.Community.Node, old_node.id).grain_frozen_balance == 0
    assert [%{event: "task_expired"}] = Tasks.list_notifications(worker)
    assert Rice.Grains.reconcile().ok?
  end

  test "已超时任务延长交付时间后回到进行中" do
    publisher = task_publisher_fixture()
    worker = user_fixture()

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               title: "延长交付",
               description: "按新期限恢复状态",
               organizer_contact: "社区服务台",
               execution_deadline: DateTime.add(DateTime.utc_now(), 3600)
             })

    assert {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})
    assert {:ok, assigned} = Tasks.appoint(publisher, task, application.id)

    assert {:ok, overdue} =
             Tasks.update_task(publisher, assigned, %{
               execution_deadline: DateTime.add(DateTime.utc_now(), -60)
             })

    assert overdue.status == "overdue"
    assert Enum.count(Tasks.list_notifications(worker), &(&1.event == "task_overdue")) == 1

    assert {:ok, resumed} =
             Tasks.update_task(publisher, overdue, %{
               execution_deadline: DateTime.add(DateTime.utc_now(), 7200)
             })

    assert resumed.status == "in_progress"
    assert resumed.round == 1
    assert resumed.assignee_id == worker.id
  end

  test "申请截止未任命即失效并退款，24小时后只保留私有历史" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    stranger = user_fixture()
    node = funded_node_fixture(publisher, 100)

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "申请即将截止",
               description: "未选人后失效",
               reward_amount: 70
             })

    assert {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})

    task =
      task
      |> change(application_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Repo.update!()

    assert {:error, :conflict} = Tasks.appoint(publisher, task, application.id)
    assert {:error, :conflict} = Tasks.reject_application(publisher, task, application.id)
    assert {:error, :conflict} = Tasks.cancel(publisher, task)
    assert {:ok, [_]} = Tasks.check_due_tasks()
    assert [public] = Tasks.list_tasks(nil, %{"status" => "expired"}).entries
    assert public.id == task.id
    assert {:ok, _} = Tasks.check_due_tasks()
    assert {:ok, expired} = Tasks.fetch_task(task.id, worker)
    assert expired.status == "expired"
    assert expired.assignee_id == nil
    assert expired.reward_status == "refunded"
    assert Enum.count(expired.events, &(&1.to_status == "expired")) == 1
    assert {:error, :conflict} = Tasks.apply(stranger, expired, %{contact: "测试联系方式"})
    assert {:error, :conflict} = Tasks.appoint(publisher, expired, application.id)
    assert [%{event: "task_expired"}] = Tasks.list_notifications(worker)
    assert [history] = Tasks.list_tasks(worker, %{"mine" => "applied"}).entries
    assert history.id == task.id

    assert %{grain_balance: 100, grain_frozen_balance: 0} =
             Repo.get!(Rice.Community.Node, node.id)

    expired
    |> change(application_deadline: DateTime.add(DateTime.utc_now(), -86_401, :second))
    |> Repo.update!()

    assert Tasks.list_tasks(nil).entries == []
    assert Tasks.list_tasks(stranger, %{"status" => "expired"}).entries == []
    assert {:error, :not_found} = Tasks.fetch_task(task.id, stranger)
    assert {:ok, %{status: "expired"}} = Tasks.fetch_task(task.id, publisher)
    assert {:ok, %{status: "expired"}} = Tasks.fetch_task(task.id, worker)
    assert [mine] = Tasks.list_tasks(publisher, %{"mine" => "created"}).entries
    assert mine.id == task.id
    assert :ok = Rice.Workers.ExpireTasks.perform(%Oban.Job{args: %{}})
    assert Rice.Grains.reconcile().ok?
  end

  test "失效退款失败时不写入失效状态或通知" do
    publisher = task_publisher_fixture()
    node = funded_node_fixture(publisher, 100)

    {:ok, task} =
      Tasks.create_task(publisher, %{
        organizer_contact: "社区服务台",
        title: "退款不可丢失",
        description: "账本异常时保持原状",
        reward_amount: 70
      })

    {:ok, healthy} =
      Tasks.create_task(publisher, %{
        organizer_contact: "社区服务台",
        title: "其他任务照常失效",
        description: "单笔退款不阻断批次",
        reward_amount: 20
      })

    Repo.get_by!(Rice.Grains.Receipt, subject_uri: "rice://tasks/#{task.id}", kind: "reserved")
    |> Repo.delete!()

    task
    |> change(application_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    healthy
    |> change(application_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:error, :grain_reservation_missing} = Tasks.check_due_tasks()
    assert %{status: "open", reward_status: "reserved"} = Repo.get!(Rice.Tasks.Task, task.id)

    assert %{status: "expired", reward_status: "refunded"} =
             Repo.get!(Rice.Tasks.Task, healthy.id)

    refute Repo.exists?(
             from e in Rice.Tasks.Event, where: e.task_id == ^task.id and e.to_status == "expired"
           )

    assert Repo.exists?(
             from e in Rice.Tasks.Event,
               where: e.task_id == ^healthy.id and e.to_status == "expired"
           )

    assert %{grain_balance: 30, grain_frozen_balance: 70} =
             Repo.get!(Rice.Community.Node, node.id)
  end

  test "定时任务尚未运行时，截止超过24小时的招募任务不公开" do
    publisher = task_publisher_fixture()
    applicant = user_fixture()
    task = task_fixture(publisher)
    assert {:ok, _} = Tasks.apply(applicant, task, %{contact: "测试联系方式"})

    task
    |> change(application_deadline: DateTime.add(DateTime.utc_now(), -86_401, :second))
    |> Repo.update!()

    assert Repo.get!(Rice.Tasks.Task, task.id).status == "open"
    assert Tasks.list_tasks(nil).entries == []
    assert {:error, :not_found} = Tasks.fetch_task(task.id)
    assert {:ok, _} = Tasks.fetch_task(task.id, publisher)
    assert {:ok, _} = Tasks.fetch_task(task.id, applicant)
    assert [history] = Tasks.list_tasks(applicant, %{"mine" => "applied"}).entries
    assert history.id == task.id
  end

  test "交付超时保留承接人和冻结报酬，补交及验收照常进行" do
    publisher = task_publisher_fixture()
    node = funded_node_fixture(publisher, 100)

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "到期保留",
               description: "保持原有约定",
               reward_amount: 70
             })

    worker = user_fixture()
    assert {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})
    assert {:ok, assigned} = Tasks.appoint(publisher, task, application.id)

    assigned
    |> change(execution_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:ok, [_]} = Tasks.check_due_tasks()
    assert {:ok, overdue} = Tasks.fetch_task(task.id, worker)
    assert {:ok, _} = Tasks.check_due_tasks()
    assert overdue.status == "overdue"
    assert overdue.assignee_id == worker.id
    assert overdue.reward_status == "reserved"
    assert Enum.count(overdue.events, &(&1.to_status == "overdue")) == 1
    assert Enum.count(Tasks.list_notifications(worker), &(&1.event == "task_overdue")) == 1

    assert %{grain_balance: 30, grain_frozen_balance: 70} =
             Repo.get!(Rice.Community.Node, node.id)

    assert {:ok, review} = Tasks.submit_result(worker, assigned, %{body: "超时补交的成果"})
    assert review.status == "under_review"

    assert Enum.any?(
             review.events,
             &(&1.from_status == "overdue" and &1.to_status == "under_review")
           )

    first_submission = Enum.find(review.submissions, &is_nil(&1.review_reason))
    assert {:ok, returned} = Tasks.request_changes(publisher, review, first_submission.id, "请补充")
    assert returned.status == "overdue"
    assert {:ok, second_review} = Tasks.submit_result(worker, returned, %{body: "补充后的成果"})
    second_submission = Enum.find(second_review.submissions, &is_nil(&1.review_reason))
    assert {:ok, completed} = Tasks.approve_result(publisher, second_review, second_submission.id)
    assert completed.status == "completed"
    assert completed.reward_status == "settled"
    assert Repo.get!(Rice.Accounts.User, worker.id).grain_balance == 70
    assert Rice.Grains.reconcile().ok?
  end

  test "定时任务运行前迟交也留下已超时状态记录与通知" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)
    assert {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})
    assert {:ok, assigned} = Tasks.appoint(publisher, task, application.id)

    assigned
    |> change(execution_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert Repo.get!(Rice.Tasks.Task, task.id).status == "in_progress"
    assert {:ok, review} = Tasks.submit_result(worker, assigned, %{body: "截止后提交"})
    assert review.status == "under_review"

    assert Enum.take(Enum.map(review.events, &{&1.from_status, &1.to_status}), -2) == [
             {"in_progress", "overdue"},
             {"overdue", "under_review"}
           ]

    assert Enum.count(Tasks.list_notifications(worker), &(&1.event == "task_overdue")) == 1
    assert {:ok, []} = Tasks.check_due_tasks()
  end

  test "按时提交后即使验收延迟，也保持待验收" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)
    assert {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})
    assert {:ok, appointed} = Tasks.appoint(publisher, task, application.id)
    assert {:ok, review} = Tasks.submit_result(worker, appointed, %{body: "已提交成果"})

    review
    |> change(execution_deadline: DateTime.add(DateTime.utc_now(), -1, :second))
    |> Repo.update!()

    assert {:ok, _} = Tasks.check_due_tasks()
    assert {:ok, unchanged} = Tasks.fetch_task(task.id, worker)
    assert unchanged.status == "under_review"
    refute Enum.any?(unchanged.events, &(&1.to_status == "overdue"))
    refute Enum.any?(Tasks.list_notifications(worker), &(&1.event == "task_overdue"))
  end

  test "任务列表支持后端关键词和结束状态筛选" do
    publisher = task_publisher_fixture()
    matching = task_fixture(publisher, %{title: "古村门楼测绘", description: "整理尺寸"})
    _other = task_fixture(publisher, %{title: "村播剪辑", description: "整理素材"})

    assert [result] = Tasks.list_tasks(nil, %{"q" => "门楼"}).entries
    assert result.id == matching.id

    assert {:ok, _cancelled} = Tasks.cancel(publisher, matching)
    assert Tasks.list_tasks(nil, %{"status" => "closed"}).entries == []

    assert [closed] =
             Tasks.list_tasks(publisher, %{"mine" => "created", "status" => "closed"}).entries

    assert closed.id == matching.id
  end

  test "搜索按真实发布时间游标分页" do
    publisher = task_publisher_fixture()

    assert {:ok, draft} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "同一搜索词的旧草稿",
               description: "稍后发布",
               status: "draft"
             })

    assert {:ok, older_public} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "同一搜索词的公开任务",
               description: "直接发布"
             })

    assert {:ok, newer_public} = Tasks.publish_draft(publisher, draft)

    first =
      Tasks.list_tasks(nil, %{
        "q" => "同一搜索词",
        "sort" => "published",
        "limit" => "1"
      })

    assert Enum.map(first.entries, & &1.id) == [newer_public.id]
    assert is_binary(first.next_cursor)

    second =
      Tasks.list_tasks(nil, %{
        "q" => "同一搜索词",
        "sort" => "published",
        "limit" => "1",
        "before" => first.next_cursor
      })

    assert Enum.map(second.entries, & &1.id) == [older_public.id]
    assert second.next_cursor == nil
  end

  test "重新开放的任务按新一期发布时间排在旧任务之前" do
    publisher = task_publisher_fixture()

    assert {:ok, first} =
             Tasks.create_task(publisher, %{
               title: "第一份任务",
               description: "第一期",
               organizer_contact: "社区服务台",
               application_deadline: DateTime.add(DateTime.utc_now(), 3600)
             })

    second = task_fixture(publisher, %{title: "后来发布的任务"})
    assert {:ok, cancelled} = Tasks.cancel(publisher, first)

    assert {:ok, reopened} =
             Tasks.update_task(publisher, cancelled, %{
               application_deadline: DateTime.add(DateTime.utc_now(), 7200)
             })

    assert Enum.map(Tasks.list_tasks(nil, %{"sort" => "published"}).entries, & &1.id) == [
             reopened.id,
             second.id
           ]

    reopen_event =
      Enum.find(reopened.events, &(&1.from_status == "cancelled" and &1.to_status == "open"))

    assert RiceWeb.Api.TaskJSON.show(%{task: reopened}).data.published_at ==
             reopen_event.inserted_at
  end
end

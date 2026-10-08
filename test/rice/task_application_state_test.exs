defmodule Rice.TaskApplicationStateTest do
  use Rice.DataCase, async: true

  alias Rice.Tasks
  alias Rice.Tasks.Application

  defp states(task) do
    Repo.all(
      from a in Application,
        where: a.task_id == ^task.id and a.round == ^task.round,
        select: {a.user_id, a.status}
    )
    |> Map.new()
  end

  defp new_task(publisher, attrs \\ %{}) do
    {:ok, task} =
      Tasks.create_task(
        publisher,
        Map.merge(
          %{
            title: "状态机",
            description: "申请状态",
            organizer_contact: "节点服务台",
            application_deadline: DateTime.add(DateTime.utc_now(), 3600),
            execution_deadline: DateTime.add(DateTime.utc_now(), 7200)
          },
          attrs
        )
      )

    task
  end

  defp apply!(user, task) do
    {:ok, application} = Tasks.apply(user, task, %{contact: "联系方式"})
    application
  end

  test "move_applications 拒绝非法迁移,不改动行" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = new_task(publisher)
    application = apply!(worker, task)
    scope = from(a in Application, where: a.id == ^application.id)

    assert {:ok, []} = Tasks.move_applications(Repo, scope, "completed")
    assert {:ok, []} = Tasks.move_applications(Repo, scope, "under_review")
    assert %{status: "pending"} = Repo.get!(Application, application.id)
  end

  test "单人任务:申请状态与任务状态同步走完整条线" do
    publisher = task_publisher_fixture()
    [chosen, other, rejected] = for _ <- 1..3, do: user_fixture()
    task = new_task(publisher)

    a = apply!(chosen, task)
    _b = apply!(other, task)
    r = apply!(rejected, task)
    assert Enum.all?(Map.values(states(task)), &(&1 == "pending"))

    {:ok, task} = Tasks.reject_application(publisher, task, r.id)
    assert states(task)[rejected.id] == "rejected"

    {:ok, task} = Tasks.appoint(publisher, task, a.id)
    assert task.status == "in_progress"

    assert %{chosen.id => "appointed", other.id => "not_selected", rejected.id => "rejected"} ==
             states(task)

    {:ok, task} = Tasks.submit_result(chosen, task, %{body: "第一版"})
    assert task.status == "under_review"
    assert states(task)[chosen.id] == "under_review"

    {:ok, task} = Tasks.request_changes(publisher, task, hd(task.submissions).id, "补充")
    assert task.status == "in_progress"
    assert states(task)[chosen.id] == "appointed"

    {:ok, task} = Tasks.submit_result(chosen, task, %{body: "第二版"})
    latest = task.submissions |> Enum.max_by(& &1.id)
    {:ok, task} = Tasks.approve_result(publisher, task, latest.id)
    assert task.status == "completed"
    assert states(task)[chosen.id] == "completed"
  end

  test "单人任务取消 / 过期时,待处理的申请跟着变" do
    publisher = task_publisher_fixture()
    [x, y] = for _ <- 1..2, do: user_fixture()

    cancelled = new_task(publisher)
    apply!(x, cancelled)
    {:ok, cancelled} = Tasks.cancel(publisher, cancelled)
    assert cancelled.status == "cancelled"
    assert Map.values(states(cancelled)) == ["cancelled"]

    expiring = new_task(publisher)
    apply!(y, expiring)
    later = DateTime.add(DateTime.utc_now(), 7200)
    {:ok, _} = Tasks.check_due_tasks(later)
    assert Map.values(states(expiring)) == ["expired"]
  end

  test "多人任务:名额满后其余申请 not_selected,个人各自流转" do
    publisher = task_publisher_fixture()
    [first, second, third] = for _ <- 1..3, do: user_fixture()
    task = new_task(publisher, %{capacity: 2})

    [a, b, _c] = for u <- [first, second, third], do: apply!(u, task)

    {:ok, task} = Tasks.appoint(publisher, task, a.id)
    assert states(task)[first.id] == "appointed"
    assert states(task)[third.id] == "pending"

    {:ok, task} = Tasks.appoint(publisher, task, b.id)

    assert states(task) == %{
             first.id => "appointed",
             second.id => "appointed",
             third.id => "not_selected"
           }

    {:ok, task} = Tasks.submit_result(first, task, %{body: "A"})
    assert states(task)[first.id] == "under_review"
    assert states(task)[second.id] == "appointed"
    assert task.status == "under_review"

    {:ok, task} = Tasks.approve_result(publisher, task, hd(task.submissions).id)
    assert states(task)[first.id] == "completed"
    assert task.status == "in_progress"

    {:ok, task} = Tasks.submit_result(second, task, %{body: "B"})
    sub = Enum.find(task.submissions, &(&1.user_id == second.id))
    {:ok, task} = Tasks.request_changes(publisher, task, sub.id, "再改")
    assert states(task)[second.id] == "appointed"

    {:ok, task} = Tasks.submit_result(second, task, %{body: "B2"})
    sub = task.submissions |> Enum.filter(&(&1.user_id == second.id)) |> Enum.max_by(& &1.id)
    {:ok, task} = Tasks.approve_result(publisher, task, sub.id)
    assert task.status == "completed"
    assert states(task)[second.id] == "completed"
  end

  test "多人任务:交付截止后落库 overdue,延期后恢复" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    now = DateTime.utc_now()
    task = new_task(publisher, %{capacity: 2, execution_deadline: DateTime.add(now, 7200)})

    a = apply!(worker, task)
    {:ok, task} = Tasks.appoint(publisher, task, a.id)
    assert states(task)[worker.id] == "appointed"

    {:ok, _} = Tasks.check_due_tasks(DateTime.add(now, 8000))
    assert states(task)[worker.id] == "overdue"

    {:ok, task} =
      Tasks.update_task(publisher, task, %{execution_deadline: DateTime.add(now, 20_000)})

    assert states(task)[worker.id] == "appointed"
    assert task.status == "in_progress"
  end

  test "单人任务:编辑把申请截止改到过去,任务过期,待处理申请跟着 expired" do
    publisher = task_publisher_fixture()
    funded_node_fixture(publisher, 10)
    [first, second] = for _ <- 1..2, do: user_fixture()
    task = new_task(publisher, %{reward_amount: 10})
    for u <- [first, second], do: apply!(u, task)

    {:ok, task} =
      Tasks.update_task(publisher, task, %{
        application_deadline: DateTime.add(DateTime.utc_now(), -60)
      })

    assert task.status == "expired"
    assert task.reward_status == "refunded"
    assert states(task) == %{first.id => "expired", second.id => "expired"}
    assert node_balance(publisher) == {10, 0}
  end

  test "单人任务:定时任务记超期后申请 overdue,延期恢复后回到 appointed" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    now = DateTime.utc_now()

    task =
      new_task(publisher, %{
        application_deadline: DateTime.add(now, 50),
        execution_deadline: DateTime.add(now, 100)
      })

    a = apply!(worker, task)
    {:ok, task} = Tasks.appoint(publisher, task, a.id)

    assert {:ok, [%{status: "overdue"}]} = Tasks.check_due_tasks(DateTime.add(now, 200))
    assert states(task)[worker.id] == "overdue"
    assert {:ok, []} = Tasks.check_due_tasks(DateTime.add(now, 200))

    {:ok, task} =
      Tasks.update_task(publisher, task, %{execution_deadline: DateTime.add(now, 9000)})

    assert task.status == "in_progress"
    assert states(task)[worker.id] == "appointed"

    {:ok, task} = Tasks.submit_result(worker, task, %{body: "成果"})
    assert states(task)[worker.id] == "under_review"
    {:ok, task} = Tasks.approve_result(publisher, task, hd(task.submissions).id)
    assert states(task)[worker.id] == "completed"
  end

  test "多人任务:拒绝是终态,名额空出来也不会复活;落选的会" do
    publisher = task_publisher_fixture()
    [first, second, third] = for _ <- 1..3, do: user_fixture()
    task = new_task(publisher, %{capacity: 1 + 1})
    [a, b, c] = for u <- [first, second, third], do: apply!(u, task)

    {:ok, task} = Tasks.reject_application(publisher, task, c.id)
    assert states(task)[third.id] == "rejected"
    {:ok, task} = Tasks.appoint(publisher, task, a.id)
    {:ok, task} = Tasks.appoint(publisher, task, b.id)
    # 名额已满,再拒绝一个已指派的人不行
    assert {:error, :conflict} = Tasks.reject_application(publisher, task, a.id)

    {:ok, task} = Tasks.release_assignee(publisher, task, b.id)

    assert states(task) == %{
             first.id => "appointed",
             second.id => "released",
             third.id => "rejected"
           }

    assert {:error, :conflict} = Tasks.appoint(publisher, task, c.id)
  end

  test "多人任务:申请截止后落选,延期后重新排队,再截止再落选" do
    publisher = task_publisher_fixture()
    [first, second] = for _ <- 1..2, do: user_fixture()
    now = DateTime.utc_now()

    task =
      new_task(publisher, %{
        capacity: 3,
        application_deadline: DateTime.add(now, 100),
        execution_deadline: DateTime.add(now, 20_000)
      })

    [a, _b] = for u <- [first, second], do: apply!(u, task)
    {:ok, task} = Tasks.appoint(publisher, task, a.id)

    {:ok, _} = Tasks.check_due_tasks(DateTime.add(now, 200))
    assert states(task)[second.id] == "not_selected"

    assert Enum.count(Tasks.list_notifications(second), &(&1.event == "application_not_selected")) ==
             1

    {:ok, task} =
      Tasks.update_task(publisher, task, %{application_deadline: DateTime.add(now, 9000)})

    assert states(task)[second.id] == "pending"
    assert Tasks.accepting_applications?(task)

    {:ok, task} =
      Tasks.update_task(publisher, task, %{application_deadline: DateTime.add(now, 100)})

    {:ok, _} = Tasks.check_due_tasks(DateTime.add(now, 200))
    assert states(task)[second.id] == "not_selected"

    assert Enum.count(Tasks.list_notifications(second), &(&1.event == "application_not_selected")) ==
             2
  end

  test "重新开放进入下一轮:旧轮次申请保留终态,新轮次从空开始" do
    publisher = task_publisher_fixture()
    funded_node_fixture(publisher, 100)
    worker = user_fixture()
    task = new_task(publisher, %{capacity: 2, reward_amount: 10})
    apply!(worker, task)
    {:ok, task} = Tasks.cancel(publisher, task)
    assert states(task)[worker.id] == "cancelled"
    assert node_balance(publisher) == {100, 0}

    {:ok, reopened} =
      Tasks.update_task(publisher, task, %{
        application_deadline: DateTime.add(DateTime.utc_now(), 3600),
        reward_amount: 20
      })

    assert reopened.round == 2 and reopened.status == "open"
    assert states(reopened) == %{}
    assert node_balance(publisher) == {60, 40}

    old = Repo.one!(from a in Application, where: a.task_id == ^task.id and a.round == 1)
    assert {old.status, old.final_status} == {"cancelled", "cancelled"}

    b = apply!(worker, reopened)
    {:ok, reopened} = Tasks.appoint(publisher, reopened, b.id)
    assert Repo.get!(Application, b.id).reward_slot == 1
    assert states(reopened) == %{worker.id => "appointed"}
    assert Rice.Grains.reconcile().ok?
  end

  defp node_balance(publisher) do
    %{grain_balance: b, grain_frozen_balance: f} =
      Repo.get_by!(Rice.Community.Node, user_id: publisher.id)

    {b, f}
  end

  test "多人任务:撤销指派让出名额,编号和冻结留给下一个人;没人承作时回到 open" do
    publisher = task_publisher_fixture()
    funded_node_fixture(publisher, 90)
    [first, second, third] = for _ <- 1..3, do: user_fixture()
    task = new_task(publisher, %{capacity: 2, reward_amount: 30})
    assert node_balance(publisher) == {30, 60}

    [a, b, c] = for u <- [first, second, third], do: apply!(u, task)
    {:ok, task} = Tasks.appoint(publisher, task, a.id)
    {:ok, task} = Tasks.appoint(publisher, task, b.id)
    assert states(task)[third.id] == "not_selected"

    # 等待验收的不能撤
    {:ok, task} = Tasks.submit_result(second, task, %{body: "B"})
    assert {:error, :conflict} = Tasks.release_assignee(publisher, task, b.id)

    {:ok, task} = Tasks.release_assignee(publisher, task, a.id, %{"reason" => "联系不上"})
    assert states(task)[first.id] == "released"
    assert states(task)[third.id] == "pending"
    assert Repo.get!(Application, a.id).reward_slot == nil
    # 冻结不动,名额让出来
    assert node_balance(publisher) == {30, 60}
    assert task.status == "under_review"

    # 被撤销的人留着 appointed_at,列表筛选不能拿它当"还在承接"
    ids = fn user, params -> Enum.map(Tasks.list_tasks(user, params).entries, & &1.id) end
    assert task.id in ids.(user_fixture(), %{"available" => "true"})
    refute task.id in ids.(first, %{"mine" => "assigned"})
    assert task.id in ids.(first, %{"mine" => "applied"})
    refute task.id in ids.(nil, %{"participant_did" => first.did})
    assert task.id in ids.(nil, %{"participant_did" => second.did})

    {:ok, task} = Tasks.appoint(publisher, task, c.id)
    assert Repo.get!(Application, c.id).reward_slot == 1
    assert {:error, :conflict} = Tasks.release_assignee(publisher, task, a.id)

    sub = Enum.find(task.submissions, &(&1.user_id == second.id))
    {:ok, task} = Tasks.approve_result(publisher, task, sub.id)
    {:ok, task} = Tasks.release_assignee(publisher, task, c.id)
    assert task.status == "in_progress"

    # 把唯一还在承作的人撤掉:已完成的还占着名额,任务继续;再把名额填满就能完成
    assert states(task) == %{
             first.id => "released",
             second.id => "completed",
             third.id => "released"
           }

    assert Rice.Grains.reconcile().ok?
  end

  test "多人任务:全部撤销后回到 open,过了申请截止由定时任务退款过期" do
    publisher = task_publisher_fixture()
    funded_node_fixture(publisher, 60)
    worker = user_fixture()
    now = DateTime.utc_now()
    task = new_task(publisher, %{capacity: 2, reward_amount: 30})

    a = apply!(worker, task)
    {:ok, task} = Tasks.appoint(publisher, task, a.id)
    {:ok, task} = Tasks.release_assignee(publisher, task, a.id)
    assert task.status == "open"
    assert node_balance(publisher) == {0, 60}

    {:ok, _} = Tasks.check_due_tasks(DateTime.add(now, 4000))
    task = Repo.get!(Rice.Tasks.Task, task.id)
    assert task.status == "expired"
    assert task.reward_status == "refunded"
    assert node_balance(publisher) == {60, 0}
    assert Rice.Grains.reconcile().ok?
  end

  test "多人任务:提前结束,已验收的算完成,其余撤销并退回冻结" do
    publisher = task_publisher_fixture()
    funded_node_fixture(publisher, 100)
    [first, second, third, fourth] = for _ <- 1..4, do: user_fixture()
    task = new_task(publisher, %{capacity: 3, reward_amount: 30})
    assert node_balance(publisher) == {10, 90}

    [a, b, _c, _d] = for u <- [first, second, third, fourth], do: apply!(u, task)
    {:ok, task} = Tasks.appoint(publisher, task, a.id)
    {:ok, task} = Tasks.appoint(publisher, task, b.id)
    {:ok, task} = Tasks.submit_result(first, task, %{body: "A"})

    # 有成果等待验收时不能结束
    assert {:error, :conflict} = Tasks.close(publisher, task)
    {:ok, task} = Tasks.approve_result(publisher, task, hd(task.submissions).id)
    assert node_balance(publisher) == {10, 60}

    {:ok, task} = Tasks.close(publisher, task)
    assert task.status == "completed"
    assert task.reward_status == "settled"

    assert states(task) == %{
             first.id => "completed",
             second.id => "released",
             third.id => "not_selected",
             fourth.id => "not_selected"
           }

    assert node_balance(publisher) == {70, 0}
    assert Rice.Grains.reconcile().ok?
    assert {:error, :conflict} = Tasks.close(publisher, task)
  end

  test "多人任务:一个都没验收就提前结束,记为 cancelled 并全额退回" do
    publisher = task_publisher_fixture()
    funded_node_fixture(publisher, 60)
    worker = user_fixture()
    task = new_task(publisher, %{capacity: 2, reward_amount: 30})

    a = apply!(worker, task)
    {:ok, task} = Tasks.appoint(publisher, task, a.id)
    assert {:error, :forbidden} = Tasks.close(worker, task)

    {:ok, task} = Tasks.close(publisher, task)
    assert task.status == "cancelled"
    assert task.reward_status == "refunded"
    assert states(task)[worker.id] == "released"
    assert node_balance(publisher) == {60, 0}
    assert Rice.Grains.reconcile().ok?
  end

  test "定时任务只在多人任务还有事可做时处理它" do
    publisher = task_publisher_fixture()
    [first, second] = for _ <- 1..2, do: user_fixture()
    now = DateTime.utc_now()

    task =
      new_task(publisher, %{
        capacity: 3,
        application_deadline: DateTime.add(now, 100),
        execution_deadline: DateTime.add(now, 200)
      })

    [a, _b] = for u <- [first, second], do: apply!(u, task)
    {:ok, task} = Tasks.appoint(publisher, task, a.id)

    # 申请截止:把 pending 迁成 not_selected
    assert {:ok, [%{id: id}]} = Tasks.check_due_tasks(DateTime.add(now, 150))
    assert id == task.id
    assert states(task)[second.id] == "not_selected"
    # 再跑一次没事可做
    assert {:ok, []} = Tasks.check_due_tasks(DateTime.add(now, 150))

    # 交付截止:把 appointed 记成 overdue,再跑一次同样空转
    assert {:ok, [%{status: "overdue"}]} = Tasks.check_due_tasks(DateTime.add(now, 250))
    assert {:ok, []} = Tasks.check_due_tasks(DateTime.add(now, 250))

    # 唯一承作人交付并通过(真实时间里申请还没截止,任务仍在进行中);
    # 到了申请截止,人没满也该收尾:定时任务把它记成 completed,之后不再碰
    {:ok, task} = Tasks.submit_result(first, task, %{body: "A"})
    {:ok, task} = Tasks.approve_result(publisher, task, hd(task.submissions).id)
    assert task.status == "in_progress"
    assert {:ok, [%{status: "completed"}]} = Tasks.check_due_tasks(DateTime.add(now, 300))
    assert {:ok, []} = Tasks.check_due_tasks(DateTime.add(now, 300))
  end
end

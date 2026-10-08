defmodule Rice.TaskApplicationStateTest do
  use Rice.DataCase, async: true

  alias Rice.Tasks
  alias Rice.Tasks.{Application, ApplicationState}

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

  test "迁移表只含合法状态,终态没有出口" do
    for {from, tos} <- ApplicationState.transitions(), to <- tos do
      assert from in ApplicationState.states() and to in ApplicationState.states()
    end

    for final <- ~w(completed rejected cancelled expired),
        do: assert(ApplicationState.transitions()[final] == [])

    refute ApplicationState.can?("completed", "appointed")
    assert ApplicationState.can?("under_review", "appointed")
    assert ApplicationState.legacy("under_review") == "appointed"
    assert ApplicationState.legacy("rejected") == "not_selected"
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
end

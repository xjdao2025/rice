defmodule Rice.TaskApplicationRejectionTest do
  use Rice.DataCase, async: true

  alias Rice.Tasks
  alias Rice.Tasks.Application

  test "拒绝只关闭指定候选，重复处理不重复通知或解冻，其他人仍可任命" do
    publisher = task_publisher_fixture()
    rejected = user_fixture()
    selected = user_fixture()
    node = funded_node_fixture(publisher, 100)

    {:ok, task} =
      Tasks.create_task(publisher, %{
        organizer_contact: "社区服务台",
        title: "筛选候选人",
        description: "保留其他候选",
        reward_amount: 60
      })

    {:ok, application} = Tasks.apply(rejected, task, %{contact: "测试联系方式"})
    assert {:ok, result} = Tasks.reject_application(publisher, task, application.id)
    assert result.status == "open"
    assert result.reward_status == "reserved"
    assert is_nil(result.assignee_id)
    assert %DateTime{} = hd(result.applications).rejected_at
    rejected_at = hd(result.applications).rejected_at

    assert {:ok, repeated} = Tasks.reject_application(publisher, task, application.id)
    assert hd(repeated.applications).rejected_at == rejected_at
    assert [%{event: "application_rejected"}] = Tasks.list_notifications(rejected)
    assert [%{reason: "task-application_rejected"}] = Rice.Inbox.list(rejected)
    assert {:error, :conflict} = Tasks.appoint(publisher, task, application.id)

    assert {:ok, duplicate} = Tasks.apply(rejected, task, %{contact: "测试联系方式", reason: "再试一次"})
    assert duplicate.id == application.id
    assert duplicate.rejected_at == rejected_at
    assert Repo.aggregate(from(a in Application, where: a.task_id == ^task.id), :count) == 1

    assert {:ok, other_application} = Tasks.apply(selected, task, %{contact: "测试联系方式"})
    assert {:ok, appointed} = Tasks.appoint(publisher, task, other_application.id)
    assert appointed.assignee_id == selected.id
    assert [%{event: "application_rejected"}] = Tasks.list_notifications(rejected)
    assert [%{event: "assignee_appointed"}] = Tasks.list_notifications(selected)

    assert %{grain_balance: 40, grain_frozen_balance: 60} =
             Repo.get!(Rice.Community.Node, node.id)

    assert [%{kind: "reserved", amount: 60}] = Repo.all(Rice.Grains.Receipt)
    assert Rice.Grains.reconcile().ok?
  end

  test "权限、跨任务申请和过期快照不能绕过拒绝检查" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)
    other_task = task_fixture(publisher)
    {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})
    {:ok, other_application} = Tasks.apply(worker, other_task, %{contact: "测试联系方式"})

    assert {:error, :forbidden} = Tasks.reject_application(worker, task, application.id)
    assert {:error, :not_found} = Tasks.reject_application(publisher, task, other_application.id)
    assert {:error, :not_found} = Tasks.reject_application(publisher, task, "invalid-id")
    assert {:error, :not_found} = Tasks.reject_application(publisher, task, Rice.Tsid.generate())
    assert is_nil(Repo.get!(Application, application.id).rejected_at)

    assert {:ok, _} = Tasks.appoint(publisher, task, application.id)
    assert {:error, :conflict} = Tasks.reject_application(publisher, task, application.id)
    assert is_nil(Repo.get!(Application, application.id).rejected_at)
    assert [%{event: "assignee_appointed"}] = Tasks.list_notifications(worker)

    assert {:ok, _} = Tasks.cancel(publisher, other_task)

    assert {:error, :conflict} =
             Tasks.reject_application(publisher, other_task, other_application.id)
  end

  test "申请截止后不能再拒绝候选，任务转为失效" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)
    {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})

    task
    |> change(application_deadline: DateTime.add(DateTime.utc_now(), -60))
    |> Repo.update!()

    assert {:error, :conflict} = Tasks.reject_application(publisher, task, application.id)
    assert is_nil(Repo.get!(Application, application.id).rejected_at)
    assert {:ok, [_]} = Tasks.check_due_tasks()
    assert {:ok, %{status: "expired"}} = Tasks.fetch_task(task.id, publisher)
  end

  test "旧申请未写拒绝时间时保持空值，并可按原规则任命" do
    publisher = task_publisher_fixture()
    worker = user_fixture()
    task = task_fixture(publisher)
    id = Rice.Tsid.generate()
    now = DateTime.utc_now()

    Repo.insert_all(Application, [
      %{
        id: id,
        task_id: task.id,
        user_id: worker.id,
        reason: "",
        inserted_at: now,
        updated_at: now
      }
    ])

    assert is_nil(Repo.get!(Application, id).rejected_at)
    assert {:ok, task} = Tasks.fetch_task(task.id, publisher)

    assert %{data: %{my_application_status: "pending"}} =
             RiceWeb.Api.TaskJSON.show(%{task: task, current_user: worker})

    assert {:ok, task} = Tasks.appoint(publisher, task, id)
    assert task.assignee_id == worker.id
  end
end

defmodule Rice.TaskLifecycleRegressionTest do
  use Rice.DataCase, async: true

  alias Rice.Community.Node
  alias Rice.Tasks
  alias Rice.Tasks.Application

  test "a personally funded node task notifies its publisher rather than unrelated node managers" do
    owner = task_publisher_fixture()
    node = Repo.get_by!(Node, user_id: owner.id)
    publisher = user_fixture()
    worker = user_fixture()

    Repo.insert!(%Rice.Community.Membership{
      node_id: node.id,
      user_id: publisher.id,
      role: "admin"
    })

    {:ok, _} = Rice.Grains.grant(publisher, 50)

    {:ok, task} =
      Tasks.create_task(publisher, %{
        title: "个人出资的节点任务",
        description: "申请与成果通知发起人",
        organizer_contact: "节点服务台",
        node_id: node.id,
        funding_source: "personal",
        reward_amount: 20
      })

    {:ok, application} = Tasks.apply(worker, task, %{contact: "电话"})
    {:ok, task} = Tasks.appoint(publisher, task, application.id)
    {:ok, _} = Tasks.submit_result(worker, task, %{body: "已完成"})

    notifications =
      Repo.all(
        from n in Rice.Tasks.Notification,
          where: n.task_id == ^task.id and n.event in ["application_created", "result_submitted"],
          select: {n.event, n.recipient_id}
      )

    assert Enum.sort(notifications) ==
             [{"application_created", publisher.id}, {"result_submitted", publisher.id}]
  end

  test "completing a single task retains its assignment and settles once under the existing constraints" do
    manager = task_publisher_fixture()
    worker = user_fixture()
    funded_node_fixture(manager, 100)

    {:ok, task} =
      Tasks.create_task(manager, %{
        title: "线下已经完成",
        description: "保留单人指派和已发放稻米",
        organizer_contact: "节点服务台",
        reward_amount: 30,
        application_deadline: DateTime.add(DateTime.utc_now(), 3600),
        execution_deadline: DateTime.add(DateTime.utc_now(), 7200)
      })

    {:ok, application} = Tasks.apply(worker, task, %{contact: "电话"})
    {:ok, task} = Tasks.appoint(manager, task, application.id)
    assigned_at = task.appointed_at
    {:ok, completed} = Tasks.complete(manager, task)

    assert completed.status == "completed"
    assert completed.assignee_id == worker.id
    assert completed.appointed_at == assigned_at
    assert Repo.get!(Application, application.id).status == "completed"
    assert %{grain_balance: 70, grain_frozen_balance: 0} = Repo.get_by!(Node, user_id: manager.id)
    assert Repo.get!(Rice.Accounts.User, worker.id).grain_balance == 30
    assert Rice.Grains.reconcile().ok?
    assert {:error, :conflict} = Tasks.complete(manager, completed)
    assert Repo.get!(Rice.Accounts.User, worker.id).grain_balance == 30
  end
end

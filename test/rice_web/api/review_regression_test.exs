defmodule RiceWeb.Api.ReviewRegressionTest do
  use RiceWeb.ConnCase, async: true
  import Ecto.Query
  import Mox
  alias Rice.{Accounts, Bridge, Events, Grains, Repo, Tasks, Vault}
  alias Rice.Accounts.{ApiToken, User, VerificationCode}

  setup :verify_on_exit!

  test "跨区号相同手机号不随机选人，改用唯一 handle 或邮箱" do
    first = user_fixture(%{phone: "13800000000", phone_region: "86", email: "first@example.com"})
    second = user_fixture(%{phone: first.phone, phone_region: "1"})
    refute Accounts.get_user_by_identifier(first.phone)
    refute Accounts.find_user(first.phone)
    assert Accounts.get_user_by_identifier(first.handle).id == first.id
    assert Accounts.get_user_by_identifier(first.email).id == first.id
    assert Accounts.get_user_by_identifier(second.handle).id == second.id
    assert Accounts.get_user_by_phone(first.phone, "1").id == second.id
  end

  test "管理员 last_used_at 按分钟节流，不缓存停用状态" do
    {admin, token} = admin_with_token()
    hash = Rice.Admin.AdminToken.hash(token)
    old = DateTime.add(DateTime.utc_now(), -120)

    Repo.update_all(from(t in Rice.Admin.AdminToken, where: t.token_hash == ^hash),
      set: [last_used_at: old]
    )

    assert Rice.Admin.admin_by_token(token).id == admin.id
    touched = Repo.get_by!(Rice.Admin.AdminToken, token_hash: hash).last_used_at
    assert DateTime.compare(touched, old) == :gt
    assert Rice.Admin.admin_by_token(token).id == admin.id
    assert Repo.get_by!(Rice.Admin.AdminToken, token_hash: hash).last_used_at == touched
    Repo.update!(Ecto.Changeset.change(admin, disabled_at: DateTime.utc_now()))
    refute Rice.Admin.admin_by_token(token)
  end

  test "登录使用不可变 DID；上游返回其他 DID 时绝不签发本地令牌" do
    user = user_fixture()

    expect(Rice.PDSMock, :create_session, fn did, "password" ->
      assert did == user.did
      {:ok, %{"did" => "did:plc:another", "accessJwt" => "a", "refreshJwt" => "r"}}
    end)

    assert {:error, :invalid_credentials} = Accounts.login(user.handle, "password")
    refute Repo.exists?(from t in ApiToken, where: t.user_id == ^user.id)
  end

  test "按 DID 取公开资料也预加载头像" do
    avatar = attachment_fixture()
    user = user_fixture() |> Ecto.Changeset.change(avatar_id: avatar.id) |> Repo.update!()
    assert Accounts.get_public_user(user.did).avatar.id == avatar.id
  end

  test "改密同步加密 Semi 凭据，撤销旧票，随后 Semi 登录使用新密码" do
    user = user_fixture(%{email: "reset@example.com"})
    {:ok, old_token} = Accounts.issue_token(user)
    sub = "sub-#{user.id}"

    {:ok, _} =
      Accounts.create_link(%{
        semi_sub: sub,
        did: user.did,
        handle: user.handle,
        account_password_ciphertext: Vault.encrypt("old-password")
      })

    code = seed_code("email", user.email, "reset_password")

    expect(Rice.PDSMock, :update_account_password, fn did, "new-password-123" ->
      assert did == user.did
      :ok
    end)

    assert {:ok, _} = Accounts.reset_password("email", user.email, code, "new-password-123")

    assert {:ok, "new-password-123"} =
             Vault.decrypt(Accounts.get_link_by_did(user.did).account_password_ciphertext)

    refute Accounts.user_by_token(old_token)
    assert Repo.get!(User, user.id).legacy_tokens_revoked

    expect(Rice.PDSMock, :create_session, fn did, "new-password-123" ->
      assert did == user.did
      {:ok, %{"did" => did, "handle" => user.handle, "accessJwt" => "a", "refreshJwt" => "r"}}
    end)

    expect(Rice.PDSMock, :get_profile, fn "a", did ->
      assert did == user.did
      {:ok, %{}}
    end)

    assert {:ok, %{rice_token: token}} = Bridge.session_for(%{"sub" => sub})
    assert Accounts.user_by_token(token).id == user.id
  end

  test "零奖励任务及免费申请也必须先结束；旧会话不能给注销人新增职责" do
    creator = user_fixture() |> Ecto.Changeset.change(can_publish_tasks: true) |> Repo.update!()
    applicant = user_fixture()

    attrs = %{
      title: "无资金但有职责",
      description: "回归",
      organizer_contact: "服务台",
      reward_amount: 0,
      funding_source: "personal"
    }

    {:ok, task} = Tasks.create_task(creator, attrs)
    {:ok, _} = Tasks.apply(applicant, task, %{contact: "联系方式"})
    assert {:error, :account_has_responsibilities} = Accounts.delete_user(creator)
    assert {:error, :account_has_responsibilities} = Accounts.delete_user(applicant)
    assert {:ok, _} = Tasks.cancel(creator, task)
    assert {:ok, _} = Accounts.delete_user(applicant)
    {:ok, next} = Tasks.create_task(creator, attrs)
    assert {:error, :forbidden} = Tasks.apply(applicant, next, %{contact: "旧会话"})
    refute Repo.exists?(from a in Rice.Tasks.Application, where: a.task_id == ^next.id)
  end

  test "余额或冻结余额未结清时拒绝注销，令牌和账本不变" do
    {user, token} = user_with_token()
    {:ok, _} = Grains.grant(user, 25)
    assert {:error, :account_has_balance} = Accounts.delete_user(user)
    assert Accounts.user_by_token(token)

    Repo.update_all(from(u in User, where: u.id == ^user.id),
      set: [grain_balance: 0, grain_frozen_balance: 25]
    )

    assert {:error, :account_has_balance} = Accounts.delete_user(user)
    assert is_nil(Repo.get!(User, user.id).deleted_at)
    assert Grains.reconcile().ok?
  end

  test "负责人和节点管理员必须先移交职责；停用账号不能再获任负责人" do
    owner = user_fixture()
    node = node_fixture(%{user_id: owner.id})
    assert {:error, :account_has_responsibilities} = Accounts.delete_user(owner)
    member = user_fixture()

    membership =
      Repo.insert!(%Rice.Community.Membership{
        node_id: node.id,
        user_id: member.id,
        role: "admin"
      })

    assert {:error, :account_has_responsibilities} = Accounts.delete_user(member)
    Repo.update!(Ecto.Changeset.change(membership, role: "member"))
    assert {:ok, _} = Accounts.delete_user(member)

    assert {:error, %Ecto.Changeset{}} =
             Rice.Admin.Catalog.update(:nodes, node.id, %{user_id: member.id})

    assert {:error, :forbidden} = Rice.Community.set_member_role(owner, node, member.id, "admin")
    assert Repo.get!(Rice.Community.Node, node.id).user_id == owner.id
  end

  test "旧版已注销但仍有余额的账户不从对账负债中消失，不能接受新转账" do
    sender = user_fixture()
    retired = user_fixture()
    {:ok, _} = Grains.grant(sender, 30)
    {:ok, _} = Grains.grant(retired, 10)
    Repo.update!(Ecto.Changeset.change(retired, deleted_at: DateTime.utc_now()))
    assert Grains.reconcile().ok?
    assert {:error, :recipient_not_found} = Grains.transfer(sender, retired, 5)
    assert Repo.get!(User, sender.id).grain_balance == 30
    assert Repo.get!(User, retired.id).grain_balance == 10
    assert Grains.reconcile().ok?
  end

  test "运营可编辑节点文案，但不能设置、转移或清空资金负责人" do
    {_operator, operator_token} = admin_with_token(%{role: "operator"})
    {_admin, admin_token} = admin_with_token()
    original = user_fixture()
    replacement = user_fixture()
    node = node_fixture(%{user_id: original.id})

    for owner <- [replacement.id, nil] do
      build_conn()
      |> authed(operator_token)
      |> patch(~p"/api/admin/nodes/#{node.id}", %{user_id: owner})
      |> json_response(403)
    end

    build_conn()
    |> authed(operator_token)
    |> post(~p"/api/admin/nodes", %{name: "越权创建", user_id: replacement.id})
    |> json_response(403)

    build_conn()
    |> authed(operator_token)
    |> patch(~p"/api/admin/nodes/#{node.id}", %{name: "新文案", user_id: original.id})
    |> json_response(200)

    assert Repo.get!(Rice.Community.Node, node.id).user_id == original.id

    build_conn()
    |> authed(admin_token)
    |> patch(~p"/api/admin/nodes/#{node.id}", %{user_id: replacement.id})
    |> json_response(200)

    assert Repo.get!(Rice.Community.Node, node.id).user_id == replacement.id
  end

  test "多人任务释放指派后，列表筛选与当前个人状态一致" do
    publisher = task_publisher_fixture()
    node = funded_node_fixture(publisher, 100)
    worker = user_fixture()

    {:ok, task} =
      Tasks.create_task(publisher, %{
        title: "状态一致",
        description: "回归",
        organizer_contact: "服务台",
        capacity: 2,
        reward_amount: 10,
        node_id: node.id
      })

    {:ok, application} = Tasks.apply(worker, task, %{contact: "联系方式"})
    {:ok, task} = Tasks.appoint(publisher, task, application.id)
    {:ok, task} = Tasks.release_assignee(publisher, task, application.id, %{reason: "释放名额"})
    assert Tasks.my_status(task, worker) == "open"
    assert Tasks.list_tasks(worker, %{"mine" => "assigned"}).entries == []

    assert Tasks.list_tasks(worker, %{"mine" => "applied", "status" => "in_progress"}).entries ==
             []

    assert [listed] = Tasks.list_tasks(worker, %{"mine" => "applied", "status" => "open"}).entries
    assert listed.id == task.id
  end

  test "显式 null 奖励和畸形、重复排序 ID 返回 422，不抛 CastError" do
    publisher = task_publisher_fixture()
    {:ok, token} = Accounts.issue_token(publisher)

    build_conn()
    |> authed(token)
    |> post(~p"/api/tasks", %{
      title: "非法奖励",
      description: "回归",
      organizer_contact: "服务台",
      reward_amount: nil
    })
    |> json_response(422)

    {_admin, token} = admin_with_token()
    id = Rice.Tsid.generate()

    for ids <- [["not-an-id"], [123], [nil], [%{}], [id, id]] do
      build_conn()
      |> authed(token)
      |> put(~p"/api/admin/apps/positions", %{ids: ids})
      |> json_response(422)
    end
  end

  test "重开修改费用不改变新通知快照或旧通知对应的历史报名费" do
    host = user_fixture()
    {participant, token} = user_with_token()
    node = node_fixture(%{user_id: host.id})
    {:ok, _} = Grains.grant(participant, 100)
    now = DateTime.utc_now()

    {:ok, event} =
      Events.create_event(host, %{
        node_id: node.id,
        title: "历史退款",
        description: "回归",
        organizer_contact: "服务台",
        location: "社区",
        capacity: 2,
        fee_amount: 20,
        client_request_id: "history",
        application_deadline: DateTime.add(now, 1800),
        starts_at: DateTime.add(now, 3600),
        ends_at: DateTime.add(now, 7200)
      })

    {:ok, event} = Events.apply(participant, event, %{contact: "联系方式"})

    {:ok, legacy} =
      Rice.Inbox.notify(
        Repo,
        participant.id,
        host.id,
        "event_application_rejected",
        "活动申请未通过，报名费已退回",
        "event",
        event.id
      )

    {:ok, event} = Events.cancel(host, event)

    snapshot =
      Repo.one!(
        from n in Rice.Tasks.Notification,
          where: n.recipient_id == ^participant.id and n.event == "event_application_cancelled"
      )

    assert snapshot.detail =~ "20 稻米"
    assert {:ok, _} = Events.update_event(host, event, %{fee_amount: 80})

    items =
      build_conn()
      |> authed(token)
      |> get(~p"/api/notifications")
      |> json_response(200)
      |> Map.fetch!("notifications")

    for notification <- [legacy, snapshot] do
      text =
        Enum.find(items, &(&1["uri"] == "business-notification:#{notification.id}"))["record"][
          "text"
        ]

      assert text =~ "20 稻米"
      refute text =~ "80 稻米"
    end
  end

  defp seed_code(channel, target, purpose) do
    code = VerificationCode.generate_code()
    Repo.insert!(VerificationCode.build(channel, target, purpose, code))
    code
  end
end

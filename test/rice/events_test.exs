defmodule Rice.EventsTest do
  use Rice.DataCase, async: true
  alias Rice.Events
  alias Rice.Events.{Application, Event, EventHistory}

  setup do
    host = user_fixture()
    node = node_fixture(%{user_id: host.id})
    first = user_fixture()
    second = user_fixture()
    for user <- [first, second], do: Rice.Grains.grant(user, 100)
    %{host: host, node: node, first: first, second: second}
  end

  test "草稿和发布重试复用原记录，只有节点管理员能发布", ctx do
    attrs = attrs(ctx.node, %{status: "draft"}) |> Map.delete(:client_request_id)
    assert {:ok, draft} = Events.create_event(ctx.host, attrs)
    assert {:ok, same} = Events.create_event(ctx.host, Map.put(attrs, :title, "新标题"))
    assert same.id == draft.id
    assert same.title == "新标题"
    assert {:ok, event} = Events.publish_draft(ctx.host, same)
    assert {:ok, again} = Events.publish_draft(ctx.host, draft)
    assert again.id == event.id
    assert event.status == "open"
    assert {:error, :conflict} = Events.update_draft(ctx.host, draft, %{fee_amount: 1})
    assert {:error, :forbidden} = Events.create_event(ctx.first, attrs(ctx.node))
    direct = attrs(ctx.node)
    assert {:ok, once} = Events.create_event(ctx.host, direct)
    assert {:ok, twice} = Events.create_event(ctx.host, direct)
    assert once.id == twice.id
    assert {:error, :not_found} = Events.fetch_event("not-an-id")
  end

  test "有空位时允许多个候选申请，冻结不占名额，通过才占位", ctx do
    event = event!(ctx)
    assert {:ok, one} = Events.apply(ctx.first, event, %{contact: "测试联系方式", reason: "私人申请资料"})
    assert {:ok, two} = Events.apply(ctx.second, event, %{contact: "测试联系方式"})
    assert length(two.applications) == 2
    assert balances(ctx.first) == {80, 20}
    assert balances(ctx.second) == {80, 20}
    assert {:ok, repeat} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    assert length(repeat.applications) == 2
    assert balances(ctx.first) == {80, 20}
    a = application(one, ctx.first)
    b = application(two, ctx.second)
    assert {:error, :forbidden} = Events.approve_application(ctx.second, event, a.id)
    assert {:ok, _} = Events.approve_application(ctx.host, event, a.id)
    assert {:error, :capacity_full} = Events.approve_application(ctx.host, event, b.id)
    assert {:ok, _} = Events.approve_application(ctx.host, event, a.id)
    assert Repo.get!(Application, b.id).status == "pending"
    assert Rice.Grains.reconcile().ok?
  end

  test "已发布活动不能改报名费或所属社区，其他编辑记录历史", ctx do
    second_node = node_fixture(%{user_id: ctx.host.id})
    event = event!(ctx, %{capacity: 2})
    assert {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    first = application(event, ctx.first)

    assert {:error, %Ecto.Changeset{} = invalid} =
             Events.update_event(ctx.host, event, %{fee_amount: 30, node_id: second_node.id})

    assert Keyword.has_key?(invalid.errors, :fee_amount)
    assert Keyword.has_key?(invalid.errors, :node_id)
    assert Repo.get!(Event, event.id).fee_amount == 20
    assert Repo.get!(Event, event.id).node_id == ctx.node.id

    assert {:ok, edited} =
             Events.update_event(ctx.host, event, %{
               "title" => "新活动",
               "description" => "新的活动介绍",
               "location" => "新地点",
               "organizer_contact" => "新联系方式"
             })

    assert edited.id == event.id
    assert edited.node_id == ctx.node.id
    assert edited.settlement_node_id == ctx.node.id
    [history] = Enum.filter(edited.history, &(&1.action == "edited"))
    assert history.actor_id == ctx.host.id
    assert history.before["title"] == "社区活动"
    assert history.after["title"] == "新活动"
    assert history.before["fee_amount"] == 20
    assert history.after["fee_amount"] == 20
    assert history.before["attachment_ids"] == []
    assert history.before["node_name"] == ctx.node.name
    assert history.after["node_name"] == ctx.node.name
    assert {:ok, _} = Events.update_event(ctx.host, edited, %{"title" => "新活动"})
    assert {:error, :forbidden} = Events.update_event(ctx.first, edited, %{"title" => "不能修改"})
    assert Repo.aggregate(from(h in EventHistory, where: h.action == "edited"), :count) == 1

    assert {:ok, edited} = Events.apply(ctx.second, edited, %{contact: "测试联系方式"})
    second = application(edited, ctx.second)
    assert first.fee_amount == 20
    assert Repo.get!(Application, first.id).settlement_node_id == ctx.node.id
    assert second.fee_amount == 20
    assert second.settlement_node_id == ctx.node.id
    assert {:ok, edited} = Events.approve_application(ctx.host, edited, first.id)
    assert {:ok, edited} = Events.approve_application(ctx.host, edited, second.id)
    assert {:error, :capacity_full} = Events.update_event(ctx.host, edited, %{capacity: 1})

    age_event!(edited)
    assert {:ok, finished} = Events.finish(ctx.host, edited)
    assert finished.status == "completed"
    assert Repo.get!(Rice.Community.Node, ctx.node.id).grain_balance == 40
    assert Repo.get!(Rice.Community.Node, second_node.id).grain_balance == 0
    assert Rice.Grains.reconcile().ok?
  end

  test "同社区管理员可编辑已发布活动并以本人署名，草稿和撤权受限", ctx do
    editor = user_fixture()
    outsider = user_fixture()
    node_fixture(%{user_id: outsider.id})

    membership =
      Repo.insert!(
        Rice.Community.Membership.changeset(%Rice.Community.Membership{
          node_id: ctx.node.id,
          user_id: editor.id,
          role: "admin"
        })
      )

    assert {:ok, draft} = Events.create_event(ctx.host, attrs(ctx.node, %{status: "draft"}))
    refute Events.can_edit?(draft, editor)
    assert {:error, :forbidden} = Events.update_event(editor, draft, %{title: "越权草稿"})

    assert {:ok, published} = Events.publish_draft(ctx.host, draft)
    assert Events.can_edit?(published, editor)
    assert {:error, :forbidden} = Events.update_event(outsider, published, %{title: "其他社区"})
    assert {:ok, edited} = Events.update_event(editor, published, %{title: "管理员修订"})

    [history] = Enum.filter(edited.history, &(&1.action == "edited"))
    assert history.actor_id == editor.id
    assert history.actor.nickname == editor.nickname
    assert history.after["title"] == "管理员修订"

    rendered = RiceWeb.Api.EventJSON.show(%{event: edited, current_user: editor}).data
    [rendered_history] = Enum.filter(rendered.history, &(&1.action == "edited"))
    assert rendered_history.actor.id == editor.id
    assert rendered_history.actor.nickname == editor.nickname

    legacy = Repo.update!(Ecto.Changeset.change(edited, settlement_node_id: nil))
    assert {:ok, legacy_edited} = Events.update_event(editor, legacy, %{title: "旧个人出资活动"})
    assert {:ok, cancelled} = Events.cancel(ctx.host, legacy_edited)
    assert {:ok, reopened} = Events.update_event(editor, cancelled, %{title: "社区继续举办"})
    assert reopened.status == "open"
    assert reopened.settlement_node_id == ctx.node.id
    assert Enum.any?(reopened.history, &(&1.actor_id == editor.id and &1.action == "edited"))

    Repo.update!(Ecto.Changeset.change(membership, role: "member"))
    refute Events.can_edit?(published, editor)
    assert {:error, :forbidden} = Events.update_event(editor, published, %{title: "撤权后编辑"})
  end

  test "报名截止已过时仍可只修正文案，不必重设旧时间", ctx do
    event = event!(ctx)
    past = DateTime.add(DateTime.utc_now(), -60)
    Repo.update!(change(event, application_deadline: past))
    assert {:ok, edited} = Events.update_event(ctx.host, event, %{"title" => "修正后的活动"})
    assert edited.title == "修正后的活动"
    assert edited.application_deadline == past

    assert {:ok, corrected} =
             Events.update_event(ctx.host, edited, %{
               "application_deadline" => DateTime.add(past, -60)
             })

    assert corrected.application_deadline == DateTime.add(past, -60)
    assert corrected.status == "open"
  end

  test "已发布活动改到开始时间之后，会在同一事务中退还未入选申请", ctx do
    event = event!(ctx, %{capacity: 2})
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "第一位联系方式"})
    {:ok, event} = Events.apply(ctx.second, event, %{contact: "第二位联系方式"})
    first = application(event, ctx.first)
    second = application(event, ctx.second)
    {:ok, event} = Events.approve_application(ctx.host, event, first.id)
    now = DateTime.utc_now()

    assert {:ok, started} =
             Events.update_event(ctx.host, event, %{
               application_deadline: DateTime.add(now, -30),
               starts_at: DateTime.add(now, -20),
               ends_at: DateTime.add(now, -10)
             })

    assert started.status == "in_progress"
    assert started.round == 1
    assert Repo.get!(Application, first.id).status == "approved"
    assert Repo.get!(Application, first.id).payment_status == "reserved"
    assert Repo.get!(Application, second.id).status == "not_selected"
    assert Repo.get!(Application, second.id).payment_status == "refunded"
    assert balances(ctx.first) == {80, 20}
    assert balances(ctx.second) == {100, 0}
    assert Enum.any?(started.history, &(&1.action == "edited"))
    assert Enum.any?(started.history, &(&1.action == "started"))
    assert Rice.Grains.reconcile().ok?
  end

  test "取消后编辑重开空白新一期，旧申请和费用流水仍归旧期", ctx do
    third = user_fixture()
    Rice.Grains.grant(third, 100)
    event = event!(ctx, %{capacity: 3})
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "第一位联系方式"})
    {:ok, event} = Events.apply(ctx.second, event, %{contact: "第二位联系方式"})
    {:ok, event} = Events.apply(third, event, %{contact: "第三位联系方式"})
    first_old = application(event, ctx.first)
    second_old = application(event, ctx.second)
    third_old = application(event, third)
    {:ok, event} = Events.approve_application(ctx.host, event, first_old.id)
    {:ok, event} = Events.reject_application(ctx.host, event, third_old.id)
    {:ok, cancelled} = Events.cancel(ctx.host, event)
    assert cancelled.round == 1
    assert balances(ctx.first) == {100, 0}
    assert balances(ctx.second) == {100, 0}

    assert {:ok, reopened} =
             Events.update_event(
               ctx.host,
               cancelled,
               attrs(ctx.node, %{fee_amount: 30, capacity: 1})
             )

    assert reopened.status == "open"
    assert reopened.round == 2
    assert length(reopened.applications) == 3
    assert Repo.get!(Application, first_old.id).status == "cancelled"
    assert Repo.get!(Application, second_old.id).status == "cancelled"
    assert Repo.get!(Application, third_old.id).status == "rejected"
    refute Enum.any?(reopened.applications, &(&1.round == 2))
    assert balances(ctx.first) == {100, 0}
    assert balances(ctx.second) == {100, 0}
    assert {:error, :not_found} = Events.approve_application(ctx.host, reopened, first_old.id)

    own = RiceWeb.Api.EventJSON.show(%{event: reopened, current_user: ctx.first}).data
    host = RiceWeb.Api.EventJSON.show(%{event: reopened, current_user: ctx.host}).data
    assert own.application_count == 0
    assert own.approved_count == 0
    assert own.my_application == nil
    assert Enum.map(own.past_applications, & &1.id) == [first_old.id]
    assert host.applications == []
    assert length(host.past_applications) == 3
    assert length(Events.list_events(ctx.first, %{"mine" => "applied"}).entries) == 1

    assert {:ok, reapplied} = Events.apply(ctx.first, reopened, %{contact: "新一期联系方式"})
    new_application = Enum.find(reapplied.applications, &(&1.round == 2))
    assert new_application.id != first_old.id
    assert new_application.fee_amount == 30
    assert balances(ctx.first) == {70, 30}
    assert balances(ctx.second) == {100, 0}
    assert Repo.get!(Application, first_old.id).payment_status == "refunded"
    assert {:ok, _} = Events.cancel(ctx.host, reapplied)
    assert balances(ctx.first) == {100, 0}
    assert Rice.Grains.reconcile().ok?
  end

  test "取消活动后只改文案也开启空白新一期", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "原联系方式"})
    old = application(event, ctx.first)
    {:ok, cancelled} = Events.cancel(ctx.host, event)
    assert DateTime.compare(cancelled.application_deadline, DateTime.utc_now()) == :gt

    {:ok, reopened} = Events.update_event(ctx.host, cancelled, %{title: "新一期活动"})

    assert reopened.status == "open"
    assert reopened.round == 2
    assert Repo.get!(Application, old.id).payment_status == "refunded"
    refute Enum.any?(reopened.applications, &(&1.round == 2))
    assert balances(ctx.first) == {100, 0}
    assert Rice.Grains.reconcile().ok?
  end

  test "取消活动重开时必须有将来的有效日程", ctx do
    event = event!(ctx)
    {:ok, cancelled} = Events.cancel(ctx.host, event)
    age_event!(cancelled)

    assert {:error, %Ecto.Changeset{} = invalid} =
             Events.update_event(ctx.host, cancelled, %{})

    assert Keyword.has_key?(invalid.errors, :application_deadline)
    assert Repo.get!(Event, event.id).round == 1
    refute Repo.exists?(from(h in EventHistory, where: h.event_id == ^event.id and h.round == 2))

    assert {:ok, reopened} = Events.update_event(ctx.host, cancelled, attrs(ctx.node))
    assert reopened.round == 2
    assert reopened.status == "open"
  end

  test "旧活动缺少收款社区时空更新也会重开空白新一期", ctx do
    event = event!(ctx)
    {:ok, cancelled} = Events.cancel(ctx.host, event)
    legacy = Repo.update!(Ecto.Changeset.change(cancelled, settlement_node_id: nil))
    history_count = Repo.aggregate(EventHistory, :count)
    receipt_count = Repo.aggregate(Rice.Grains.Receipt, :count)

    assert {:ok, reopened} = Events.update_event(ctx.host, legacy, %{})
    assert reopened.status == "open"
    assert reopened.round == 2
    assert reopened.settlement_node_id == ctx.node.id
    assert reopened.applications == []
    assert Repo.aggregate(EventHistory, :count) == history_count + 1
    assert Repo.aggregate(Rice.Grains.Receipt, :count) == receipt_count
  end

  test "换社区重开后新社区管理员不能查看旧期私人申请", ctx do
    next_node = node_fixture(%{user_id: ctx.host.id})
    new_manager = user_fixture()

    Repo.insert!(
      Rice.Community.Membership.changeset(%Rice.Community.Membership{
        node_id: next_node.id,
        user_id: new_manager.id,
        role: "admin"
      })
    )

    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "旧期私人联系方式"})
    {:ok, cancelled} = Events.cancel(ctx.host, event)
    {:ok, reopened} = Events.update_event(ctx.host, cancelled, attrs(next_node))

    manager = RiceWeb.Api.EventJSON.show(%{event: reopened, current_user: new_manager}).data
    creator = RiceWeb.Api.EventJSON.show(%{event: reopened, current_user: ctx.host}).data
    applicant = RiceWeb.Api.EventJSON.show(%{event: reopened, current_user: ctx.first}).data

    assert manager.can_manage
    assert manager.past_applications == []
    assert length(creator.past_applications) == 1
    assert hd(applicant.past_applications).contact == "旧期私人联系方式"
  end

  test "已完成活动不可编辑，也不改变旧期申请和收据", ctx do
    event = event!(ctx, %{capacity: 2})
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "第一位联系方式"})
    {:ok, event} = Events.apply(ctx.second, event, %{contact: "第二位联系方式"})
    first_old = application(event, ctx.first)
    second_old = application(event, ctx.second)
    {:ok, event} = Events.approve_application(ctx.host, event, first_old.id)
    {:ok, event} = Events.reject_application(ctx.host, event, second_old.id)
    age_event!(event)
    {:ok, finished} = Events.finish(ctx.host, event)
    assert Repo.get!(Application, first_old.id).payment_status == "settled"
    receipt_count = Repo.aggregate(Rice.Grains.Receipt, :count)
    history_count = Repo.aggregate(EventHistory, :count)

    assert {:error, :conflict} =
             Events.update_event(ctx.host, finished, attrs(ctx.node, %{fee_amount: 5}))

    refute "edit" in Events.allowed_actions(finished, ctx.host)
    persisted = Repo.get!(Event, event.id)
    assert persisted.status == "completed"
    assert persisted.round == 1
    assert persisted.fee_amount == 20
    assert Repo.get!(Application, first_old.id).payment_status == "settled"
    assert Repo.get!(Application, second_old.id).payment_status == "refunded"
    assert Repo.aggregate(from(a in Application, where: a.event_id == ^event.id), :count) == 2
    assert Repo.aggregate(Rice.Grains.Receipt, :count) == receipt_count
    assert Repo.aggregate(EventHistory, :count) == history_count
    assert balances(ctx.first) == {80, 0}
    assert Repo.get!(Rice.Community.Node, ctx.node.id).grain_balance == 20
    assert Rice.Grains.reconcile().ok?
  end

  test "取消活动的新一期名额不受旧期通过人数占用", ctx do
    event = event!(ctx, %{capacity: 2})
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "第一位联系方式"})
    {:ok, event} = Events.apply(ctx.second, event, %{contact: "第二位联系方式"})
    {:ok, event} = Events.approve_application(ctx.host, event, application(event, ctx.first).id)
    {:ok, event} = Events.approve_application(ctx.host, event, application(event, ctx.second).id)
    {:ok, cancelled} = Events.cancel(ctx.host, event)

    assert {:ok, reopened} =
             Events.update_event(ctx.host, cancelled, attrs(ctx.node, %{capacity: 1}))

    assert reopened.round == 2
    assert Repo.aggregate(from(a in Application, where: a.event_id == ^event.id), :count) == 2
    assert balances(ctx.first) == {100, 0}
    assert balances(ctx.second) == {100, 0}
    assert Rice.Grains.reconcile().ok?
  end

  test "收费和免费活动满员后拒绝新申请，释放名额后才恢复", ctx do
    for fee <- [1, 0] do
      event = event!(ctx, %{fee_amount: fee})
      {:ok, applied} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
      first = application(applied, ctx.first)
      {:ok, full} = Events.approve_application(ctx.host, event, first.id)
      refute "apply" in Events.allowed_actions(full, ctx.second)
      before = {Repo.aggregate(EventHistory, :count), Repo.aggregate(Rice.Grains.Receipt, :count)}

      # A stale detail object must not bypass the current capacity check.
      assert {:error, :capacity_full} =
               Events.apply(ctx.second, event, %{contact: "测试联系方式"})

      refute Repo.get_by(Application, event_id: event.id, user_id: ctx.second.id)
      assert balances(ctx.second) == {100, 0}

      assert before ==
               {Repo.aggregate(EventHistory, :count), Repo.aggregate(Rice.Grains.Receipt, :count)}

      assert {:ok, repeat} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
      assert application(repeat, ctx.first).id == first.id
      assert balances(ctx.first) == {100 - fee, fee}
      {:ok, reopened} = Events.remove_application(ctx.host, full, first.id)
      assert "apply" in Events.allowed_actions(reopened, ctx.second)
      assert {:ok, _} = Events.apply(ctx.second, reopened, %{contact: "测试联系方式"})
      assert balances(ctx.second) == {100 - fee, fee}
      assert {:ok, _} = Events.cancel(ctx.host, reopened)
      assert Rice.Grains.reconcile().ok?
    end
  end

  test "余额不足不会产生申请、冻结和进展的半成功记录", ctx do
    user = user_fixture()
    event = event!(ctx)
    before = Repo.aggregate(EventHistory, :count)
    assert {:error, :insufficient_balance} = Events.apply(user, event, %{contact: "测试联系方式"})
    assert Repo.aggregate(Application, :count) == 0
    assert Repo.aggregate(EventHistory, :count) == before
    assert balances(user) == {0, 0}
  end

  test "拒绝和移除分别退款且释放名额，重试不重复退，拒绝后不重报", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    {:ok, event} = Events.apply(ctx.second, event, %{contact: "测试联系方式"})
    a = application(event, ctx.first)
    b = application(event, ctx.second)
    assert {:ok, _} = Events.approve_application(ctx.host, event, a.id)
    assert {:ok, _} = Events.remove_application(ctx.host, event, a.id)
    assert {:ok, _} = Events.remove_application(ctx.host, event, a.id)
    assert balances(ctx.first) == {100, 0}
    assert {:ok, _} = Events.approve_application(ctx.host, event, b.id)
    assert {:ok, _} = Events.cancel(ctx.host, event)
    assert {:ok, _} = Events.cancel(ctx.host, event)
    assert balances(ctx.second) == {100, 0}
    assert {:error, :conflict} = Events.finish(ctx.host, event)
    assert {:ok, revisit} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    assert application(revisit, ctx.first).status == "removed"

    another = event!(ctx)
    {:ok, another} = Events.apply(ctx.first, another, %{contact: "测试联系方式"})
    a = application(another, ctx.first)
    assert {:ok, _} = Events.reject_application(ctx.host, another, a.id)
    assert {:ok, repeat} = Events.apply(ctx.first, another, %{contact: "测试联系方式"})
    assert application(repeat, ctx.first).status == "rejected"
    assert balances(ctx.first) == {100, 0}
    assert Rice.Grains.reconcile().ok?
  end

  test "截止只关闭新申请，开始自动退未入选，结束须主办方确认才结算", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    {:ok, event} = Events.apply(ctx.second, event, %{contact: "测试联系方式"})
    a = application(event, ctx.first)
    b = application(event, ctx.second)

    Repo.update_all(from(e in Event, where: e.id == ^event.id),
      set: [application_deadline: DateTime.add(DateTime.utc_now(), -1)]
    )

    assert {:ok, _} = Events.approve_application(ctx.host, event, a.id)
    assert {:error, :conflict} = Events.apply(user_fixture(), event, %{contact: "测试联系方式"})
    assert {:error, :conflict} = Events.finish(ctx.host, event)
    age_event!(event)
    assert :ok = Events.start_due_events()
    assert :ok = Events.start_due_events()
    assert Repo.get!(Event, event.id).status == "in_progress"
    assert Repo.get!(Application, b.id).status == "not_selected"
    assert balances(ctx.first) == {80, 20}
    assert balances(ctx.second) == {100, 0}
    assert balances(ctx.host) == {0, 0}
    assert {:error, :conflict} = Events.approve_application(ctx.host, event, b.id)
    assert {:ok, finished} = Events.finish(ctx.host, event)
    assert {:ok, _} = Events.finish(ctx.host, event)
    assert finished.status == "completed"
    assert application(finished, ctx.first).payment_status == "settled"
    assert balances(ctx.first) == {80, 0}
    assert balances(ctx.host) == {0, 0}
    assert Repo.get!(Rice.Community.Node, ctx.node.id).grain_balance == 20
    assert {:error, :conflict} = Events.cancel(ctx.host, event)
    assert {:error, :conflict} = Events.remove_application(ctx.host, event, a.id)
    assert Rice.Grains.reconcile().ok?
  end

  test "退款异常回滚整场开始，恢复原冻结后系统原任务可重试", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    {:ok, event} = Events.apply(ctx.second, event, %{contact: "测试联系方式"})
    users = Enum.sort_by([ctx.first, ctx.second], & &1.id)
    [healthy, broken] = users

    Repo.update_all(from(u in Rice.Accounts.User, where: u.id == ^broken.id),
      set: [grain_frozen_balance: 0]
    )

    age_event!(event)
    assert {:error, _} = Events.start_due_events()
    assert Repo.get!(Event, event.id).status == "open"
    assert balances(healthy) == {80, 20}
    assert Enum.all?(Repo.all(Application), &(&1.status == "pending"))
    assert {:error, _} = Events.finish(ctx.host, event)
    assert balances(ctx.host) == {0, 0}

    Repo.update_all(from(u in Rice.Accounts.User, where: u.id == ^broken.id),
      set: [grain_frozen_balance: 20]
    )

    assert :ok = Events.start_due_events()
    assert balances(healthy) == {100, 0}
    assert balances(broken) == {100, 0}
    assert Rice.Grains.reconcile().ok?
  end

  test "免费活动执行相同审批和开始规则，完全不产生资金操作", ctx do
    event = event!(ctx, %{fee_amount: 0})
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    {:ok, event} = Events.apply(ctx.second, event, %{contact: "测试联系方式"})
    a = application(event, ctx.first)
    assert {:ok, _} = Events.approve_application(ctx.host, event, a.id)
    age_event!(event)
    # finish also performs overdue start before settlement, without relying on reads.
    assert {:ok, finished} = Events.finish(ctx.host, event)
    assert application(finished, ctx.first).payment_status == "none"
    assert application(finished, ctx.second).status == "not_selected"
    assert balances(ctx.first) == {100, 0}
    assert balances(ctx.second) == {100, 0}
    assert balances(ctx.host) == {0, 0}

    assert Repo.aggregate(
             from(t in Rice.Grains.Transfer,
               where: like(t.subject_uri, "rice://event_applications/%")
             ),
             :count
           ) == 0
  end

  test "公开详情隐藏候选理由和余额，本人仅见本人申请，主办方见全部", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式", reason: "私人甲"})
    {:ok, event} = Events.apply(ctx.second, event, %{contact: "测试联系方式", reason: "私人乙"})
    public = RiceWeb.Api.EventJSON.show(%{event: event, current_user: nil}).data
    own = RiceWeb.Api.EventJSON.show(%{event: event, current_user: ctx.first}).data
    host = RiceWeb.Api.EventJSON.show(%{event: event, current_user: ctx.host}).data
    assert public.applications == []
    assert public.my_application == nil
    refute inspect(public) =~ "私人"
    refute inspect(public) =~ "grain_balance"
    assert Enum.map(own.applications, & &1.user.id) == [ctx.first.id]
    assert own.my_application.reason == "私人甲"
    assert length(host.applications) == 2
    assert Events.list_events(ctx.first, %{"mine" => "applied"}).entries |> length() == 1
  end

  test "本人可在报名截止后开始前撤销，退回原费用且不能重报或重复退款", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    own = application(event, ctx.first)

    event
    |> Ecto.Changeset.change(application_deadline: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert {:ok, event} = Events.fetch_event(event.id, ctx.first)
    assert Events.application_actions(event, own, ctx.first) == ["withdraw"]
    assert balances(ctx.first) == {80, 20}
    assert {:ok, withdrawn} = Events.withdraw_application(ctx.first, event, own.id)
    assert withdrawn.status == "open"
    assert application(withdrawn, ctx.first).status == "withdrawn"
    assert application(withdrawn, ctx.first).payment_status == "refunded"
    assert balances(ctx.first) == {100, 0}

    assert Events.application_actions(withdrawn, application(withdrawn, ctx.first), ctx.first) ==
             []

    refute "apply" in Events.allowed_actions(withdrawn, ctx.first)

    assert {:ok, _} = Events.withdraw_application(ctx.first, event, own.id)
    assert {:ok, repeated} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    assert application(repeated, ctx.first).id == own.id
    assert application(repeated, ctx.first).status == "withdrawn"
    assert {:error, :conflict} = Events.approve_application(ctx.host, event, own.id)
    assert {:ok, _} = Events.cancel(ctx.host, event)
    assert {:ok, _} = Events.withdraw_application(ctx.first, event, own.id)
    assert balances(ctx.first) == {100, 0}
    uri = "rice://event_applications/#{own.id}"

    assert Repo.aggregate(
             from(r in Rice.Grains.Receipt, where: r.subject_uri == ^uri and r.kind == "refunded"),
             :count
           ) == 1

    assert Repo.aggregate(
             from(h in EventHistory,
               where: h.application_id == ^own.id and h.action == "application_withdrawn"
             ),
             :count
           ) == 1

    assert Repo.aggregate(
             from(n in Rice.Tasks.Notification,
               where: n.subject_id == ^event.id and n.event == "event_application_withdrawn"
             ),
             :count
           ) == 1

    assert Rice.Grains.reconcile().ok?
  end

  test "免费申请撤销不产生冻结或退款凭证", ctx do
    event = event!(ctx, %{fee_amount: 0})
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    own = application(event, ctx.first)
    assert {:ok, withdrawn} = Events.withdraw_application(ctx.first, event, own.id)
    assert application(withdrawn, ctx.first).status == "withdrawn"
    assert application(withdrawn, ctx.first).payment_status == "none"
    assert balances(ctx.first) == {100, 0}
    assert Repo.aggregate(Rice.Grains.Receipt, :count) == 0
  end

  test "只能撤销本人且属于本场的申请，主办者不能代撤销", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    own = application(event, ctx.first)
    other_event = event!(ctx)

    assert {:error, :forbidden} = Events.withdraw_application(ctx.second, event, own.id)
    assert {:error, :forbidden} = Events.withdraw_application(ctx.host, event, own.id)
    assert {:error, :not_found} = Events.withdraw_application(ctx.first, other_event, own.id)
    assert {:error, :not_found} = Events.withdraw_application(ctx.first, event, "invalid")

    assert {:error, :not_found} =
             Events.withdraw_application(ctx.first, event, Rice.Tsid.generate())

    assert Repo.get!(Application, own.id).status == "pending"
    assert balances(ctx.first) == {80, 20}
  end

  test "已通过或其他已结束申请不能自助撤销", ctx do
    for action <- [:approved, :removed, :rejected, :cancelled, :not_selected] do
      event = event!(ctx, %{fee_amount: 0})
      {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
      own = application(event, ctx.first)

      case action do
        :approved ->
          assert {:ok, _} = Events.approve_application(ctx.host, event, own.id)

        :removed ->
          assert {:ok, _} = Events.approve_application(ctx.host, event, own.id)
          assert {:ok, _} = Events.remove_application(ctx.host, event, own.id)

        :rejected ->
          assert {:ok, _} = Events.reject_application(ctx.host, event, own.id)

        :cancelled ->
          assert {:ok, _} = Events.cancel(ctx.host, event)

        :not_selected ->
          assert {:ok, _} = Events.start_event(event.id, event.starts_at)
      end

      assert {:error, :conflict} = Events.withdraw_application(ctx.first, event, own.id)
      assert {:ok, current} = Events.fetch_event(event.id, ctx.first)
      assert application(current, ctx.first).status == Atom.to_string(action)
      assert Events.application_actions(current, application(current, ctx.first), ctx.first) == []
    end
  end

  test "到达开始时间即不能撤销，尚未执行定时任务也不能绕过", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    own = application(event, ctx.first)
    now = DateTime.utc_now()

    event
    |> Ecto.Changeset.change(application_deadline: DateTime.add(now, -1), starts_at: now)
    |> Repo.update!()

    assert {:error, :conflict} = Events.withdraw_application(ctx.first, event, own.id)
    assert {:ok, current} = Events.fetch_event(event.id, ctx.first)
    assert current.status == "open"
    assert application(current, ctx.first).status == "pending"
    assert Events.application_actions(current, application(current, ctx.first), ctx.first) == []
    assert balances(ctx.first) == {80, 20}

    assert {:ok, _} = Events.start_event(event.id)
    assert Repo.get!(Application, own.id).status == "not_selected"
    assert balances(ctx.first) == {100, 0}
  end

  test "撤销退款失败时不写半成功状态或历史", ctx do
    event = event!(ctx)
    {:ok, event} = Events.apply(ctx.first, event, %{contact: "测试联系方式"})
    own = application(event, ctx.first)
    uri = "rice://event_applications/#{own.id}"
    Repo.delete_all(from(r in Rice.Grains.Receipt, where: r.subject_uri == ^uri))

    assert {:error, :grain_reservation_missing} =
             Events.withdraw_application(ctx.first, event, own.id)

    assert Repo.get!(Application, own.id).status == "pending"
    assert Repo.get!(Application, own.id).payment_status == "reserved"
    assert balances(ctx.first) == {80, 20}

    refute Repo.exists?(
             from(h in EventHistory,
               where: h.application_id == ^own.id and h.action == "application_withdrawn"
             )
           )
  end

  defp attrs(node, extra \\ %{}) do
    now = DateTime.utc_now()

    Map.merge(
      %{
        organizer_contact: "社区服务台",
        node_id: node.id,
        client_request_id: "event-#{System.unique_integer([:positive])}",
        title: "社区活动",
        description: "一起整理公共空间",
        location: "公共客厅",
        fee_amount: 20,
        capacity: 1,
        application_deadline: DateTime.add(now, 1800),
        starts_at: DateTime.add(now, 3600),
        ends_at: DateTime.add(now, 7200)
      },
      extra
    )
  end

  defp event!(ctx, extra \\ %{}) do
    {:ok, event} = Events.create_event(ctx.host, attrs(ctx.node, extra))
    event
  end

  defp application(event, user), do: Enum.find(event.applications, &(&1.user_id == user.id))

  defp balances(user) do
    current = Repo.get!(Rice.Accounts.User, user.id)
    {current.grain_balance, current.grain_frozen_balance}
  end

  defp age_event!(event) do
    now = DateTime.utc_now()

    Repo.update_all(from(e in Event, where: e.id == ^event.id),
      set: [
        application_deadline: DateTime.add(now, -30),
        starts_at: DateTime.add(now, -20),
        ends_at: DateTime.add(now, -10)
      ]
    )
  end
end

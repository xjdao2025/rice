defmodule RiceWeb.Api.GrainFlowTest do
  @moduledoc """
  稻米从增发到各种流转的全链路,全部走 HTTP。

  钱只有一个来源(后台发放),之后在个人、节点、任务和活动之间流转;每一步都看
  接口返回的钱包和库里的余额,最后对账:全站可用 + 冻结 == 发放总额。
  """
  use RiceWeb.ConnCase, async: true

  import Ecto.Query

  alias Rice.Accounts.{User, VerificationCode}
  alias Rice.Community.Node
  alias Rice.Grains.{Receipt, Transfer}
  alias Rice.Repo

  defp balances(%User{id: id}) do
    %{grain_balance: b, grain_frozen_balance: f} = Repo.get!(User, id)
    {b, f}
  end

  defp balances(%Node{id: id}) do
    %{grain_balance: b, grain_frozen_balance: f} = Repo.get!(Node, id)
    {b, f}
  end

  defp admin_with_code do
    {admin, token} = admin_with_token()

    issue = fn ->
      code = VerificationCode.generate_code()

      Repo.insert!(
        VerificationCode.build(
          "sms",
          Rice.Accounts.phone_target(admin.phone_region, admin.phone),
          "admin_grant",
          code
        )
      )

      code
    end

    {admin, token, issue}
  end

  defp wallet(token),
    do:
      build_conn()
      |> authed(token)
      |> get(~p"/api/wallet")
      |> json_response(200)
      |> Map.fetch!("data")

  defp node_wallet(token, node_id) do
    build_conn()
    |> authed(token)
    |> get(~p"/api/nodes/#{node_id}/wallet")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp transfer(token, body),
    do: build_conn() |> authed(token) |> post(~p"/api/grain_transfers", body)

  test "增发 → 转账 / 打赏 → 节点注资 → 任务奖励 → 活动报名费,每一步余额都对得上账" do
    {_admin, admin_token, issue_code} = admin_with_code()
    {manager, manager_token} = user_with_token(%{nickname: "节点主"})
    manager = manager |> Ecto.Changeset.change(can_publish_tasks: true) |> Repo.update!()
    node = node_fixture(%{user_id: manager.id})
    {alice, alice_token} = user_with_token(%{nickname: "阿青"})
    {bob, bob_token} = user_with_token(%{nickname: "小林"})

    # ── 1. 后台发放:个人按 handle / did,节点按 id ─────────────────────
    assert %{"data" => %{"granted" => 2}} =
             build_conn()
             |> authed(admin_token)
             |> post(~p"/api/admin/grain_grants", %{
               to: [alice.handle, manager.did],
               amount: 200,
               memo: "启动",
               code: issue_code.()
             })
             |> json_response(201)

    # 验证码一次性:同一个码再发一次不行,钱不动
    assert %{"errors" => %{"code" => _}} =
             build_conn()
             |> authed(admin_token)
             |> post(~p"/api/admin/grain_grants", %{to: [bob.handle], amount: 999, code: "000000"})
             |> json_response(422)

    assert balances(alice) == {200, 0}
    assert balances(manager) == {200, 0}
    assert balances(bob) == {0, 0}

    node_grant = %{amount: 100, client_request_id: "node-seed", memo: "节点启动", code: issue_code.()}

    assert %{"data" => %{"replayed" => false, "amount" => 100}} =
             build_conn()
             |> authed(admin_token)
             |> post(~p"/api/admin/nodes/#{node.id}/grain_grants", node_grant)
             |> json_response(201)

    # 同一请求标识重试:返回原流水,不验码、不加钱;改了金额则冲突
    assert %{"data" => %{"replayed" => true}} =
             build_conn()
             |> authed(admin_token)
             |> post(~p"/api/admin/nodes/#{node.id}/grain_grants", %{node_grant | code: "wrong"})
             |> json_response(200)

    assert build_conn()
           |> authed(admin_token)
           |> post(~p"/api/admin/nodes/#{node.id}/grain_grants", %{node_grant | amount: 50})
           |> json_response(409)

    assert balances(node) == {100, 0}

    # 发放记录公开,总量 = 200 + 200 + 100
    grants = build_conn() |> get(~p"/api/grain_grants") |> json_response(200)
    assert grants["meta"]["total_granted"] == 500
    assert length(grants["data"]) == 3
    assert Enum.any?(grants["data"], &(&1["to_node"] && &1["to_node"]["id"] == node.id))

    # ── 2. 个人之间:赠送、打赏、各种拒绝 ─────────────────────────────
    gift = transfer(alice_token, %{to: bob.did, amount: 50, memo: "请你喝茶"}) |> json_response(201)
    assert gift["data"]["kind"] == "gift"
    assert gift["data"]["direction"] == "out"

    reward =
      transfer(alice_token, %{
        to: bob.handle,
        amount: "20",
        kind: "reward",
        subject_uri: "at://#{bob.did}/app.bsky.feed.post/abc123"
      })
      |> json_response(201)

    assert reward["data"]["kind"] == "reward"

    # 打赏的帖子必须是收款人自己的
    assert %{"errors" => %{"subject_uri" => _}} =
             transfer(alice_token, %{
               to: bob.did,
               amount: 5,
               kind: "reward",
               subject_uri: "at://#{alice.did}/app.bsky.feed.post/abc123"
             })
             |> json_response(422)

    assert %{"errors" => %{"to" => _}} =
             transfer(alice_token, %{to: alice.did, amount: 5}) |> json_response(422)

    assert %{"errors" => %{"amount" => _}} =
             transfer(bob_token, %{to: alice.did, amount: 71}) |> json_response(422)

    assert transfer(bob_token, %{to: alice.did, amount: 0}) |> json_response(422)
    assert transfer(bob_token, %{to: alice.did, amount: "1.5"}) |> json_response(422)
    # 客户端把 kind 写成 grant 也只是赠送,凭空造不出稻米
    assert %{"data" => %{"kind" => "gift"}} =
             transfer(bob_token, %{to: alice.did, amount: 10, kind: "grant"})
             |> json_response(201)

    assert balances(alice) == {140, 0}
    assert balances(bob) == {60, 0}
    assert Rice.Grains.total_granted() == 500

    bob_view =
      build_conn() |> authed(bob_token) |> get(~p"/api/grain_transfers") |> json_response(200)

    assert Enum.map(bob_view["data"], &{&1["kind"], &1["direction"], &1["amount"]}) ==
             [{"gift", "out", 10}, {"reward", "in", 20}, {"gift", "in", 50}]

    assert wallet(bob_token)["balance"] == 60
    assert wallet(bob_token)["earned"] == 70

    # ── 3. 节点主把个人稻米转入节点 ────────────────────────────────────
    fund = %{amount: 120, client_request_id: "fund-1"}

    assert build_conn()
           |> authed(alice_token)
           |> post(~p"/api/nodes/#{node.id}/fund", fund)
           |> json_response(403)

    funded =
      build_conn()
      |> authed(manager_token)
      |> post(~p"/api/nodes/#{node.id}/fund", fund)
      |> json_response(200)

    assert funded["data"]["balance"] == 220
    # 重试同一请求不重复扣
    assert build_conn()
           |> authed(manager_token)
           |> post(~p"/api/nodes/#{node.id}/fund", fund)
           |> json_response(200)

    assert build_conn()
           |> authed(manager_token)
           |> post(~p"/api/nodes/#{node.id}/fund", %{fund | amount: 1})
           |> json_response(409)

    assert balances(manager) == {80, 0}
    assert balances(node) == {220, 0}

    # 节点钱包只有节点管理员能看
    assert build_conn()
           |> authed(alice_token)
           |> get(~p"/api/nodes/#{node.id}/wallet")
           |> json_response(403)

    # ── 4. 任务奖励:从节点账户冻结,验收后发给承作人 ────────────────
    created =
      build_conn()
      |> authed(manager_token)
      |> post(~p"/api/tasks", %{
        client_request_id: "grain-task",
        title: "修篱笆",
        description: "修好",
        organizer_contact: "服务台",
        reward_amount: 150
      })
      |> json_response(201)

    task_id = created["data"]["id"]
    assert balances(node) == {70, 150}
    assert node_wallet(manager_token, node.id)["frozen"] == 150

    # 节点余额不够再发一个
    assert %{"errors" => %{"amount" => _}} =
             build_conn()
             |> authed(manager_token)
             |> post(~p"/api/tasks", %{
               client_request_id: "grain-task-2",
               title: "太贵",
               description: "x",
               organizer_contact: "服务台",
               reward_amount: 71
             })
             |> json_response(422)

    assert build_conn()
           |> authed(bob_token)
           |> post(~p"/api/tasks/#{task_id}/applications", %{contact: "微信"})
           |> json_response(201)

    app_id =
      build_conn()
      |> authed(manager_token)
      |> get(~p"/api/tasks/#{task_id}")
      |> json_response(200)
      |> get_in(["data", "applications"])
      |> hd()
      |> Map.fetch!("id")

    assert build_conn()
           |> authed(manager_token)
           |> post(~p"/api/tasks/#{task_id}/applications/#{app_id}/appoint")
           |> json_response(200)

    assert build_conn()
           |> authed(bob_token)
           |> post(~p"/api/tasks/#{task_id}/submissions", %{body: "修好了"})
           |> json_response(201)

    submission_id =
      build_conn()
      |> authed(manager_token)
      |> get(~p"/api/tasks/#{task_id}")
      |> json_response(200)
      |> get_in(["data", "submissions"])
      |> hd()
      |> Map.fetch!("id")

    approved =
      build_conn()
      |> authed(manager_token)
      |> post(~p"/api/tasks/#{task_id}/submissions/#{submission_id}/approve")
      |> json_response(200)

    assert approved["data"]["reward_status"] == "settled"
    assert balances(bob) == {210, 0}
    assert balances(node) == {70, 0}
    # 任务已完成,再点一次验收是冲突,不会重复发
    assert build_conn()
           |> authed(manager_token)
           |> post(~p"/api/tasks/#{task_id}/submissions/#{submission_id}/approve")
           |> json_response(409)

    assert balances(bob) == {210, 0}

    assert [%{kind: "reserved"}, %{kind: "settled"}] =
             Repo.all(
               from r in Receipt,
                 where: r.subject_uri == ^"rice://tasks/#{task_id}",
                 order_by: r.id,
                 select: %{kind: r.kind}
             )

    # 结算在节点钱包里是一笔 task_reward 转账(付给小林),冻结凭证仍留作证据
    node_entries = node_wallet(manager_token, node.id)["entries"]

    assert Enum.any?(
             node_entries,
             &(&1["kind"] == "task_reward" and &1["amount"] == 150 and
                 &1["to_user"]["id"] == bob.id)
           )

    assert Enum.any?(node_entries, &(&1["kind"] == "reserved" and &1["amount"] == 150))
    assert Enum.any?(node_entries, &(&1["kind"] == "community_fund" and &1["amount"] == 120))
    assert Enum.any?(node_entries, &(&1["kind"] == "grant" and &1["amount"] == 100))
    # 小林的明细里是一笔来自节点的收入
    bob_entries = wallet(bob_token)["entries"]

    assert Enum.any?(
             bob_entries,
             &(&1["kind"] == "task_reward" and &1["from_node"]["id"] == node.id)
           )

    # ── 5. 活动报名费:报名时从个人冻结,结束后结算给节点,撤销退回 ──
    now = DateTime.utc_now()

    event =
      build_conn()
      |> authed(manager_token)
      |> post(~p"/api/events", %{
        organizer_contact: "服务台",
        node_id: node.id,
        title: "周末修路",
        description: "一起",
        location: "村口",
        fee_amount: 30,
        capacity: 2,
        client_request_id: "grain-event",
        application_deadline: DateTime.add(now, 1800),
        starts_at: DateTime.add(now, 3600),
        ends_at: DateTime.add(now, 7200)
      })
      |> json_response(201)

    event_id = event["data"]["id"]

    alice_app =
      build_conn()
      |> authed(alice_token)
      |> post(~p"/api/events/#{event_id}/applications", %{contact: "微信"})
      |> json_response(200)
      |> get_in(["data", "my_application", "id"])

    bob_app =
      build_conn()
      |> authed(bob_token)
      |> post(~p"/api/events/#{event_id}/applications", %{contact: "微信"})
      |> json_response(200)
      |> get_in(["data", "my_application", "id"])

    assert balances(alice) == {110, 30}
    assert balances(bob) == {180, 30}
    # 没钱的人报不了名,也不留申请
    {poor, poor_token} = user_with_token()

    assert build_conn()
           |> authed(poor_token)
           |> post(~p"/api/events/#{event_id}/applications", %{contact: "微信"})
           |> json_response(422)

    refute Repo.get_by(Rice.Events.Application, event_id: event_id, user_id: poor.id)

    assert build_conn()
           |> authed(manager_token)
           |> post(~p"/api/events/#{event_id}/applications/#{alice_app}/approve")
           |> json_response(200)

    # 小林在开始前自己撤销:退回冻结;主办方不能替他撤
    assert build_conn()
           |> authed(manager_token)
           |> post(~p"/api/events/#{event_id}/applications/#{bob_app}/withdraw")
           |> json_response(403)

    assert build_conn()
           |> authed(bob_token)
           |> post(~p"/api/events/#{event_id}/applications/#{bob_app}/withdraw")
           |> json_response(200)

    assert balances(bob) == {210, 0}

    # 时间到了,主办方结束活动:阿青的报名费结算到节点
    Repo.update_all(from(e in Rice.Events.Event, where: e.id == ^event_id),
      set: [
        application_deadline: DateTime.add(now, -3),
        starts_at: DateTime.add(now, -2),
        ends_at: DateTime.add(now, -1)
      ]
    )

    finished =
      build_conn()
      |> authed(manager_token)
      |> post(~p"/api/events/#{event_id}/finish")
      |> json_response(200)

    assert finished["data"]["status"] == "completed"
    assert balances(alice) == {110, 0}
    assert balances(node) == {100, 0}

    # ── 6. 对账:发放 500 = 阿青 110 + 小林 210 + 节点主 80 + 节点 100 ────
    assert %{ok?: true, granted: 500, balances: 500, frozen: 0} = Rice.Grains.reconcile()
    assert Repo.aggregate(from(t in Transfer, where: t.kind == "grant"), :count) == 3
  end
end

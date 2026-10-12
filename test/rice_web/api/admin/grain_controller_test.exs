defmodule RiceWeb.Api.Admin.GrainControllerTest do
  use RiceWeb.ConnCase, async: true

  import Mox
  setup :verify_on_exit!

  alias Rice.Accounts.VerificationCode

  setup do
    {admin, token} = admin_with_token()
    %{admin: admin, token: token, code: grant_code(admin)}
  end

  # 发放动的是钱,要管理员自己手机上的验证码 —— core 也是这个要求
  defp grant_code(admin) do
    code = VerificationCode.generate_code()

    Rice.Repo.insert!(
      VerificationCode.build(
        "sms",
        Rice.Accounts.phone_target(admin.phone_region, admin.phone),
        "admin_grant",
        code
      )
    )

    code
  end

  test "运营发不了稻米,连验证码都要不到", %{conn: conn} do
    {_op, op_token} = admin_with_token(%{role: "operator"})
    user = user_fixture()

    assert conn
           |> authed(op_token)
           |> post(~p"/api/admin/grain_grants/challenge")
           |> response(403)

    assert build_conn()
           |> authed(op_token)
           |> post(~p"/api/admin/grain_grants", %{to: [user.id], amount: 100, code: "000000"})
           |> response(403)

    assert Rice.Repo.reload!(user).grain_balance == 0
  end

  describe "节点增发" do
    test "批量入节点钱包，重复节点只增发一次且可重试", %{conn: conn, token: token, code: code} do
      owner = user_fixture()
      a = node_fixture(%{user_id: owner.id})
      b = node_fixture()

      attrs = %{
        node_ids: [a.id, b.id, a.id],
        amount: 10,
        code: code,
        client_request_id: "batch-1"
      }

      assert %{"data" => %{"granted" => 2, "replayed" => false}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", attrs)
               |> json_response(201)

      assert %{"data" => %{"granted" => 2, "replayed" => true}} =
               build_conn()
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", Map.delete(attrs, :code))
               |> json_response(200)

      assert Rice.Repo.reload!(a).grain_balance == 10
      assert Rice.Repo.reload!(b).grain_balance == 10
      assert Rice.Repo.reload!(owner).grain_balance == 0
      assert Rice.Grains.reconcile().ok?

      for changed <- [%{amount: 11}, %{node_ids: [a.id]}, %{memo: "变更"}] do
        assert build_conn()
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", Map.merge(attrs, changed))
               |> json_response(409)
      end
    end

    test "拒绝旧个人增发请求", %{conn: conn, token: token, code: code} do
      user = user_fixture()

      assert %{"errors" => %{"to" => [_]}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{to: [user.id], amount: 10, code: code})
               |> json_response(422)

      assert Rice.Repo.reload!(user).grain_balance == 0
    end

    test "不存在的节点导致整批失败且不消耗验证码", %{conn: conn, token: token, code: code} do
      node = node_fixture()

      attrs = %{
        node_ids: [node.id, Rice.Tsid.generate()],
        amount: 10,
        code: code,
        client_request_id: "batch-2"
      }

      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", attrs)
             |> json_response(404)

      assert Rice.Repo.reload!(node).grain_balance == 0

      assert build_conn()
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", %{attrs | node_ids: [node.id]})
             |> json_response(201)
    end

    test "金额、节点列表与请求标识必须有效", %{conn: conn, token: token, code: code} do
      node = node_fixture()
      attrs = %{node_ids: [node.id], amount: 10, code: code, client_request_id: "batch-3"}
      invalid = for amount <- [0, -1, "abc", nil, 1.5], do: %{amount: amount}
      invalid = invalid ++ for ids <- [[], [nil], [123], ["bad"], "bad"], do: %{node_ids: ids}

      for changed <- invalid ++ [%{client_request_id: nil}, %{memo: String.duplicate("x", 257)}] do
        assert conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", Map.merge(attrs, changed))
               |> json_response(422)
      end

      assert Rice.Repo.reload!(node).grain_balance == 0

      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", attrs)
             |> json_response(201)
    end

    test "批量溢出不部分入账", %{conn: conn, token: token, code: code} do
      a = node_fixture()
      b = node_fixture()
      Rice.Repo.update!(Ecto.Changeset.change(b, grain_balance: 9_223_372_036_854_775_807))

      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", %{
               node_ids: [a.id, b.id],
               amount: 10,
               code: code,
               client_request_id: "overflow"
             })
             |> json_response(422)

      assert Rice.Repo.reload!(a).grain_balance == 0
    end
  end

  # 令牌可能被人从浏览器里捞走,短信在管理员自己手上。发钱要两样都有。
  describe "发放的二次验证" do
    test "没有验证码发不出去", %{conn: conn, token: token} do
      user = node_fixture()

      assert %{"errors" => %{"code" => [_]}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{
                 node_ids: [user.id],
                 client_request_id: user.id,
                 amount: 10
               })
               |> json_response(422)

      assert Rice.Repo.get!(Rice.Community.Node, user.id).grain_balance == 0
    end

    test "验证码不对发不出去", %{conn: conn, token: token} do
      user = node_fixture()

      assert %{"errors" => %{"code" => [_]}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{
                 node_ids: [user.id],
                 client_request_id: user.id,
                 amount: 10,
                 code: "000000"
               })
               |> json_response(422)

      assert Rice.Repo.get!(Rice.Community.Node, user.id).grain_balance == 0
    end

    # 码是发到某个管理员手机上的,不是一张全局通行证
    test "别的管理员手机上的码用不了", %{conn: conn, token: token} do
      other = admin_fixture()
      other_code = grant_code(other)
      user = node_fixture()

      assert %{"errors" => %{"code" => [_]}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{
                 node_ids: [user.id],
                 client_request_id: user.id,
                 amount: 10,
                 code: other_code
               })
               |> json_response(422)

      assert Rice.Repo.get!(Rice.Community.Node, user.id).grain_balance == 0
    end

    test "同一个码用不了第二次", %{conn: conn, token: token, code: code} do
      a = node_fixture()
      b = node_fixture()

      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", %{
               node_ids: [a.id],
               client_request_id: a.id,
               amount: 10,
               code: code
             })
             |> json_response(201)

      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", %{
               node_ids: [b.id],
               client_request_id: b.id,
               amount: 10,
               code: code
             })
             |> json_response(422)

      assert Rice.Repo.get!(Rice.Community.Node, b.id).grain_balance == 0
    end

    # 粘一列几百个手机号,一个笔误不该把码烧掉 —— 重发要等 60 秒
    test "参数校验失败不消耗验证码", %{conn: conn, token: token, code: code} do
      user = node_fixture()

      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", %{
               node_ids: [user.id, "bad"],
               client_request_id: user.id,
               amount: 10,
               code: code
             })
             |> json_response(422)

      # 同一个码,把笔误改掉之后还能用
      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", %{
               node_ids: [user.id],
               client_request_id: user.id,
               amount: 10,
               code: code
             })
             |> json_response(201)

      assert Rice.Repo.get!(Rice.Community.Node, user.id).grain_balance == 10
    end

    # 用一个新管理员 —— setup 里给默认管理员塞过码了,60 秒内再发是 429
    test "发码", %{conn: conn} do
      {_admin, fresh_token} = admin_with_token()
      expect(Rice.NotificationsMock, :send_sms, fn "86", _phone, _text -> :ok end)

      assert conn
             |> authed(fresh_token)
             |> post(~p"/api/admin/grain_grants/challenge")
             |> response(202)
    end

    # core 完全没有这层,同一个号可以被无限次轰炸
    test "60 秒内重复发码是 429", %{conn: conn, token: token} do
      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants/challenge")
             |> json_response(429)
    end

    test "未认证发不了码", %{conn: conn} do
      assert conn |> post(~p"/api/admin/grain_grants/challenge") |> json_response(401)
    end
  end

  describe "记录" do
    test "发放记录带收款人的联系方式", %{conn: conn, token: token} do
      user = user_fixture(%{nickname: "王五", email: "wangwu@example.com"})
      {:ok, _} = Rice.Grains.grant(user, 30)

      assert %{"data" => [one]} =
               conn |> authed(token) |> get(~p"/api/admin/grain_grants") |> json_response(200)

      assert one["amount"] == 30
      assert one["to"]["nickname"] == "王五"
      assert one["to"]["email"] == "wangwu@example.com"
    end

    test "按收款人筛", %{conn: conn, token: token} do
      wang = user_fixture(%{nickname: "王五"})
      li = user_fixture(%{nickname: "李四"})
      {:ok, _} = Rice.Grains.grant(wang, 10)
      {:ok, _} = Rice.Grains.grant(li, 20)

      assert %{"data" => [one]} =
               conn |> authed(token) |> get(~p"/api/admin/grain_grants?q=王") |> json_response(200)

      assert one["to"]["nickname"] == "王五"
    end

    # 手滑的日期不该让整个列表 500
    test "时间参数解析不了就当没传", %{conn: conn, token: token} do
      {:ok, _} = Rice.Grains.grant(user_fixture(), 10)

      assert %{"data" => [_]} =
               conn
               |> authed(token)
               |> get(~p"/api/admin/grain_grants?since=不是时间")
               |> json_response(200)
    end

    test "某人的明细,方向按那个人算而不是按管理员", %{conn: conn, token: token} do
      payer = user_fixture()
      payee = user_fixture()
      {:ok, _} = Rice.Grains.grant(payer, 100)
      {:ok, _} = Rice.Grains.transfer(payer, payee.did, 30)

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> get(~p"/api/admin/users/#{payer.id}/grain_transfers")
               |> json_response(200)

      by_kind = Map.new(data, &{&1["kind"], &1["direction"]})
      assert by_kind["grant"] == "in"
      assert by_kind["gift"] == "out"
    end
  end

  test "未认证 401", %{conn: conn} do
    assert conn |> get(~p"/api/admin/grain_grants") |> json_response(401)

    assert build_conn()
           |> post(~p"/api/admin/grain_grants", %{to: ["x"], amount: 1, code: "000000"})
           |> json_response(401)
  end
end

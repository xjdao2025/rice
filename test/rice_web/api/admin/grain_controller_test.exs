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

  describe "发放" do
    test "收款人可以用邮箱 / handle / DID / id", %{conn: conn, token: token, code: code} do
      a = user_fixture(%{email: "a@example.com"})
      b = user_fixture(%{handle: "bb.web5.xjdao.test"})
      c = user_fixture()

      assert %{"data" => %{"granted" => 3}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{
                 to: ["a@example.com", "bb.web5.xjdao.test", c.did],
                 amount: 10,
                 code: code
               })
               |> json_response(201)

      for user <- [a, b, c] do
        assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 10
      end
    end

    # core 也是全有或全无,但它是在拿到分布式锁之后才发现数量对不上
    test "有一个收款人认不出来,整批都不发", %{conn: conn, token: token, code: code} do
      user = user_fixture(%{phone: "13800003333", phone_region: "86"})

      assert %{"errors" => %{"to" => [message]}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{
                 to: ["13800003333", "查无此人@example.com"],
                 amount: 50,
                 code: code
               })
               |> json_response(422)

      assert message =~ "查无此人@example.com"
      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 0
    end

    test "重复的收款人只发一次", %{conn: conn, token: token, code: code} do
      user = user_fixture(%{phone: "13800004444", phone_region: "86"})

      assert %{"data" => %{"granted" => 1}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{
                 to: ["13800004444", "13800004444", user.did],
                 amount: 25,
                 code: code
               })
               |> json_response(201)

      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 25
    end

    test "金额非法 422", %{conn: conn, token: token, code: code} do
      user = user_fixture()

      for amount <- [0, -1, "abc", nil, 1.5] do
        assert conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{to: [user.did], amount: amount, code: code})
               |> json_response(422)
      end

      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 0
    end

    test "收款人为空 422", %{conn: conn, token: token, code: code} do
      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", %{to: [], amount: 10, code: code})
             |> json_response(422)
    end

    # `to` 是 JSON 数组,里面塞什么都能过 HTTP 那一层。
    # 直接 String.trim/1 会抛,表现是 500 —— 客户端发错格式不该是服务端的错。
    test "收款人不是字符串时 422 而不是 500", %{conn: conn, token: token, code: code} do
      user = user_fixture()

      for bad <- [[nil], [123], [%{"phone" => "13800000000"}], [["嵌套"]], [user.did, nil]] do
        assert %{"errors" => %{"to" => [_]}} =
                 conn
                 |> authed(token)
                 |> post(~p"/api/admin/grain_grants", %{to: bad, amount: 10, code: code})
                 |> json_response(422)
      end

      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 0
    end

    # 从表格里粘一列手机号,末尾常带几个空行
    test "空白的收款人直接丢掉,不算作认不出来", %{conn: conn, token: token, code: code} do
      user = user_fixture(%{phone: "13800006666", phone_region: "86"})

      assert %{"data" => %{"granted" => 1}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{
                 to: ["13800006666", "", "  "],
                 amount: 15,
                 code: code
               })
               |> json_response(201)

      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 15
    end

    # 按手机号找和按 DID 找必须是同一个结果。原先联系方式那条路排除了停用的,
    # id/DID/handle 那条路没排除 —— 同一个人换个写法就发得出去了。
    test "停用的用户收不到,五种写法都收不到", %{conn: conn, token: token, code: code} do
      user =
        user_fixture(%{
          phone: "13800005555",
          phone_region: "86",
          email: "disabled@example.com",
          handle: "disabled.web5.xjdao.test"
        })

      Rice.Repo.update!(Ecto.Changeset.change(user, disabled_at: DateTime.utc_now()))

      for identifier <- [
            "13800005555",
            "disabled@example.com",
            "disabled.web5.xjdao.test",
            user.did,
            user.id
          ] do
        assert conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{
                 to: [identifier],
                 amount: 10,
                 code: code
               })
               |> json_response(422),
               "#{identifier} 不该发得出去"
      end

      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 0
    end
  end

  # 令牌可能被人从浏览器里捞走,短信在管理员自己手上。发钱要两样都有。
  describe "发放的二次验证" do
    test "没有验证码发不出去", %{conn: conn, token: token} do
      user = user_fixture()

      assert %{"errors" => %{"code" => [_]}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{to: [user.did], amount: 10})
               |> json_response(422)

      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 0
    end

    test "验证码不对发不出去", %{conn: conn, token: token} do
      user = user_fixture()

      assert %{"errors" => %{"code" => [_]}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{
                 to: [user.did],
                 amount: 10,
                 code: "000000"
               })
               |> json_response(422)

      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 0
    end

    # 码是发到某个管理员手机上的,不是一张全局通行证
    test "别的管理员手机上的码用不了", %{conn: conn, token: token} do
      other = admin_fixture()
      other_code = grant_code(other)
      user = user_fixture()

      assert %{"errors" => %{"code" => [_]}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/grain_grants", %{
                 to: [user.did],
                 amount: 10,
                 code: other_code
               })
               |> json_response(422)

      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 0
    end

    test "同一个码用不了第二次", %{conn: conn, token: token, code: code} do
      a = user_fixture()
      b = user_fixture()

      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", %{to: [a.did], amount: 10, code: code})
             |> json_response(201)

      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", %{to: [b.did], amount: 10, code: code})
             |> json_response(422)

      assert Rice.Repo.get!(Rice.Accounts.User, b.id).grain_balance == 0
    end

    # 粘一列几百个手机号,一个笔误不该把码烧掉 —— 重发要等 60 秒
    test "参数校验失败不消耗验证码", %{conn: conn, token: token, code: code} do
      user = user_fixture(%{phone: "13800009999", phone_region: "86"})

      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", %{
               to: ["13800009999", "打错了@example.com"],
               amount: 10,
               code: code
             })
             |> json_response(422)

      # 同一个码,把笔误改掉之后还能用
      assert conn
             |> authed(token)
             |> post(~p"/api/admin/grain_grants", %{
               to: ["13800009999"],
               amount: 10,
               code: code
             })
             |> json_response(201)

      assert Rice.Repo.get!(Rice.Accounts.User, user.id).grain_balance == 10
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

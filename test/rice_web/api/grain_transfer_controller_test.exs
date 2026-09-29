defmodule RiceWeb.Api.GrainTransferControllerTest do
  use RiceWeb.ConnCase, async: true

  describe "POST /api/grain_transfers/recipient" do
    test "手机号预览只返回公开资料，核对后用 id 转账", %{conn: conn} do
      {sender, token} = user_with_token()
      {:ok, _} = Rice.Grains.grant(sender, 100)
      avatar = attachment_fixture()

      recipient =
        user_fixture(%{phone: "13800001234", email: "private@example.com", nickname: "收款人"})
        |> Ecto.Changeset.change(avatar_id: avatar.id)
        |> Rice.Repo.update!()

      count = Rice.Repo.aggregate(Rice.Grains.Transfer, :count)

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> post(~p"/api/grain_transfers/recipient", %{to: " 13800001234 "})
               |> json_response(200)

      assert data["id"] == recipient.id
      assert data["avatar"]["id"] == avatar.id
      assert Map.keys(data) |> Enum.sort() == ~w(avatar bio did handle id nickname node_member)
      assert Rice.Repo.get!(Rice.Accounts.User, sender.id).grain_balance == 100
      assert Rice.Repo.get!(Rice.Accounts.User, recipient.id).grain_balance == 0
      assert Rice.Repo.aggregate(Rice.Grains.Transfer, :count) == count

      assert %{"data" => %{"to" => %{"id" => id}}} =
               build_conn()
               |> authed(token)
               |> post(~p"/api/grain_transfers", %{to: data["id"], amount: 7})
               |> json_response(201)

      assert id == recipient.id
      assert Rice.Repo.get!(Rice.Accounts.User, sender.id).grain_balance == 93
      assert Rice.Repo.get!(Rice.Accounts.User, recipient.id).grain_balance == 7
      assert Rice.Repo.aggregate(Rice.Grains.Transfer, :count) == count + 1
      assert Rice.Grains.reconcile().ok?
    end

    test "未登录不能查手机号，匿名公开资料仍不识别手机号", %{conn: conn} do
      user_fixture(%{phone: "13800001234"})

      assert conn
             |> post(~p"/api/grain_transfers/recipient", %{to: "13800001234"})
             |> json_response(401)

      assert build_conn() |> get(~p"/api/users/13800001234/profile") |> json_response(404)
    end

    test "不存在、非法、禁用或已注销的收款人不产生流水", %{conn: conn} do
      {_sender, token} = user_with_token()

      for field <- [:disabled_at, :deleted_at] do
        user_fixture(%{phone: if(field == :disabled_at, do: "13800000001", else: "13800000002")})
        |> Ecto.Changeset.change(%{field => DateTime.utc_now()})
        |> Rice.Repo.update!()
      end

      for params <- [
            %{},
            %{to: ["13800001234"]},
            %{to: "13800001234"},
            %{to: "+8613800001234"},
            %{to: "13800000001"},
            %{to: "13800000002"}
          ] do
        assert conn
               |> authed(token)
               |> post(~p"/api/grain_transfers/recipient", params)
               |> json_response(422)
      end

      assert Rice.Repo.aggregate(Rice.Grains.Transfer, :count) == 0
    end

    test "跨区同号的预览和实际转账都拒绝歧义，不改余额或流水", %{conn: conn} do
      {sender, token} = user_with_token()
      {:ok, _} = Rice.Grains.grant(sender, 100)

      recipients =
        for region <- ["86", "1"], do: user_fixture(%{phone: "13800001234", phone_region: region})

      count = Rice.Repo.aggregate(Rice.Grains.Transfer, :count)

      for path <- [~p"/api/grain_transfers/recipient", ~p"/api/grain_transfers"] do
        assert %{"errors" => %{"to" => ["接收用户不存在"]}} =
                 conn
                 |> authed(token)
                 |> post(path, %{to: "13800001234", amount: 10})
                 |> json_response(422)
      end

      assert Rice.Repo.get!(Rice.Accounts.User, sender.id).grain_balance == 100

      assert Enum.all?(
               recipients,
               &(Rice.Repo.get!(Rice.Accounts.User, &1.id).grain_balance == 0)
             )

      assert Rice.Repo.aggregate(Rice.Grains.Transfer, :count) == count
    end
  end

  describe "POST /api/grain_transfers" do
    setup do
      {sender, token} = user_with_token()
      # 用 grant 而不是直接改余额 —— 这样账本是自洽的,reconcile 有意义
      {:ok, _} = Rice.Grains.grant(sender, 100)

      %{
        sender: Rice.Repo.get!(Rice.Accounts.User, sender.id),
        token: token,
        recipient: user_fixture()
      }
    end

    test "赠送", %{conn: conn, token: token, recipient: to} do
      assert %{"data" => data} =
               conn
               |> authed(token)
               |> post(~p"/api/grain_transfers", %{to: to.did, amount: 30, memo: "谢谢"})
               |> json_response(201)

      assert data["kind"] == "gift"
      assert data["amount"] == 30
      assert data["memo"] == "谢谢"
      assert data["direction"] == "out"
      assert data["to"]["did"] == to.did
    end

    test "打赏带帖子 URI", %{conn: conn, token: token, recipient: to} do
      uri = "at://did:plc:x/app.bsky.feed.post/abc"

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> post(~p"/api/grain_transfers", %{
                 to: to.did,
                 amount: 5,
                 kind: "reward",
                 subject_uri: uri
               })
               |> json_response(201)

      assert data["kind"] == "reward"
      assert data["subject_uri"] == uri
    end

    test "余额不足 422", %{conn: conn, token: token, recipient: to} do
      assert %{"errors" => %{"amount" => ["稻米不足"]}} =
               conn
               |> authed(token)
               |> post(~p"/api/grain_transfers", %{to: to.did, amount: 101})
               |> json_response(422)
    end

    test "转给自己 422", %{conn: conn, token: token, sender: sender} do
      assert %{"errors" => %{"to" => ["不能转给自己"]}} =
               conn
               |> authed(token)
               |> post(~p"/api/grain_transfers", %{to: sender.did, amount: 1})
               |> json_response(422)
    end

    test "收款方可以用 id / handle / 邮箱 / 手机号指定", %{token: token} do
      to =
        user_fixture(%{
          handle: "ShouKuan.web5.xjdao.test",
          email: "Shou.Kuan@example.com",
          phone: "13800001234",
          phone_region: "86"
        })

      # 每种写法各转 1,五次都要落到同一个人身上
      for identifier <- [
            to.id,
            to.did,
            "shoukuan.web5.xjdao.test",
            "SHOU.KUAN@example.com",
            "13800001234"
          ] do
        assert %{"data" => data} =
                 build_conn()
                 |> authed(token)
                 |> post(~p"/api/grain_transfers", %{to: identifier, amount: 1})
                 |> json_response(201)

        assert data["to"]["did"] == to.did
      end

      assert Rice.Repo.get!(Rice.Accounts.User, to.id).grain_balance == 5
    end

    test "手机号不跨区号误配", %{conn: conn, token: token} do
      user_fixture(%{phone: "13800005678", phone_region: "86"})

      # 带区号前缀的写法不认 —— 界面上没有区号输入,避免歧义匹配
      assert conn
             |> authed(token)
             |> post(~p"/api/grain_transfers", %{to: "86-13800005678", amount: 1})
             |> json_response(422)
    end

    test "收款方不存在 422", %{conn: conn, token: token} do
      assert %{"errors" => %{"to" => ["接收用户不存在"]}} =
               conn
               |> authed(token)
               |> post(~p"/api/grain_transfers", %{to: "did:plc:nobody", amount: 1})
               |> json_response(422)
    end

    test "金额非法 422", %{conn: conn, token: token, recipient: to} do
      for amount <- [0, -1, "abc", nil, 1.5, "0"] do
        assert conn
               |> authed(token)
               |> post(~p"/api/grain_transfers", %{to: to.did, amount: amount})
               |> json_response(422)
      end
    end

    test "未认证 401", %{conn: conn, recipient: to} do
      assert conn
             |> post(~p"/api/grain_transfers", %{to: to.did, amount: 1})
             |> json_response(401)
    end

    # 不能靠请求参数指定付款方,只能是自己
    test "付款方永远是当前登录用户", %{conn: conn, token: token, sender: sender, recipient: to} do
      victim = user_fixture()
      {:ok, _} = Rice.Grains.grant(victim, 1000)

      conn
      |> authed(token)
      |> post(~p"/api/grain_transfers", %{
        to: to.did,
        amount: 10,
        from: victim.did,
        from_user_id: victim.id
      })
      |> json_response(201)

      assert Rice.Repo.get!(Rice.Accounts.User, victim.id).grain_balance == 1000
      assert Rice.Repo.get!(Rice.Accounts.User, sender.id).grain_balance == 90
    end

    # kind 只认 reward,其余一律 gift —— 客户端不能伪造成 grant 来凭空增发
    test "客户端不能把 kind 指定成 grant", %{conn: conn, token: token, recipient: to} do
      assert %{"data" => %{"kind" => "gift"}} =
               conn
               |> authed(token)
               |> post(~p"/api/grain_transfers", %{to: to.did, amount: 1, kind: "grant"})
               |> json_response(201)

      # 总量守恒:客户端伪造 kind 没能凭空造出稻米
      assert Rice.Grains.reconcile().ok?
    end
  end

  describe "GET /api/grain_transfers" do
    test "只返回与自己相关的流水,带方向", %{conn: conn} do
      {me, token} = user_with_token()
      give_grain(me, 100)
      other = user_fixture()

      {:ok, _} = Rice.Grains.transfer(Rice.Repo.get!(Rice.Accounts.User, me.id), other, 10)
      {:ok, _} = Rice.Grains.grant(me, 5)
      {:ok, _} = Rice.Grains.transfer(user_fixture() |> give_grain(50), other, 1)

      assert %{"data" => data} =
               conn |> authed(token) |> get(~p"/api/grain_transfers") |> json_response(200)

      assert length(data) == 2
      assert Enum.sort(Enum.map(data, & &1["direction"])) == ["in", "out"]
    end

    test "分页可用", %{conn: conn} do
      {me, token} = user_with_token()
      for _ <- 1..25, do: {:ok, _} = Rice.Grains.grant(me, 1)

      page1 = conn |> authed(token) |> get(~p"/api/grain_transfers") |> json_response(200)
      assert length(page1["data"]) == 20

      page2 =
        build_conn()
        |> authed(token)
        |> get(~p"/api/grain_transfers?before=#{page1["meta"]["next_cursor"]}")
        |> json_response(200)

      assert length(page2["data"]) == 5
      ids = Enum.map(page1["data"] ++ page2["data"], & &1["id"])
      assert length(Enum.uniq(ids)) == 25
    end

    test "未认证 401", %{conn: conn} do
      assert conn |> get(~p"/api/grain_transfers") |> json_response(401)
    end
  end

  describe "GET /api/grain_grants" do
    test "公开可读,只列增发", %{conn: conn} do
      a = user_fixture() |> give_grain(100)
      b = user_fixture()
      {:ok, _} = Rice.Grains.grant(b, 50)
      {:ok, _} = Rice.Grains.transfer(a, b, 10)

      assert %{"data" => [one]} = conn |> get(~p"/api/grain_grants") |> json_response(200)
      assert one["kind"] == "grant"
      assert is_nil(one["from"])
      assert one["to"]["did"] == b.did
    end
  end
end

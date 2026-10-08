defmodule RiceWeb.Api.Admin.ModerationControllerTest do
  @moduledoc "提案审核、勋章、全站配置、管理员账号。"
  use RiceWeb.ConnCase, async: true

  setup do
    {admin, token} = admin_with_token()
    %{admin: admin, token: token}
  end

  describe "提案审核" do
    test "列表看得到已下架的 —— C 端那份看不到", %{conn: conn, token: token} do
      author = user_fixture()
      listed = proposal_fixture(author)
      unlisted = proposal_fixture(author)
      Rice.Repo.update!(Ecto.Changeset.change(unlisted, listed: false))

      assert %{"data" => data} =
               conn |> authed(token) |> get(~p"/api/admin/proposals") |> json_response(200)

      ids = Enum.map(data, & &1["id"]) |> Enum.sort()
      assert ids == Enum.sort([listed.id, unlisted.id])

      # C 端只看得到上架的
      assert %{"data" => [one]} = build_conn() |> get(~p"/api/proposals") |> json_response(200)
      assert one["id"] == listed.id
    end

    test "下架和恢复", %{conn: conn, token: token} do
      proposal = proposal_fixture(user_fixture())

      assert %{"data" => %{"listed" => false}} =
               conn
               |> authed(token)
               |> patch(~p"/api/admin/proposals/#{proposal.id}", %{listed: false})
               |> json_response(200)

      assert %{"data" => []} = build_conn() |> get(~p"/api/proposals") |> json_response(200)

      # core 的 take-off 只能单向下架,没有恢复的入口
      assert %{"data" => %{"listed" => true}} =
               build_conn()
               |> authed(token)
               |> patch(~p"/api/admin/proposals/#{proposal.id}", %{listed: true})
               |> json_response(200)

      assert %{"data" => [_]} = build_conn() |> get(~p"/api/proposals") |> json_response(200)
    end

    test "listed 不是布尔值 422", %{conn: conn, token: token} do
      proposal = proposal_fixture(user_fixture())

      assert conn
             |> authed(token)
             |> patch(~p"/api/admin/proposals/#{proposal.id}", %{listed: "no"})
             |> json_response(422)
    end

    test "详情带评论,下架的也看得到", %{conn: conn, token: token} do
      author = user_fixture()
      proposal = proposal_fixture(author)
      Rice.Repo.update!(Ecto.Changeset.change(proposal, listed: false))
      {:ok, _} = Rice.Governance.create_comment(author, proposal, "一条评论")

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> get(~p"/api/admin/proposals/#{proposal.id}")
               |> json_response(200)

      assert data["listed"] == false
      assert [%{"body" => "一条评论"}] = data["comments"]
    end

    test "能删任意评论,不只是自己的", %{conn: conn, token: token} do
      author = user_fixture()
      proposal = proposal_fixture(author)
      {:ok, comment} = Rice.Governance.create_comment(user_fixture(), proposal, "别人的评论")

      assert conn
             |> authed(token)
             |> delete(~p"/api/admin/proposals/#{proposal.id}/comments/#{comment.id}")
             |> response(204)

      assert %{"data" => []} =
               build_conn()
               |> get(~p"/api/proposals/#{proposal.id}/comments")
               |> json_response(200)
    end

    test "按标题和发起人搜", %{token: token} do
      author = user_fixture(%{nickname: "赵六"})
      target = proposal_fixture(author, %{title: "修路提案"})
      proposal_fixture(user_fixture(%{nickname: "钱七"}), %{title: "建桥提案"})

      for q <- ["修路", "赵六"] do
        assert %{"data" => [one]} =
                 build_conn()
                 |> authed(token)
                 |> get(~p"/api/admin/proposals?q=#{q}")
                 |> json_response(200)

        assert one["id"] == target.id
      end
    end
  end

  describe "勋章" do
    test "新建并列出,持有人数是现算的", %{conn: conn, token: token} do
      image = attachment_fixture(%{filename: "medal.png"})

      assert %{"data" => badge} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/badges", %{name: "早期贡献者", image_id: image.id})
               |> json_response(201)

      assert badge["name"] == "早期贡献者"
      assert badge["image"]["filename"] == "medal.png"

      record = Rice.Repo.get!(Rice.Community.Badge, badge["id"])
      for _ <- 1..3, do: {:ok, _} = Rice.Community.award_badge(record, user_fixture())

      assert %{"data" => [listed]} =
               build_conn() |> authed(token) |> get(~p"/api/admin/badges") |> json_response(200)

      assert listed["holder_count"] == 3
    end

    test "持有人列表带联系方式,可按名字筛", %{conn: conn, token: token} do
      badge = badge_fixture()
      holder = user_fixture(%{nickname: "孙八", email: "sun@example.com"})
      {:ok, _} = Rice.Community.award_badge(badge, holder)
      {:ok, _} = Rice.Community.award_badge(badge, user_fixture(%{nickname: "周九"}))

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> get(~p"/api/admin/badges/#{badge.id}/holders")
               |> json_response(200)

      assert length(data) == 2

      assert %{"data" => [one]} =
               build_conn()
               |> authed(token)
               |> get(~p"/api/admin/badges/#{badge.id}/holders?q=孙")
               |> json_response(200)

      assert one["email"] == "sun@example.com"
      assert one["awarded_at"]
    end

    # core 的 medal/create 收一个名单文件,建和发是同一次调用。
    # 只建不发的话,这个后台就没有任何发勋章的入口了。
    test "建的时候把名单一起发了", %{conn: conn, token: token} do
      a = user_fixture(%{phone: "13800007777", phone_region: "86"})
      b = user_fixture(%{handle: "bb.web5.xjdao.test"})

      assert %{"data" => badge} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/badges", %{
                 name: "首批共建者",
                 to: ["13800007777", "bb.web5.xjdao.test"]
               })
               |> json_response(201)

      assert %{"data" => holders} =
               build_conn()
               |> authed(token)
               |> get(~p"/api/admin/badges/#{badge["id"]}/holders")
               |> json_response(200)

      assert Enum.map(holders, & &1["id"]) |> Enum.sort() == Enum.sort([a.id, b.id])
    end

    # 名单里一个笔误就留下一枚没有持有人的孤儿勋章 —— 所以建和发在一个事务里
    test "名单里有人认不出来,勋章也不建", %{conn: conn, token: token} do
      user_fixture(%{phone: "13800008888", phone_region: "86"})

      assert %{"errors" => %{"to" => [message]}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/badges", %{
                 name: "不该被建出来",
                 to: ["13800008888", "查无此人@example.com"]
               })
               |> json_response(422)

      assert message =~ "查无此人@example.com"
      refute Rice.Repo.get_by(Rice.Community.Badge, name: "不该被建出来")
    end

    test "不带名单也能建 —— 空勋章是合法的", %{conn: conn, token: token} do
      assert %{"data" => badge} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/badges", %{name: "先建着"})
               |> json_response(201)

      assert badge["name"] == "先建着"
    end

    test "名单里不是字符串时 422 而不是 500", %{conn: conn, token: token} do
      assert %{"errors" => %{"to" => [_]}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/badges", %{name: "坏名单", to: [nil, 123]})
               |> json_response(422)
    end

    test "名单里重复的人只发一次", %{conn: conn, token: token} do
      user = user_fixture(%{phone: "13800009000", phone_region: "86"})

      assert %{"data" => badge} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/badges", %{
                 name: "去重",
                 to: ["13800009000", "13800009000", user.did]
               })
               |> json_response(201)

      assert %{"data" => holders} =
               build_conn()
               |> authed(token)
               |> get(~p"/api/admin/badges/#{badge["id"]}/holders")
               |> json_response(200)

      assert length(holders) == 1
    end
  end

  # core 没有这个入口:medal/create 建和发一次做完,建完就加不了人。
  # 漏一个人只能重建一枚同名勋章,先拿到的人的获得时间也跟着变。
  describe "给已有勋章补发持有人" do
    test "补进去的人出现在持有人列表里", %{conn: conn, token: token} do
      badge = badge_fixture()
      old = user_fixture(%{nickname: "先拿到的"})
      {:ok, _} = Rice.Community.award_badge(badge, old)
      late = user_fixture(%{phone: "13800001111", phone_region: "86"})

      assert %{"data" => %{"awarded" => 1, "already_held" => 0}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/badges/#{badge.id}/holders", %{to: ["13800001111"]})
               |> json_response(201)

      assert %{"data" => holders} =
               build_conn()
               |> authed(token)
               |> get(~p"/api/admin/badges/#{badge.id}/holders")
               |> json_response(200)

      assert Enum.map(holders, & &1["id"]) |> Enum.sort() == Enum.sort([old.id, late.id])
    end

    # 补名单时运营粘的常常是完整名单而不是差集 —— 重叠报错的话这接口没法用
    test "已经持有的人不算错,也不会重复发", %{conn: conn, token: token} do
      badge = badge_fixture()
      held = user_fixture(%{phone: "13800002222", phone_region: "86"})
      {:ok, first} = Rice.Community.award_badge(badge, held)
      fresh = user_fixture(%{handle: "fresh.web5.xjdao.test"})

      assert %{"data" => %{"awarded" => 1, "already_held" => 1}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/badges/#{badge.id}/holders", %{
                 to: ["13800002222", "fresh.web5.xjdao.test"]
               })
               |> json_response(201)

      assert Rice.Community.badge_holder_count(badge) == 2
      assert Rice.Repo.get_by!(Rice.Community.BadgeAward, badge_id: badge.id, user_id: fresh.id)

      # 先拿到的人的获得时间不能被这次补发改掉 —— 重建一枚同名勋章的老办法
      # 正是会毁掉这个时间,补发接口存在的意义有一半在这里
      assert Rice.Repo.reload!(first).awarded_at == first.awarded_at
    end

    test "名单里有人认不出来,一个都不发", %{conn: conn, token: token} do
      badge = badge_fixture()
      user_fixture(%{phone: "13800003333", phone_region: "86"})

      assert %{"errors" => %{"to" => [message]}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/badges/#{badge.id}/holders", %{
                 to: ["13800003333", "查无此人@example.com"]
               })
               |> json_response(422)

      assert message =~ "查无此人@example.com"
      assert Rice.Community.badge_holder_count(badge) == 0
    end

    test "名单里不是字符串时 422 而不是 500", %{conn: conn, token: token} do
      badge = badge_fixture()

      assert %{"errors" => %{"to" => [_]}} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/badges/#{badge.id}/holders", %{to: [nil, 123]})
               |> json_response(422)
    end

    # 空名单在新建时是合法的(建一枚空勋章),在这里不是 ——
    # 补发一个空名单是个笔误,不该静悄悄地返回成功
    test "空名单 422", %{token: token} do
      badge = badge_fixture()

      for body <- [%{}, %{to: []}, %{to: ["", "  "]}] do
        assert %{"errors" => %{"to" => ["名单不能为空"]}} =
                 build_conn()
                 |> authed(token)
                 |> post(~p"/api/admin/badges/#{badge.id}/holders", body)
                 |> json_response(422)
      end
    end

    test "勋章不存在 404", %{conn: conn, token: token} do
      assert conn
             |> authed(token)
             |> post(~p"/api/admin/badges/3ke6kg3wk223e/holders", %{to: ["a"]})
             |> json_response(404)
    end

    test "未认证 401", %{conn: conn} do
      badge = badge_fixture()

      assert conn
             |> post(~p"/api/admin/badges/#{badge.id}/holders", %{to: ["a"]})
             |> json_response(401)
    end

    # C 端令牌调不了管理端 —— 两套令牌互相换不过去
    # 发勋章是内容运营,不是管理员管理 —— operator 应该能做
    test "运营也能补发", %{conn: _conn} do
      badge = badge_fixture()
      user = user_fixture(%{handle: "op-target.web5.xjdao.test"})
      {_admin, token} = admin_with_token(%{role: "operator"})

      assert %{"data" => %{"awarded" => 1}} =
               build_conn()
               |> authed(token)
               |> post(~p"/api/admin/badges/#{badge.id}/holders", %{to: [user.handle]})
               |> json_response(201)
    end
  end

  # 后台的提案列表有个「发布时间」范围搜索。core 有这个筛选,
  # 迁过来时前端还在发 since/until,而服务端不认 —— 表现是筛了等于没筛。
  describe "提案按发布时间筛" do
    test "范围内外分得开", %{conn: conn, token: token} do
      old = proposal_fixture(user_fixture(), %{title: "去年的提案"})
      Rice.Repo.update!(Ecto.Changeset.change(old, inserted_at: ~U[2025-01-01 00:00:00.000000Z]))
      proposal_fixture(user_fixture(), %{title: "刚发的提案"})

      titles = fn query ->
        conn
        |> authed(token)
        |> get(~p"/api/admin/proposals?#{query}")
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["title"])
      end

      assert "刚发的提案" in titles.(%{since: "2026-01-01T00:00:00Z"})
      refute "去年的提案" in titles.(%{since: "2026-01-01T00:00:00Z"})
      assert "去年的提案" in titles.(%{until: "2026-01-01T00:00:00Z"})
      refute "刚发的提案" in titles.(%{until: "2026-01-01T00:00:00Z"})
    end

    # 一个手滑的日期不该让整个列表 500
    test "解析不了的时间当没传", %{conn: conn, token: token} do
      proposal_fixture(user_fixture())

      assert %{"data" => [_ | _]} =
               conn
               |> authed(token)
               |> get(~p"/api/admin/proposals?since=2026-07-01")
               |> json_response(200)
    end
  end

  describe "全站配置" do
    test "读改一体 —— core 是三个接口改同一行", %{conn: conn, token: token} do
      a = attachment_fixture(%{filename: "章程.pdf"})
      b = attachment_fixture(%{filename: "年报.pdf"})

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> patch(~p"/api/admin/settings", %{
                 fund_scale: 1_000_000,
                 proposal_approval_votes: 5,
                 document_ids: [a.id, b.id]
               })
               |> json_response(200)

      assert data["fund_scale"] == 1_000_000
      assert data["proposal_approval_votes"] == 5
      assert Enum.map(data["documents"], & &1["filename"]) == ["章程.pdf", "年报.pdf"]

      # 不传 document_ids 就不动文件清单
      assert %{"data" => data} =
               build_conn()
               |> authed(token)
               |> patch(~p"/api/admin/settings", %{fund_scale: 2_000_000})
               |> json_response(200)

      assert data["fund_scale"] == 2_000_000
      assert length(data["documents"]) == 2

      # 传空数组就是清空
      assert %{"data" => %{"documents" => []}} =
               build_conn()
               |> authed(token)
               |> patch(~p"/api/admin/settings", %{document_ids: []})
               |> json_response(200)
    end

    test "文件顺序就是数组顺序", %{conn: conn, token: token} do
      a = attachment_fixture(%{filename: "甲.pdf"})
      b = attachment_fixture(%{filename: "乙.pdf"})

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> patch(~p"/api/admin/settings", %{document_ids: [b.id, a.id]})
               |> json_response(200)

      assert Enum.map(data["documents"], & &1["filename"]) == ["乙.pdf", "甲.pdf"]
    end

    # 提案配置运营能改;金库公示在管理端只对 admin 开放,服务端也一样
    test "运营只改得了提案票数,金库字段原样不动", %{conn: conn} do
      {_op, op_token} = admin_with_token(%{role: "operator"})

      assert %{"data" => data} =
               conn
               |> authed(op_token)
               |> patch(~p"/api/admin/settings", %{
                 fund_scale: 999,
                 proposal_approval_votes: 7
               })
               |> json_response(200)

      assert data["proposal_approval_votes"] == 7
      refute data["fund_scale"] == 999
    end

    test "负数 422", %{conn: conn, token: token} do
      assert conn
             |> authed(token)
             |> patch(~p"/api/admin/settings", %{fund_scale: -1})
             |> json_response(422)
    end

    test "改完 C 端立刻看得到", %{conn: conn, token: token} do
      conn
      |> authed(token)
      |> patch(~p"/api/admin/settings", %{fund_scale: 888})
      |> json_response(200)

      assert %{"data" => %{"fund_scale" => 888}} =
               build_conn() |> get(~p"/api/settings/foundation") |> json_response(200)
    end
  end

  describe "管理员账号(仅 role=admin)" do
    test "新建返回初始密码,而且这个密码能登进去", %{conn: conn, token: token} do
      assert %{"data" => created} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/admin_users", %{
                 phone: "13911112222",
                 phone_region: "86",
                 role: "operator"
               })
               |> json_response(201)

      password = created["initial_password"]
      assert byte_size(password) == 12
      assert created["role"] == "operator"

      # 初始密码确实是这个账号的密码
      admin = Rice.Repo.get!(Rice.Admin.AdminUser, created["id"])
      assert Rice.Admin.AdminUser.valid_password?(admin, password)
      refute Rice.Admin.AdminUser.valid_password?(admin, password <> "x")
    end

    test "operator 进不了管理员管理 —— core 只在前端藏菜单", %{conn: conn} do
      {_operator, operator_token} = admin_with_token(%{role: "operator"})

      assert conn
             |> authed(operator_token)
             |> get(~p"/api/admin/admin_users")
             |> json_response(403)

      assert build_conn()
             |> authed(operator_token)
             |> post(~p"/api/admin/admin_users", %{phone: "13911113333"})
             |> json_response(403)
    end

    test "operator 照常能做内容运营", %{conn: conn} do
      {_operator, operator_token} = admin_with_token(%{role: "operator"})

      assert %{"data" => _} =
               conn
               |> authed(operator_token)
               |> post(~p"/api/admin/apps", %{name: "运营也能建"})
               |> json_response(201)
    end

    test "删不掉超管,也删不掉自己", %{conn: conn, token: token, admin: admin} do
      superuser = admin_fixture(%{superuser: true})
      Rice.Repo.update!(Ecto.Changeset.change(superuser, superuser: true))

      assert conn
             |> authed(token)
             |> delete(~p"/api/admin/admin_users/#{superuser.id}")
             |> json_response(422)

      assert build_conn()
             |> authed(token)
             |> delete(~p"/api/admin/admin_users/#{admin.id}")
             |> json_response(422)
    end

    test "删掉管理员会撤销他的全部会话", %{conn: conn, token: token} do
      {victim, victim_token} = admin_with_token()
      assert build_conn() |> authed(victim_token) |> get(~p"/api/admin/me") |> json_response(200)

      assert conn
             |> authed(token)
             |> delete(~p"/api/admin/admin_users/#{victim.id}")
             |> response(204)

      assert build_conn() |> authed(victim_token) |> get(~p"/api/admin/me") |> json_response(401)
    end

    test "手机号重复 422", %{conn: conn, token: token} do
      admin_fixture(%{phone: "13911114444", phone_region: "86"})

      assert conn
             |> authed(token)
             |> post(~p"/api/admin/admin_users", %{phone: "13911114444", phone_region: "86"})
             |> json_response(422)
    end

    # 登录和找回密码都只认手机号,只填邮箱建出来的账号是个死账号:
    # 能存进库,登不进去,也找不回密码。
    test "只填邮箱建不出管理员", %{conn: conn, token: token} do
      assert %{"errors" => errors} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/admin_users", %{email: "no-phone@example.com"})
               |> json_response(422)

      assert errors["phone"]
      refute Rice.Repo.get_by(Rice.Admin.AdminUser, email: "no-phone@example.com")
    end

    test "邮箱仍然可以和手机号一起填", %{conn: conn, token: token} do
      assert %{"data" => created} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/admin_users", %{
                 phone: "13911116666",
                 email: "both@example.com"
               })
               |> json_response(201)

      assert created["email"] == "both@example.com"
    end

    test "角色只能是 admin 或 operator", %{conn: conn, token: token} do
      assert conn
             |> authed(token)
             |> post(~p"/api/admin/admin_users", %{phone: "13911115555", role: "superadmin"})
             |> json_response(422)
    end
  end
end

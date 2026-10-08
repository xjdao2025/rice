defmodule RiceWeb.Api.Admin.CatalogControllerTest do
  @moduledoc """
  应用入口 / 轮播位 / 公告 / 节点走同一个控制器,所以增删改排序只测一遍
  (以 apps 为准),另外三种各测一条,确认路由和视图挂对了。
  """
  use RiceWeb.ConnCase, async: true

  setup do
    {_admin, token} = admin_with_token()
    %{token: token}
  end

  describe "增删改" do
    test "新建 / 改 / 删", %{conn: conn, token: token} do
      logo = attachment_fixture(%{filename: "logo.png"})

      assert %{"data" => created} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/apps", %{name: "论坛", url: "https://a.test", logo_id: logo.id})
               |> json_response(201)

      assert created["name"] == "论坛"
      assert created["logo"]["filename"] == "logo.png"

      assert %{"data" => updated} =
               build_conn()
               |> authed(token)
               |> patch(~p"/api/admin/apps/#{created["id"]}", %{name: "社区"})
               |> json_response(200)

      assert updated["name"] == "社区"
      # 没传的字段不该被清掉
      assert updated["url"] == "https://a.test"

      assert build_conn()
             |> authed(token)
             |> delete(~p"/api/admin/apps/#{created["id"]}")
             |> response(204)

      assert build_conn()
             |> authed(token)
             |> get(~p"/api/admin/apps/#{created["id"]}")
             |> json_response(404)
    end

    test "新建的排在最后", %{conn: conn, token: token} do
      for name <- ~w(甲 乙 丙) do
        build_conn() |> authed(token) |> post(~p"/api/admin/apps", %{name: name})
      end

      assert %{"data" => apps} =
               conn |> authed(token) |> get(~p"/api/admin/apps") |> json_response(200)

      assert Enum.map(apps, & &1["name"]) == ~w(甲 乙 丙)
      assert Enum.map(apps, & &1["position"]) == [0, 1, 2]
    end

    test "必填字段缺失 422", %{conn: conn, token: token} do
      assert %{"errors" => errors} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/apps", %{url: "x"})
               |> json_response(422)

      assert errors["name"]
    end

    test "id 不合法当 404,不是 500", %{conn: conn, token: token} do
      assert conn |> authed(token) |> get(~p"/api/admin/apps/not-a-tsid") |> json_response(404)
    end
  end

  describe "排序" do
    test "整份顺序覆盖", %{conn: conn, token: token} do
      ids =
        for name <- ~w(甲 乙 丙) do
          %{"data" => app} =
            build_conn()
            |> authed(token)
            |> post(~p"/api/admin/apps", %{name: name})
            |> json_response(201)

          app["id"]
        end

      reversed = Enum.reverse(ids)

      assert %{"data" => apps} =
               conn
               |> authed(token)
               |> put(~p"/api/admin/apps/positions", %{ids: reversed})
               |> json_response(200)

      assert Enum.map(apps, & &1["id"]) == reversed
    end

    # 排到一半失败会留下半新半旧的顺序 —— 所以整批在一个事务里
    test "有不存在的 id 时整批不生效", %{conn: conn, token: token} do
      %{"data" => a} =
        build_conn()
        |> authed(token)
        |> post(~p"/api/admin/apps", %{name: "甲"})
        |> json_response(201)

      %{"data" => b} =
        build_conn()
        |> authed(token)
        |> post(~p"/api/admin/apps", %{name: "乙"})
        |> json_response(201)

      assert %{"errors" => %{"ids" => _}} =
               conn
               |> authed(token)
               |> put(~p"/api/admin/apps/positions", %{ids: [b["id"], a["id"], "2222222222222"]})
               |> json_response(422)

      assert %{"data" => apps} =
               build_conn() |> authed(token) |> get(~p"/api/admin/apps") |> json_response(200)

      # 顺序原样,没有被排到一半
      assert Enum.map(apps, & &1["name"]) == ~w(甲 乙)
    end

    test "ids 不是数组 422", %{conn: conn, token: token} do
      assert conn
             |> authed(token)
             |> put(~p"/api/admin/apps/positions", %{ids: "甲"})
             |> json_response(422)
    end

    # positions 必须排在 /:id 前面,否则会被当成一个 id
  end

  describe "另外三种资源" do
    test "banners", %{conn: conn, token: token} do
      image = attachment_fixture()

      assert %{"data" => banner} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/banners", %{url: "https://b.test", image_id: image.id})
               |> json_response(201)

      assert banner["url"] == "https://b.test"
      assert banner["image"]["id"] == image.id
    end

    test "announcements", %{conn: conn, token: token} do
      assert %{"data" => announcement} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/announcements", %{title: "通知"})
               |> json_response(201)

      assert announcement["title"] == "通知"
    end

    test "nodes 带节点主", %{conn: conn, token: token} do
      owner = user_fixture(%{nickname: "节点主"})

      assert %{"data" => node} =
               conn
               |> authed(token)
               |> post(~p"/api/admin/nodes", %{name: "郑州", user_id: owner.id})
               |> json_response(201)

      assert node["owner"]["nickname"] == "节点主"
      assert node["owner"]["grain_balance"] == 0
      assert node["grain_balance"] == 0
      assert node["grain_frozen_balance"] == 0
    end
  end

  test "未认证一律 401", %{conn: conn} do
    assert conn |> get(~p"/api/admin/apps") |> json_response(401)
    assert build_conn() |> post(~p"/api/admin/apps", %{name: "x"}) |> json_response(401)
    assert build_conn() |> put(~p"/api/admin/apps/positions", %{ids: []}) |> json_response(401)
  end

  # 管理端令牌是另一套,C 端用户拿不到后台
end

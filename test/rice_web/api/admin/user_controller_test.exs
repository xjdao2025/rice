defmodule RiceWeb.Api.Admin.UserControllerTest do
  use RiceWeb.ConnCase, async: true

  setup do
    {_admin, token} = admin_with_token()
    %{token: token}
  end

  describe "列表与过滤" do
    test "按昵称 / handle / 邮箱 / 手机号模糊搜", %{conn: conn, token: token} do
      target =
        user_fixture(%{
          nickname: "张三",
          handle: "zhangsan.web5.xjdao.test",
          email: "zhangsan@example.com",
          phone: "13800001111"
        })

      user_fixture(%{nickname: "李四"})

      for q <- ["张", "zhangsan", "zhangsan@example.com", "1380000"] do
        assert %{"data" => [one]} =
                 build_conn()
                 |> authed(token)
                 |> get(~p"/api/admin/users?q=#{q}")
                 |> json_response(200)

        assert one["id"] == target.id, "搜 #{q} 应该只命中张三"
      end

      # 后台要靠手机邮箱找人,所以这两个字段必须给出来
      assert %{"data" => [one]} =
               conn |> authed(token) |> get(~p"/api/admin/users?q=张") |> json_response(200)

      assert one["phone"] == "13800001111"
      assert one["email"] == "zhangsan@example.com"
    end

    # 用户输入直接进 LIKE,一个 % 就是全表
    test "搜索里的 % 和 _ 被当成字面量", %{conn: conn, token: token} do
      user_fixture(%{nickname: "张三"})
      user_fixture(%{nickname: "李四"})

      assert %{"data" => []} =
               conn |> authed(token) |> get(~p"/api/admin/users?q=%") |> json_response(200)

      assert %{"data" => []} =
               build_conn()
               |> authed(token)
               |> get(~p"/api/admin/users?q=_")
               |> json_response(200)
    end

    test "按节点身份和停用状态过滤", %{conn: conn, token: token} do
      member = user_fixture()
      Rice.Repo.update!(Ecto.Changeset.change(member, node_member: true))
      plain = user_fixture()

      assert %{"data" => [one]} =
               conn
               |> authed(token)
               |> get(~p"/api/admin/users?node_member=true")
               |> json_response(200)

      assert one["id"] == member.id

      assert %{"data" => [one]} =
               build_conn()
               |> authed(token)
               |> get(~p"/api/admin/users?node_member=false")
               |> json_response(200)

      assert one["id"] == plain.id
    end

    test "软删的用户不出现", %{conn: conn, token: token} do
      deleted = user_fixture()
      Rice.Repo.update!(Ecto.Changeset.change(deleted, deleted_at: DateTime.utc_now()))

      assert %{"data" => []} =
               conn |> authed(token) |> get(~p"/api/admin/users") |> json_response(200)
    end
  end

  describe "改管理位" do
    test "停用会当场撤销该用户的全部令牌", %{conn: conn, token: token} do
      {user, user_token} = user_with_token()
      # 先确认这把令牌本来是好使的
      assert build_conn() |> authed(user_token) |> get(~p"/api/users/me") |> json_response(200)

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> patch(~p"/api/admin/users/#{user.id}", %{disabled: true})
               |> json_response(200)

      assert data["disabled"] == true

      # core 只改标记,手上的 JWT 还能用满 30 天
      assert build_conn() |> authed(user_token) |> get(~p"/api/users/me") |> json_response(401)
    end

    test "恢复启用", %{conn: conn, token: token} do
      user = user_fixture()
      Rice.Repo.update!(Ecto.Changeset.change(user, disabled_at: DateTime.utc_now()))

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> patch(~p"/api/admin/users/#{user.id}", %{disabled: false})
               |> json_response(200)

      assert data["disabled"] == false
    end

    test "设/取消节点身份", %{conn: conn, token: token} do
      user = user_fixture()

      assert %{"data" => %{"node_member" => true}} =
               conn
               |> authed(token)
               |> patch(~p"/api/admin/users/#{user.id}", %{node_member: true})
               |> json_response(200)

      assert %{"data" => %{"node_member" => false}} =
               build_conn()
               |> authed(token)
               |> patch(~p"/api/admin/users/#{user.id}", %{node_member: false})
               |> json_response(200)
    end

    # 只认两个管理位,别的字段塞进来一律无效
    test "改不动余额、did、handle", %{conn: conn, token: token} do
      user = user_fixture()

      conn
      |> authed(token)
      |> patch(~p"/api/admin/users/#{user.id}", %{
        node_member: true,
        grain_balance: 999_999,
        did: "did:plc:hacker",
        handle: "hacker.test"
      })
      |> json_response(200)

      reloaded = Rice.Repo.get!(Rice.Accounts.User, user.id)
      assert reloaded.grain_balance == 0
      assert reloaded.did == user.did
      assert reloaded.handle == user.handle
    end

    test "什么都没改时 422", %{conn: conn, token: token} do
      user = user_fixture()

      assert conn
             |> authed(token)
             |> patch(~p"/api/admin/users/#{user.id}", %{nickname: "改不动"})
             |> json_response(422)
    end

    test "找不到的用户 404", %{conn: conn, token: token} do
      assert conn
             |> authed(token)
             |> patch(~p"/api/admin/users/2222222222222", %{disabled: true})
             |> json_response(404)
    end
  end

  # 后台的表格是页码式的:运营要跳页、要知道一共多少条。游标给不了这两样。
  describe "页码分页" do
    test "传 page 时 meta 带上 total", %{conn: conn, token: token} do
      for i <- 1..5, do: user_fixture(%{nickname: "翻页#{i}"})

      assert %{"data" => data, "meta" => meta} =
               conn
               |> authed(token)
               |> get(~p"/api/admin/users?page=1&per_page=2")
               |> json_response(200)

      assert length(data) == 2
      assert meta["total"] == 5
      assert meta["page"] == 1
      assert meta["per_page"] == 2
    end

    test "过滤条件和页码一起用时,total 算的是过滤后的", %{conn: conn, token: token} do
      for i <- 1..4, do: user_fixture(%{nickname: "甲#{i}"})
      for i <- 1..3, do: user_fixture(%{nickname: "乙#{i}"})

      assert %{"meta" => meta} =
               conn
               |> authed(token)
               |> get(~p"/api/admin/users?q=甲&page=1&per_page=2")
               |> json_response(200)

      assert meta["total"] == 4
    end

    # 少了这条,C 端信息流哪天被默认切成页码都没人发现
  end

  test "未认证 401", %{conn: conn} do
    assert conn |> get(~p"/api/admin/users") |> json_response(401)
  end
end

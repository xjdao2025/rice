defmodule RiceWeb.Api.NodeControllerTest do
  use RiceWeb.ConnCase, async: true

  describe "GET /api/nodes" do
    test "空库返回空数组", %{conn: conn} do
      assert %{"data" => []} = conn |> get(~p"/api/nodes") |> json_response(200)
    end

    test "按 position 升序,带节点主", %{conn: conn} do
      owner = user_fixture(%{nickname: "主理人"}) |> give_grain(777)
      node_fixture(%{name: "乙", position: 2})
      node_fixture(%{name: "甲", position: 1, user_id: owner.id})

      assert %{"data" => data} = conn |> get(~p"/api/nodes") |> json_response(200)
      assert Enum.map(data, & &1["name"]) == ["甲", "乙"]

      [first, second] = data
      assert first["owner"]["nickname"] == "主理人"
      assert first["owner"]["did"] == owner.did
      refute Map.has_key?(first["owner"], "grain_balance")
      assert is_nil(second["owner"])
    end

    test "节点主的联系方式不外露", %{conn: conn} do
      owner = user_fixture(%{email: "secret@example.com", phone: "13800000000"})
      node_fixture(%{user_id: owner.id})

      body = conn |> get(~p"/api/nodes") |> response(200)

      refute body =~ "secret@example.com"
      refute body =~ "13800000000"
    end
  end

  describe "GET /api/nodes/members" do
    test "只列节点用户", %{conn: conn} do
      member = user_fixture(%{nickname: "节点用户"})
      Rice.Repo.update!(Ecto.Changeset.change(member, node_member: true))
      user_fixture(%{nickname: "普通用户"})

      assert %{"data" => [one]} = conn |> get(~p"/api/nodes/members") |> json_response(200)
      assert one["nickname"] == "节点用户"
    end

    test "被禁用或软删的节点用户不出现", %{conn: conn} do
      disabled = user_fixture()

      Rice.Repo.update!(
        Ecto.Changeset.change(disabled, node_member: true, disabled_at: DateTime.utc_now())
      )

      deleted = user_fixture()

      Rice.Repo.update!(
        Ecto.Changeset.change(deleted, node_member: true, deleted_at: DateTime.utc_now())
      )

      assert %{"data" => []} = conn |> get(~p"/api/nodes/members") |> json_response(200)
    end
  end

  describe "社区申请与身份" do
    setup do
      {admin, admin_token} = user_with_token()
      {applicant, applicant_token} = user_with_token()
      {_other, other_token} = user_with_token()
      node = node_fixture(%{user_id: admin.id, name: "青禾社区"})

      %{
        admin: admin,
        admin_token: admin_token,
        applicant: applicant,
        applicant_token: applicant_token,
        other_token: other_token,
        node: node
      }
    end

    test "入会申请仅本人和本节点管理员可见，余额不公开", ctx do
      data = apply_join(ctx, "我的私人申请理由")
      application_id = data["my_application"]["id"]
      assert data["my_application"]["status"] == "pending"
      assert is_nil(data["role"])
      refute Map.has_key?(data, "applications")

      for token <- [nil, ctx.other_token] do
        conn = if token, do: authed(build_conn(), token), else: build_conn()
        public = conn |> get("/api/nodes/#{ctx.node.id}") |> json_response(200)
        assert is_nil(public["data"]["my_application"])
        refute Map.has_key?(public["data"], "applications")
        refute Jason.encode!(public) =~ "我的私人申请理由"
        refute Map.has_key?(public["data"]["owner"], "grain_balance")
      end

      admin_data = get_node(ctx.admin_token, ctx.node.id)
      assert [%{"id" => ^application_id, "reason" => "我的私人申请理由"}] = admin_data["applications"]
      assert is_nil(admin_data["my_application"])

      assert build_conn()
             |> authed(ctx.other_token)
             |> post("/api/nodes/#{ctx.node.id}/applications/#{application_id}/approve")
             |> response(403)

      second_node = node_fixture(%{user_id: ctx.admin.id})

      assert build_conn()
             |> authed(ctx.admin_token)
             |> post("/api/nodes/#{second_node.id}/applications/#{application_id}/approve")
             |> response(404)

      assert build_conn() |> post("/api/nodes/#{ctx.node.id}/applications") |> response(401)
      assert build_conn() |> get("/api/nodes?mine=identity") |> response(401)
    end

    test "重复申请返回原记录，拒绝可重申，通过后身份和历史保留", ctx do
      first = apply_join(ctx, "第一次")["my_application"]
      assert apply_join(ctx, "重复点击")["my_application"]["id"] == first["id"]

      rejected = review(ctx, first["id"], "reject", %{review_reason: "请补充介绍"})
      assert [%{"status" => "rejected", "review_reason" => "请补充介绍"}] = rejected["applications"]
      assert get_node(ctx.applicant_token, ctx.node.id)["my_application"]["status"] == "rejected"
      assert identity(ctx.applicant_token) == []

      second = apply_join(ctx, "补充后的介绍")["my_application"]
      refute second["id"] == first["id"]
      assert [%{"role" => nil}] = identity(ctx.applicant_token)
      approved = review(ctx, second["id"], "approve")
      assert Enum.map(approved["applications"], & &1["status"]) == ["approved", "rejected"]
      assert Enum.map(approved["members"], & &1["role"]) == ["admin", "member"]

      assert review(ctx, second["id"], "approve")["applications"] == approved["applications"]

      assert [%{"role" => "member", "my_application" => %{"status" => "approved"}}] =
               identity(ctx.applicant_token)

      assert [%{"role" => "admin"}] = identity(ctx.admin_token)
      assert identity(ctx.other_token) == []

      assert build_conn()
             |> authed(ctx.applicant_token)
             |> post("/api/nodes/#{ctx.node.id}/applications")
             |> response(409)

      assert build_conn()
             |> authed(ctx.admin_token)
             |> post("/api/nodes/#{ctx.node.id}/applications/#{second["id"]}/reject")
             |> response(409)

      assert %{"data" => [%{"role" => "admin"}, %{"role" => "member"}]} =
               build_conn() |> get("/api/nodes/#{ctx.node.id}/members") |> json_response(200)
    end

    test "目录筛选按真实社区关系，并转义搜索通配符", ctx do
      node_fixture(%{name: "别的节点"})
      apply_join(ctx, "希望加入")

      for mine <- ["pending", "identity"] do
        assert %{"data" => [%{"id" => id}]} =
                 build_conn()
                 |> authed(ctx.applicant_token)
                 |> get("/api/nodes", %{mine: mine, q: "青禾"})
                 |> json_response(200)

        assert id == ctx.node.id
      end

      for mine <- ["joined", "managed"] do
        assert %{"data" => []} =
                 build_conn()
                 |> authed(ctx.applicant_token)
                 |> get("/api/nodes", %{mine: mine})
                 |> json_response(200)
      end

      assert %{"data" => []} = build_conn() |> get("/api/nodes", %{q: "%"}) |> json_response(200)
    end

    test "无管理员的旧节点保持只读", ctx do
      node = node_fixture()

      assert %{"data" => %{"owner" => nil}} =
               build_conn() |> get("/api/nodes/#{node.id}") |> json_response(200)

      assert build_conn()
             |> authed(ctx.applicant_token)
             |> post("/api/nodes/#{node.id}/applications")
             |> response(403)
    end

    test "数据库约束阻止同一用户产生两条待审申请", ctx do
      apply_join(ctx, "第一次")

      changeset =
        Rice.Community.JoinApplication.create_changeset(
          %Rice.Community.JoinApplication{node_id: ctx.node.id, user_id: ctx.applicant.id},
          %{}
        )

      assert {:error, invalid} = Rice.Repo.insert(changeset, mode: :savepoint)
      assert {_, options} = invalid.errors[:node_id]
      assert options[:constraint] == :unique
      assert options[:constraint_name] == "node_join_applications_one_pending"
    end
  end

  defp apply_join(ctx, reason) do
    build_conn()
    |> authed(ctx.applicant_token)
    |> post("/api/nodes/#{ctx.node.id}/applications", %{reason: reason})
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp review(ctx, id, action, params \\ %{}) do
    build_conn()
    |> authed(ctx.admin_token)
    |> post("/api/nodes/#{ctx.node.id}/applications/#{id}/#{action}", params)
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp get_node(token, id) do
    build_conn()
    |> authed(token)
    |> get("/api/nodes/#{id}")
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp identity(token) do
    build_conn()
    |> authed(token)
    |> get("/api/nodes?mine=identity")
    |> json_response(200)
    |> Map.fetch!("data")
  end
end

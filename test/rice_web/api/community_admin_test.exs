defmodule RiceWeb.Api.CommunityAdminTest do
  use RiceWeb.ConnCase, async: true
  import Ecto.Query
  alias Rice.{Community, Repo}

  setup do
    {owner, owner_token} = user_with_token()
    {manager, manager_token} = user_with_token()
    {applicant, applicant_token} = user_with_token()
    node = node_fixture(%{user_id: owner.id})

    Repo.insert!(
      Community.Membership.changeset(%Community.Membership{node_id: node.id, user_id: manager.id})
    )

    %{
      owner: owner,
      owner_token: owner_token,
      manager: manager,
      manager_token: manager_token,
      applicant: applicant,
      applicant_token: applicant_token,
      node: node
    }
  end

  test "只有创始管理员可授权现有成员，其他管理员能审批入会且撤权立即生效", ctx do
    role_path = "/api/nodes/#{ctx.node.id}/members/"
    assert build_conn() |> patch(role_path <> ctx.manager.id, %{role: "admin"}) |> response(401)

    assert build_conn()
           |> authed(ctx.manager_token)
           |> patch(role_path <> ctx.manager.id, %{role: "admin"})
           |> response(403)

    assert build_conn()
           |> authed(ctx.owner_token)
           |> patch(role_path <> ctx.applicant.id, %{role: "admin"})
           |> response(404)

    assert build_conn()
           |> authed(ctx.owner_token)
           |> patch(role_path <> ctx.owner.id, %{role: "member"})
           |> response(403)

    assert build_conn()
           |> authed(ctx.owner_token)
           |> patch(role_path <> ctx.manager.id, %{role: "owner"})
           |> response(422)

    promoted = role(ctx, "admin")
    assert Enum.count(promoted["members"], &(&1["role"] == "admin")) == 2
    assert promoted["can_manage_members"]
    assert Community.admin?(ctx.node, ctx.manager)
    assert Enum.sort(Community.admin_ids(ctx.node)) == Enum.sort([ctx.owner.id, ctx.manager.id])

    joined =
      build_conn()
      |> authed(ctx.applicant_token)
      |> post("/api/nodes/#{ctx.node.id}/applications", %{reason: "申请"})
      |> json_response(200)

    id = joined["data"]["my_application"]["id"]
    view = get_node(ctx.manager_token, ctx.node.id)
    assert [%{"id" => ^id}] = view["applications"]
    refute view["can_manage_members"]

    assert build_conn()
           |> authed(ctx.manager_token)
           |> patch(role_path <> ctx.applicant.id, %{role: "admin"})
           |> response(403)

    build_conn()
    |> authed(ctx.manager_token)
    |> post("/api/nodes/#{ctx.node.id}/applications/#{id}/approve")
    |> json_response(200)

    role(ctx, "member")
    refute Community.admin?(ctx.node, ctx.manager)
    refute Map.has_key?(get_node(ctx.manager_token, ctx.node.id), "applications")
  end

  for kind <- ["tasks", "events"] do
    @kind kind
    test "#{kind}: 共同管理、申请联系信息与个人草稿按实时权限隔离", ctx do
      role(ctx, "admin")
      path = "/api/#{@kind}"
      created = create(@kind, ctx.owner_token, ctx.node)
      id = created["id"]
      own = create(@kind, ctx.manager_token, ctx.node)
      legacy = create(@kind, ctx.owner_token, ctx.node)

      {schema, funding_field} =
        if @kind == "tasks",
          do: {Rice.Tasks.Task, :funding_node_id},
          else: {Rice.Events.Event, :settlement_node_id}

      schema
      |> Repo.get!(legacy["id"])
      |> Ecto.Changeset.change([{funding_field, nil}])
      |> Repo.update!()

      draft = create(@kind, ctx.owner_token, ctx.node, "draft")
      success = if @kind == "tasks", do: 201, else: 200

      applied =
        build_conn()
        |> authed(ctx.applicant_token)
        |> post("#{path}/#{id}/applications", %{contact: "申请人私人电话"})
        |> json_response(success)

      application_id = applied["data"]["my_application"]["id"]
      assert Enum.sort(recipients(@kind, id)) == Enum.sort([ctx.owner.id, ctx.manager.id])

      build_conn()
      |> authed(ctx.applicant_token)
      |> post("#{path}/#{legacy["id"]}/applications", %{contact: "历史申请私人电话"})
      |> json_response(success)

      expected =
        if @kind == "tasks", do: [ctx.owner.id, ctx.manager.id], else: [ctx.owner.id]

      assert Enum.sort(recipients(@kind, legacy["id"])) == Enum.sort(expected)

      legacy_view =
        build_conn()
        |> authed(ctx.manager_token)
        |> get("#{path}/#{legacy["id"]}")
        |> json_response(200)

      refute legacy_view["data"]["can_manage"]
      refute inspect(legacy_view) =~ "历史申请私人电话"

      assert build_conn()
             |> authed(ctx.manager_token)
             |> post("#{path}/#{legacy["id"]}/cancel")
             |> response(403)

      managed =
        build_conn()
        |> authed(ctx.manager_token)
        |> get(path, %{mine: "managed"})
        |> json_response(200)

      assert Enum.sort(Enum.map(managed["data"], & &1["id"])) ==
               Enum.sort([id, own["id"], legacy["id"]])

      refute inspect(managed) =~ "申请人私人电话"

      assert build_conn()
             |> authed(ctx.manager_token)
             |> get("#{path}/#{draft["id"]}")
             |> response(404)

      detail =
        build_conn() |> authed(ctx.manager_token) |> get("#{path}/#{id}") |> json_response(200)

      assert detail["data"]["can_manage"]
      assert hd(detail["data"]["applications"])["contact"] == "申请人私人电话"

      build_conn()
      |> authed(ctx.manager_token)
      |> post("#{path}/#{id}/applications/#{application_id}/reject")
      |> json_response(200)

      role(ctx, "member")

      build_conn()
      |> authed(ctx.applicant_token)
      |> post("#{path}/#{own["id"]}/applications", %{contact: "交接后的申请电话"})
      |> json_response(success)

      assert recipients(@kind, own["id"]) == [ctx.owner.id]

      if @kind == "tasks" do
        {:ok, task} = Rice.Tasks.fetch_task(own["id"], ctx.owner)
        application = hd(task.applications)
        {:ok, task} = Rice.Tasks.appoint(ctx.owner, task, application.id)
        {:ok, _task} = Rice.Tasks.submit_result(ctx.applicant, task, %{body: "交付"})
        assert recipients("tasks", own["id"], "result_submitted") == [ctx.owner.id]
      end

      for task_id <- [id, own["id"]] do
        hidden =
          build_conn()
          |> authed(ctx.manager_token)
          |> get("#{path}/#{task_id}")
          |> json_response(200)

        refute hidden["data"]["can_manage"]
        refute inspect(hidden) =~ "申请人私人电话"

        assert build_conn()
               |> authed(ctx.manager_token)
               |> post("#{path}/#{task_id}/cancel")
               |> response(403)
      end

      assert build_conn()
             |> authed(ctx.applicant_token)
             |> get("#{path}/#{id}")
             |> json_response(200)
             |> get_in(["data", "my_application", "contact"]) == "申请人私人电话"
    end
  end

  defp recipients(kind, id, action \\ nil) do
    query = from n in Rice.Tasks.Notification, select: n.recipient_id

    if kind == "tasks" do
      action = action || "application_created"
      Repo.all(from n in query, where: n.task_id == ^id and n.event == ^action)
    else
      Repo.all(
        from n in query,
          where:
            n.subject_type == "event" and n.subject_id == ^id and
              n.event == "event_application_created"
      )
    end
  end

  defp role(ctx, value),
    do:
      build_conn()
      |> authed(ctx.owner_token)
      |> patch("/api/nodes/#{ctx.node.id}/members/#{ctx.manager.id}", %{role: value})
      |> json_response(200)
      |> Map.fetch!("data")

  defp get_node(token, id),
    do:
      build_conn()
      |> authed(token)
      |> get("/api/nodes/#{id}")
      |> json_response(200)
      |> Map.fetch!("data")

  defp create(kind, token, node, status \\ "open") do
    now = DateTime.utc_now()

    attrs = %{
      node_id: node.id,
      title: "共同管理",
      description: "说明",
      organizer_contact: "组织方公开电话",
      status: status,
      client_request_id: "admin-#{System.unique_integer([:positive])}"
    }

    attrs =
      if kind == "events",
        do:
          Map.merge(attrs, %{
            location: "社区",
            capacity: 3,
            fee_amount: 0,
            application_deadline: DateTime.add(now, 1800),
            starts_at: DateTime.add(now, 3600),
            ends_at: DateTime.add(now, 7200)
          }),
        else: attrs

    build_conn()
    |> authed(token)
    |> post("/api/#{kind}", attrs)
    |> json_response(201)
    |> Map.fetch!("data")
  end
end

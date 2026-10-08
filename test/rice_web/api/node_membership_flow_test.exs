defmodule RiceWeb.Api.NodeMembershipFlowTest do
  @moduledoc """
  节点身份的完整 HTTP 流程:申请入会 → 拒绝 → 再申请 → 通过 → 提为管理员 → 撤回。
  每一步都看权限真正开放和收回了什么:审批、钱包、注资、任务管理。
  """
  use RiceWeb.ConnCase, async: true

  alias Rice.Community.Node

  defp node_view(token, node_id) do
    conn = if token, do: authed(build_conn(), token), else: build_conn()
    conn |> get(~p"/api/nodes/#{node_id}") |> json_response(200) |> Map.fetch!("data")
  end

  defp my_nodes(token, mine),
    do:
      build_conn()
      |> authed(token)
      |> get(~p"/api/nodes", %{mine: mine})
      |> json_response(200)
      |> Map.fetch!("data")
      |> Enum.map(& &1["id"])

  defp join(token, node_id, reason),
    do:
      build_conn()
      |> authed(token)
      |> post(~p"/api/nodes/#{node_id}/applications", %{reason: reason})

  defp review(token, node_id, application_id, action),
    do:
      build_conn()
      |> authed(token)
      |> post("/api/nodes/#{node_id}/applications/#{application_id}/#{action}")

  defp set_role(token, node_id, user_id, role),
    do:
      build_conn()
      |> authed(token)
      |> patch(~p"/api/nodes/#{node_id}/members/#{user_id}", %{role: role})

  test "入会申请、审批、提为管理员和撤回,权限随身份实时变化" do
    owner = task_publisher_fixture(%{nickname: "节点主"})
    {:ok, owner_token} = Rice.Accounts.issue_token(owner)
    node = Rice.Repo.get_by!(Node, user_id: owner.id)
    {joiner, joiner_token} = user_with_token(%{nickname: "新人"})
    {other, other_token} = user_with_token(%{nickname: "路人"})

    # ── 申请:幂等,只有本人和节点管理员看得到 ────────────────────────
    assert my_nodes(joiner_token, "pending") == []
    assert build_conn() |> post(~p"/api/nodes/#{node.id}/applications", %{}) |> response(401)
    assert join(owner_token, node.id, "自己") |> response(409)

    applied = join(joiner_token, node.id, "想一起干活") |> json_response(200) |> Map.fetch!("data")
    application_id = applied["my_application"]["id"]
    assert applied["my_application"]["status"] == "pending"
    assert applied["role"] == nil
    # 重复申请拿到的是同一份
    assert join(joiner_token, node.id, "再申请")
           |> json_response(200)
           |> get_in(["data", "my_application", "id"]) ==
             application_id

    assert my_nodes(joiner_token, "pending") == [node.id]
    assert my_nodes(joiner_token, "joined") == []
    refute Map.has_key?(node_view(other_token, node.id), "applications")
    refute Map.has_key?(node_view(nil, node.id), "applications")

    assert [%{"id" => ^application_id, "status" => "pending"}] =
             node_view(owner_token, node.id)["applications"]

    # 路人不能审批
    assert review(other_token, node.id, application_id, "approve") |> response(403)

    # ── 拒绝后可以再申请,通过后成为成员 ──────────────────────────────
    assert review(owner_token, node.id, application_id, "reject") |> json_response(200)
    assert node_view(joiner_token, node.id)["my_application"]["status"] == "rejected"
    assert my_nodes(joiner_token, "pending") == []
    # 已拒绝的不能再通过
    assert review(owner_token, node.id, application_id, "approve") |> response(409)

    second_id =
      join(joiner_token, node.id, "再试一次")
      |> json_response(200)
      |> get_in(["data", "my_application", "id"])

    assert second_id != application_id
    assert review(owner_token, node.id, second_id, "approve") |> json_response(200)
    # 重复通过是幂等的
    assert review(owner_token, node.id, second_id, "approve") |> json_response(200)

    view = node_view(joiner_token, node.id)
    assert view["role"] == "member"
    assert Enum.any?(view["members"], &(&1["user"]["id"] == joiner.id and &1["role"] == "member"))
    assert my_nodes(joiner_token, "joined") == [node.id]
    assert my_nodes(joiner_token, "managed") == []
    # 成了成员就不能再申请
    assert join(joiner_token, node.id, "又来") |> response(409)

    # ── 普通成员没有管理权:看不了钱包、不能注资、不能审批、不能管任务 ──
    other_app =
      join(other_token, node.id, "我也来")
      |> json_response(200)
      |> get_in(["data", "my_application", "id"])

    assert review(joiner_token, node.id, other_app, "approve") |> response(403)

    assert build_conn()
           |> authed(joiner_token)
           |> get(~p"/api/nodes/#{node.id}/wallet")
           |> response(403)

    {:ok, _} = Rice.Grains.grant(joiner, 50)

    assert build_conn()
           |> authed(joiner_token)
           |> post(~p"/api/nodes/#{node.id}/fund", %{amount: 20, client_request_id: "m-1"})
           |> response(403)

    task =
      build_conn()
      |> authed(owner_token)
      |> post(~p"/api/tasks", %{
        client_request_id: "node-task",
        title: "搬桌子",
        description: "搬",
        organizer_contact: "服务台"
      })
      |> json_response(201)
      |> Map.fetch!("data")

    task_app =
      build_conn()
      |> authed(other_token)
      |> post(~p"/api/tasks/#{task["id"]}/applications", %{contact: "微信"})
      |> json_response(201)
      |> get_in(["data", "my_application", "id"])

    refute build_conn()
           |> authed(joiner_token)
           |> get(~p"/api/tasks/#{task["id"]}")
           |> json_response(200)
           |> get_in(["data", "can_manage"])

    assert build_conn()
           |> authed(joiner_token)
           |> post(~p"/api/tasks/#{task["id"]}/applications/#{task_app}/appoint")
           |> response(403)

    # ── 提为管理员:只有节点主能提,提了之后上面这些都能做 ─────────────
    assert set_role(joiner_token, node.id, other.id, "admin") |> response(403)

    assert set_role(owner_token, node.id, joiner.id, "admin")
           |> json_response(200)
           |> get_in(["data", "role"]) == "admin"

    assert my_nodes(joiner_token, "managed") == [node.id]
    assert review(joiner_token, node.id, other_app, "approve") |> json_response(200)
    assert node_view(other_token, node.id)["role"] == "member"

    assert build_conn()
           |> authed(joiner_token)
           |> post(~p"/api/nodes/#{node.id}/fund", %{amount: 20, client_request_id: "m-1"})
           |> json_response(200)
           |> get_in(["data", "balance"]) == 20

    assert build_conn()
           |> authed(joiner_token)
           |> get(~p"/api/nodes/#{node.id}/wallet")
           |> json_response(200)

    assert build_conn()
           |> authed(joiner_token)
           |> post(~p"/api/tasks/#{task["id"]}/applications/#{task_app}/appoint")
           |> json_response(200)
           |> get_in(["data", "status"]) == "in_progress"

    # 管理员也不能提拔别人,更不能动节点主
    assert set_role(joiner_token, node.id, other.id, "admin") |> response(403)
    assert set_role(owner_token, node.id, owner.id, "member") |> response(403)
    assert Enum.sort(Rice.Community.admin_ids(node)) == Enum.sort([owner.id, joiner.id])

    # ── 撤回:立即失去管理权,成员身份保留 ─────────────────────────────
    assert set_role(owner_token, node.id, joiner.id, "member") |> json_response(200)
    assert node_view(joiner_token, node.id)["role"] == "member"
    assert my_nodes(joiner_token, "managed") == []
    assert my_nodes(joiner_token, "joined") == [node.id]

    assert build_conn()
           |> authed(joiner_token)
           |> get(~p"/api/nodes/#{node.id}/wallet")
           |> response(403)

    assert Rice.Community.admin_ids(node) == [owner.id]
    assert Rice.Grains.reconcile().ok?
  end
end

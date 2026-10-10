defmodule RiceWeb.Api.CommunityWalletTest do
  use RiceWeb.ConnCase, async: true
  alias Rice.Grains

  test "社区账户独立，谁都能转入且幂等，错误金额不改写" do
    {owner, token} = user_with_token()
    {_other, other_token} = user_with_token()
    node = node_fixture(%{user_id: owner.id})
    {:ok, _} = Grains.grant(owner, 100)
    path = "/api/nodes/#{node.id}/fund"
    request = %{amount: 40, client_request_id: "once"}

    assert build_conn() |> get("/api/nodes/#{node.id}/wallet") |> json_response(401)

    assert build_conn()
           |> authed(other_token)
           |> get("/api/nodes/#{node.id}/wallet")
           |> json_response(403)

    # 不是管理员也能转入,只是自己没稻米
    assert build_conn() |> authed(other_token) |> post(path, request) |> json_response(422)

    for invalid <- [-1, 1.5, "1.5", 0, 1_000_000_000, 9_223_372_036_854_775_808] do
      assert build_conn()
             |> authed(token)
             |> post(path, %{request | amount: invalid})
             |> json_response(422)
    end

    assert Grains.wallet(node).balance == 0
    assert Grains.wallet(owner).balance == 100

    for _ <- 1..2 do
      result = build_conn() |> authed(token) |> post(path, request) |> json_response(201)
      assert result["data"]["amount"] == 40
    end

    assert build_conn()
           |> authed(token)
           |> post(path, %{request | amount: 41})
           |> json_response(409)

    assert build_conn()
           |> authed(token)
           |> post(path, %{amount: 61, client_request_id: "too-much"})
           |> json_response(422)

    assert Grains.wallet(owner).balance == 60
    assert Grains.wallet(node).balance == 40
    assert [%{kind: "community_fund", to_node: %{id: node_id}} | _] = Grains.wallet(owner).entries
    assert node_id == node.id
    assert Grains.reconcile().ok?
  end

  test "节点管理员从节点账户发放稻米，可安全重试，别人发不了" do
    {owner, token} = user_with_token()
    {other, other_token} = user_with_token()
    node = node_fixture(%{user_id: owner.id})
    {:ok, _} = Grains.grant(other, 30)
    path = "/api/nodes/#{node.id}/fund"

    # 普通成员向节点转入 30
    build_conn()
    |> authed(other_token)
    |> post(path, %{amount: 30, client_request_id: "in"})
    |> json_response(201)

    send = "/api/nodes/#{node.id}/grain_transfers"
    request = %{to: other.handle, amount: 12, memo: "辛苦了", client_request_id: "out"}

    assert build_conn() |> authed(other_token) |> post(send, request) |> json_response(403)

    for invalid <- [0, -1, "12", 1.5] do
      assert build_conn()
             |> authed(token)
             |> post(send, %{request | amount: invalid})
             |> json_response(422)
    end

    for _ <- 1..2 do
      result = build_conn() |> authed(token) |> post(send, request) |> json_response(201)
      assert %{"amount" => 12, "kind" => "gift", "memo" => "辛苦了"} = result["data"]
      assert result["data"]["from_node"]["id"] == node.id
      assert result["data"]["to"]["handle"] == other.handle
    end

    assert build_conn()
           |> authed(token)
           |> post(send, %{request | amount: 13})
           |> json_response(409)

    assert build_conn()
           |> authed(token)
           |> post(send, %{request | amount: 19, client_request_id: "too-much"})
           |> json_response(422)

    assert Grains.wallet(node).balance == 18
    assert Grains.wallet(other).balance == 12
    assert [%{kind: "gift", from_node: %{id: node_id}} | _] = Grains.wallet(other).entries
    assert node_id == node.id
    assert Grains.reconcile().ok?
  end
end

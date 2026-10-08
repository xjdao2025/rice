defmodule RiceWeb.Api.CommunityWalletTest do
  use RiceWeb.ConnCase, async: true
  alias Rice.Grains

  test "社区账户独立，转入要授权且幂等，错误金额不改写" do
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

    assert build_conn() |> authed(other_token) |> post(path, request) |> json_response(403)

    for invalid <- [-1, 1.5, "1.5", 0, 1_000_000_000, 9_223_372_036_854_775_808] do
      assert build_conn()
             |> authed(token)
             |> post(path, %{request | amount: invalid})
             |> json_response(422)
    end

    assert Grains.wallet(node).balance == 0
    assert Grains.wallet(owner).balance == 100

    for _ <- 1..2 do
      result = build_conn() |> authed(token) |> post(path, request) |> json_response(200)
      assert result["data"]["balance"] == 40
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
end

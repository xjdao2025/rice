defmodule RiceWeb.Api.Admin.NodeGrainControllerTest do
  use RiceWeb.ConnCase, async: true

  import Ecto.Query

  alias Rice.Accounts.VerificationCode
  alias Rice.Community.Node
  alias Rice.Grains.Transfer
  alias Rice.Repo

  setup do
    {admin, token} = admin_with_token()
    code = VerificationCode.generate_code()

    Repo.insert!(
      VerificationCode.build(
        "sms",
        Rice.Accounts.phone_target(admin.phone_region, admin.phone),
        "admin_grant",
        code
      )
    )

    owner = user_fixture()
    node = node_fixture(%{user_id: owner.id})
    %{admin: admin, token: token, code: code, owner: owner, node: node}
  end

  defp grant(conn, token, node_id, params) do
    conn
    |> authed(token)
    |> post("/api/admin/nodes/#{node_id}/grain_grants", params)
  end

  defp attrs(code, overrides \\ %{}) do
    Map.merge(
      %{amount: 75, memo: "节点启动资金", client_request_id: "grant-001", code: code},
      overrides
    )
  end

  test "节点发放直接进入节点钱包和节点流水，个人余额不变", %{
    conn: conn,
    token: token,
    code: code,
    owner: owner,
    node: node
  } do
    assert %{
             "data" => %{
               "id" => id,
               "amount" => 75,
               "to_node_id" => node_id,
               "replayed" => false
             }
           } = conn |> grant(token, node.id, attrs(code)) |> json_response(201)

    assert node_id == node.id
    assert Repo.get!(Node, node.id).grain_balance == 75
    assert Repo.get!(Rice.Accounts.User, owner.id).grain_balance == 0

    transfer = Repo.get!(Transfer, id)
    assert transfer.kind == "grant"
    assert transfer.amount == 75
    assert transfer.to_node_id == node.id
    assert is_nil(transfer.to_user_id)
    assert is_nil(transfer.from_user_id)
    assert is_nil(transfer.from_node_id)
    assert Rice.Grains.reconcile().ok?

    assert %{"data" => node_detail} =
             conn
             |> authed(token)
             |> get("/api/admin/nodes/#{node.id}")
             |> json_response(200)

    assert node_detail["grain_balance"] == 75
    assert node_detail["grain_frozen_balance"] == 0
    assert node_detail["owner"]["grain_balance"] == 0

    {:ok, owner_token} = Rice.Accounts.issue_token(owner)

    assert %{"data" => %{"balance" => 75, "frozen" => 0, "earned" => 75}} =
             conn
             |> authed(owner_token)
             |> get("/api/nodes/#{node.id}/wallet")
             |> json_response(200)

    assert %{"data" => [listed]} =
             conn |> authed(token) |> get(~p"/api/admin/grain_grants") |> json_response(200)

    assert listed["id"] == id
    assert listed["to"] == nil
    assert listed["to_node"] == %{"id" => node.id, "name" => node.name}

    assert %{"data" => [%{"id" => ^id, "to_node" => %{"id" => ^node_id}}]} =
             conn |> get(~p"/api/grain_grants") |> json_response(200)

    assert %{"data" => [%{"id" => ^id}]} =
             conn
             |> authed(token)
             |> get("/api/admin/grain_grants?q=#{URI.encode_www_form(node.name)}")
             |> json_response(200)

    assert %{"data" => [%{"id" => ^id}]} =
             conn
             |> authed(token)
             |> get("/api/admin/grain_grants?q=#{node.id}")
             |> json_response(200)
  end

  test "同一请求重试不重复入账，变更金额或备注会冲突", %{
    conn: conn,
    token: token,
    code: code,
    node: node
  } do
    assert %{"data" => %{"id" => id}} =
             conn |> grant(token, node.id, attrs(code)) |> json_response(201)

    # 首次发放已经消费验证码；重试凭同一请求标识返回原流水。
    assert %{"data" => %{"id" => ^id, "replayed" => true}} =
             conn |> grant(token, node.id, Map.delete(attrs(code), :code)) |> json_response(200)

    assert conn
           |> grant(token, node.id, attrs(code, %{amount: 76}))
           |> json_response(409)

    assert conn
           |> grant(token, node.id, attrs(code, %{memo: "另一个备注"}))
           |> json_response(409)

    assert Repo.get!(Node, node.id).grain_balance == 75
    assert Repo.aggregate(from(t in Transfer, where: t.to_node_id == ^node.id), :count, :id) == 1
  end

  test "同一验证码不能给另一个请求发放", %{
    conn: conn,
    token: token,
    code: code,
    node: node
  } do
    assert conn |> grant(token, node.id, attrs(code)) |> json_response(201)

    assert %{"errors" => %{"code" => [_]}} =
             conn
             |> grant(token, node.id, attrs(code, %{client_request_id: "grant-002"}))
             |> json_response(422)

    assert Repo.get!(Node, node.id).grain_balance == 75
    assert Repo.aggregate(from(t in Transfer, where: t.to_node_id == ^node.id), :count, :id) == 1
  end

  test "金额、请求标识和节点先校验，错误不消耗验证码", %{
    conn: conn,
    token: token,
    code: code,
    node: node
  } do
    for bad_amount <- [0, -1, "75", nil, 9_223_372_036_854_775_808] do
      assert conn
             |> grant(token, node.id, attrs(code, %{amount: bad_amount}))
             |> json_response(422)
    end

    for bad_id <- [nil, "", "  ", String.duplicate("x", 129)] do
      assert %{"errors" => %{"client_request_id" => [_]}} =
               conn
               |> grant(token, node.id, attrs(code, %{client_request_id: bad_id}))
               |> json_response(422)
    end

    assert conn
           |> grant(token, node.id, attrs(code, %{memo: String.duplicate("字", 257)}))
           |> json_response(422)

    assert conn |> grant(token, Rice.Tsid.generate(), attrs(code)) |> json_response(404)
    assert conn |> grant(token, "bad-id", attrs(code)) |> json_response(404)
    assert Repo.get!(Node, node.id).grain_balance == 0

    assert conn |> grant(token, node.id, attrs(code)) |> json_response(201)
    assert Repo.get!(Node, node.id).grain_balance == 75
  end

  test "验证码错误不会产生流水或余额，但会累计错误尝试", %{
    conn: conn,
    token: token,
    admin: admin,
    code: code,
    node: node
  } do
    wrong_code = if code == "000000", do: "111111", else: "000000"

    assert %{"errors" => %{"code" => [_]}} =
             conn |> grant(token, node.id, attrs(wrong_code)) |> json_response(422)

    assert Repo.get!(Node, node.id).grain_balance == 0
    assert Repo.aggregate(from(t in Transfer, where: t.to_node_id == ^node.id), :count, :id) == 0

    target = Rice.Accounts.phone_target(admin.phone_region, admin.phone)

    verification =
      Repo.one!(
        from v in VerificationCode,
          where: v.target == ^target and v.purpose == "admin_grant",
          order_by: [desc: v.id],
          limit: 1
      )

    assert verification.attempts == 1
  end

  test "非管理员无法发放", %{conn: conn, code: code, node: node} do
    assert conn
           |> post("/api/admin/nodes/#{node.id}/grain_grants", attrs(code))
           |> json_response(401)

    assert Repo.get!(Node, node.id).grain_balance == 0
  end
end

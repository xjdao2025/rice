defmodule RiceWeb.Api.EventControllerTest do
  use RiceWeb.ConnCase, async: true
  alias Rice.{Events, Repo}

  test "API 提供真实候选管理、私人申请和本人回访", %{conn: conn} do
    {host, host_token} = user_with_token()
    {first, first_token} = user_with_token()
    {second, second_token} = user_with_token()
    node = node_fixture(%{user_id: host.id})
    for user <- [first, second], do: Rice.Grains.grant(user, 50)
    now = DateTime.utc_now()

    attrs = %{
      organizer_contact: "社区服务台",
      node_id: node.id,
      title: "公共客厅修理",
      description: "一起修好木凳",
      location: "公共客厅",
      fee_amount: 20,
      capacity: 1,
      client_request_id: "publish-#{System.unique_integer([:positive])}",
      application_deadline: DateTime.add(now, 1800),
      starts_at: DateTime.add(now, 3600),
      ends_at: DateTime.add(now, 7200)
    }

    assert build_conn() |> post(~p"/api/events", attrs) |> json_response(401)

    assert build_conn()
           |> authed(first_token)
           |> post(~p"/api/events", attrs)
           |> json_response(403)

    created = conn |> authed(host_token) |> post(~p"/api/events", attrs) |> json_response(201)
    id = created["data"]["id"]
    assert created["data"]["node"]["id"] == node.id
    assert created["data"]["creator"]["id"] == host.id

    first_result =
      build_conn()
      |> authed(first_token)
      |> post(~p"/api/events/#{id}/applications", %{contact: "测试联系方式", reason: "第一位的私人申请"})
      |> json_response(200)

    a_id = first_result["data"]["my_application"]["id"]
    assert first_result["data"]["my_application"]["status"] == "pending"

    second_result =
      build_conn()
      |> authed(second_token)
      |> post(~p"/api/events/#{id}/applications", %{contact: "测试联系方式", reason: "第二位的私人申请"})
      |> json_response(200)

    b_id = second_result["data"]["my_application"]["id"]
    assert second_result["data"]["application_count"] == 2

    public = build_conn() |> get(~p"/api/events/#{id}") |> json_response(200)
    assert public["data"]["applications"] == []
    refute inspect(public) =~ "私人申请"
    refute Enum.any?(public["data"]["history"], &(&1["action"] == "applied"))
    mine = build_conn() |> authed(first_token) |> get(~p"/api/events/#{id}") |> json_response(200)
    assert length(mine["data"]["applications"]) == 1
    assert Enum.count(mine["data"]["history"], &(&1["action"] == "applied")) == 1
    refute Enum.any?(mine["data"]["history"], &(&1["actor"] && &1["actor"]["id"] == second.id))

    assert build_conn()
           |> authed(second_token)
           |> post(~p"/api/events/#{id}/applications/#{a_id}/approve")
           |> json_response(403)

    approved =
      build_conn()
      |> authed(host_token)
      |> post(~p"/api/events/#{id}/applications/#{a_id}/approve")
      |> json_response(200)

    assert approved["data"]["approved_count"] == 1

    {late, late_token} = user_with_token()
    {:ok, _} = Rice.Grains.grant(late, 100)
    full = build_conn() |> authed(late_token) |> get(~p"/api/events/#{id}") |> json_response(200)
    refute "apply" in full["data"]["allowed_actions"]

    listed = build_conn() |> authed(late_token) |> get(~p"/api/events") |> json_response(200)
    refute "apply" in hd(listed["data"])["allowed_actions"]

    denied =
      build_conn()
      |> authed(late_token)
      |> post(~p"/api/events/#{id}/applications", %{contact: "测试联系方式"})
      |> json_response(409)

    assert denied["errors"]["detail"] == "活动已满，暂无可用名额"
    assert Repo.get!(Rice.Accounts.User, late.id).grain_balance == 100
    assert Repo.get!(Rice.Accounts.User, late.id).grain_frozen_balance == 0
    refute Repo.get_by(Rice.Events.Application, event_id: id, user_id: late.id)

    pending =
      build_conn() |> authed(second_token) |> get(~p"/api/events/#{id}") |> json_response(200)

    assert pending["data"]["my_application"]["allowed_actions"] == ["withdraw"]

    assert %{"data" => [%{"id" => ^id}]} =
             build_conn()
             |> get("/api/events", %{participant_did: first.did})
             |> json_response(200)

    assert %{"data" => []} =
             build_conn()
             |> get("/api/events", %{participant_did: second.did})
             |> json_response(200)

    assert %{"data" => [%{"id" => ^id}]} =
             build_conn() |> get("/api/events", %{creator_did: host.did}) |> json_response(200)

    assert build_conn()
           |> authed(host_token)
           |> post(~p"/api/events/#{id}/applications/#{b_id}/approve")
           |> json_response(409)

    revisited =
      build_conn()
      |> authed(first_token)
      |> get(~p"/api/events?mine=applied")
      |> json_response(200)

    assert hd(revisited["data"])["my_application"]["status"] == "approved"
    assert {:ok, event} = Events.fetch_event(id, host)
    assert {:ok, _} = Events.cancel(host, event)
    assert Repo.get!(Rice.Accounts.User, first.id).grain_balance == 50
    assert Repo.get!(Rice.Accounts.User, second.id).grain_balance == 50
  end

  test "本人撤销API返回完整活动，隐藏撤销入口并保留私人退款结果" do
    {host, _host_token} = user_with_token()
    {applicant, applicant_token} = user_with_token()
    {_other, other_token} = user_with_token()
    node = node_fixture(%{user_id: host.id})
    {:ok, _} = Rice.Grains.grant(applicant, 50)
    now = DateTime.utc_now()

    {:ok, event} =
      Events.create_event(host, %{
        organizer_contact: "社区服务台",
        node_id: node.id,
        title: "撤销申请API验收",
        client_request_id: "withdraw-api-#{System.unique_integer([:positive])}",
        description: "保留申请历史",
        location: "社区",
        fee_amount: 20,
        capacity: 1,
        application_deadline: DateTime.add(now, 1800),
        starts_at: DateTime.add(now, 3600),
        ends_at: DateTime.add(now, 7200)
      })

    applied =
      build_conn()
      |> authed(applicant_token)
      |> post(~p"/api/events/#{event.id}/applications", %{contact: "测试联系方式", reason: "私人申请理由"})
      |> json_response(200)

    own = applied["data"]["my_application"]
    assert own["allowed_actions"] == ["withdraw"]
    path = ~p"/api/events/#{event.id}/applications/#{own["id"]}/withdraw"
    assert build_conn() |> post(path, %{}) |> json_response(401)
    assert build_conn() |> authed(other_token) |> post(path, %{}) |> json_response(403)

    withdrawn = build_conn() |> authed(applicant_token) |> post(path, %{}) |> json_response(200)
    assert withdrawn["data"]["id"] == event.id
    assert withdrawn["data"]["status"] == "open"
    assert withdrawn["data"]["approved_count"] == 0
    assert withdrawn["data"]["my_application"]["status"] == "withdrawn"
    assert withdrawn["data"]["my_application"]["payment_status"] == "refunded"
    assert withdrawn["data"]["my_application"]["allowed_actions"] == []
    refute "apply" in withdrawn["data"]["allowed_actions"]

    revisited =
      build_conn()
      |> authed(applicant_token)
      |> get(~p"/api/events?mine=applied")
      |> json_response(200)

    assert hd(revisited["data"])["my_application"]["status"] == "withdrawn"
    public = build_conn() |> get(~p"/api/events/#{event.id}") |> json_response(200)
    assert public["data"]["my_application"] == nil
    assert public["data"]["applications"] == []
    refute Enum.any?(public["data"]["history"], &(&1["action"] == "application_withdrawn"))
    refute inspect(public) =~ "私人申请理由"
  end

  test "非法输入返回错误，草稿仅本人可见" do
    {host, token} = user_with_token()
    node = node_fixture(%{user_id: host.id})
    now = DateTime.utc_now()

    attrs = %{
      organizer_contact: "社区服务台",
      node_id: node.id,
      title: "草稿",
      description: "描述",
      location: "地点",
      status: "draft",
      capacity: 1,
      application_deadline: DateTime.add(now, 120),
      starts_at: DateTime.add(now, 120),
      ends_at: DateTime.add(now, 180)
    }

    for {field, value} <- [
          title: nil,
          application_deadline: DateTime.add(now, -1),
          application_deadline: DateTime.add(now, 121),
          ends_at: attrs.starts_at
        ] do
      rejected =
        build_conn()
        |> authed(token)
        |> post(~p"/api/events", Map.put(attrs, field, value))
        |> json_response(422)

      assert Map.has_key?(rejected["errors"], Atom.to_string(field))
    end

    created = build_conn() |> authed(token) |> post(~p"/api/events", attrs) |> json_response(201)
    id = created["data"]["id"]
    assert build_conn() |> get(~p"/api/events/#{id}") |> json_response(404)
    assert %{"data" => []} = build_conn() |> get(~p"/api/events") |> json_response(200)

    assert %{"data" => [%{"id" => ^id}]} =
             build_conn()
             |> authed(token)
             |> get(~p"/api/events?mine=created&status=draft")
             |> json_response(200)

    assert build_conn() |> get(~p"/api/events/not-an-id") |> json_response(404)
  end
end

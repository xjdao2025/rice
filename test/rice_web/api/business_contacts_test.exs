defmodule RiceWeb.Api.BusinessContactsTest do
  use RiceWeb.ConnCase, async: true

  for kind <- ["tasks", "events"] do
    @kind kind

    test "#{kind}: 发布必填联系方式，草稿可暂不填写，补齐后发布" do
      {host, token} = user_with_token()
      node = node_fixture(%{user_id: host.id})
      attrs = attrs(@kind, node)
      path = "/api/#{@kind}"

      for contact <- [nil, "  ", String.duplicate("联", 257)] do
        response =
          build_conn()
          |> authed(token)
          |> post(path, Map.put(attrs, :organizer_contact, contact))
          |> json_response(422)

        assert response["errors"]["organizer_contact"]
      end

      draft =
        build_conn()
        |> authed(token)
        |> post(path, Map.put(attrs, :status, "draft"))
        |> json_response(201)
        |> Map.fetch!("data")

      assert is_nil(draft["organizer_contact"])
      id = draft["id"]

      assert build_conn()
             |> authed(token)
             |> post("#{path}/#{id}/publish")
             |> json_response(422)
             |> get_in(["errors", "organizer_contact"])

      build_conn()
      |> authed(token)
      |> patch("#{path}/#{id}", %{organizer_contact: "  社区电话 123  "})
      |> json_response(200)

      published =
        build_conn()
        |> authed(token)
        |> post("#{path}/#{id}/publish")
        |> json_response(200)

      assert published["data"]["status"] == "open"
      assert published["data"]["organizer_contact"] == "社区电话 123"
      public = build_conn() |> get("#{path}/#{id}") |> json_response(200)
      assert public["data"]["organizer_contact"] == "社区电话 123"

      # Deployed rows have no contact to backfill; they must remain readable.
      schema = if @kind == "tasks", do: Rice.Tasks.Task, else: Rice.Events.Event

      schema
      |> Rice.Repo.get!(id)
      |> Ecto.Changeset.change(organizer_contact: nil)
      |> Rice.Repo.update!()

      legacy = build_conn() |> get("#{path}/#{id}") |> json_response(200)
      assert is_nil(legacy["data"]["organizer_contact"])
    end

    test "#{kind}: 申请联系方式仅组织方与本人详情可见，不进入公开或列表响应" do
      {host, host_token} = user_with_token()
      {_first, first_token} = user_with_token()
      {_other, other_token} = user_with_token()
      node = node_fixture(%{user_id: host.id})
      path = "/api/#{@kind}"
      attrs = Map.put(attrs(@kind, node), :organizer_contact, "公开服务台")

      created = build_conn() |> authed(host_token) |> post(path, attrs) |> json_response(201)
      id = created["data"]["id"]
      apply_path = "#{path}/#{id}/applications"
      success = if @kind == "tasks", do: 201, else: 200

      for contact <- [nil, " ", String.duplicate("联", 257)] do
        invalid =
          build_conn()
          |> authed(first_token)
          |> post(apply_path, %{contact: contact})
          |> json_response(422)

        assert invalid["errors"]["contact"]
      end

      result =
        build_conn()
        |> authed(first_token)
        |> post(apply_path, %{contact: "  私人联系方式甲  "})
        |> json_response(success)

      assert result["data"]["my_application"]["contact"] == "私人联系方式甲"
      assert result["data"]["application_count"] == 1

      repeated =
        build_conn() |> authed(first_token) |> post(apply_path, %{}) |> json_response(success)

      assert repeated["data"]["my_application"]["contact"] == "私人联系方式甲"
      host_view = build_conn() |> authed(host_token) |> get("#{path}/#{id}") |> json_response(200)
      assert hd(host_view["data"]["applications"])["contact"] == "私人联系方式甲"

      for token <- [nil, other_token], route <- [path, "#{path}/#{id}"] do
        conn = if token, do: authed(build_conn(), token), else: build_conn()
        response = conn |> get(route) |> json_response(200)
        refute inspect(response) =~ "私人联系方式甲"
      end

      for token <- [host_token, first_token] do
        response = build_conn() |> authed(token) |> get(path) |> json_response(200)
        refute inspect(response) =~ "私人联系方式甲"
      end
    end
  end

  defp attrs(kind, node) do
    now = DateTime.utc_now()

    base = %{
      node_id: node.id,
      title: "联系方式验收",
      description: "公开内容",
      client_request_id: "contact-#{System.unique_integer([:positive])}"
    }

    if kind == "tasks" do
      base
    else
      Map.merge(base, %{
        location: "社区",
        capacity: 3,
        fee_amount: 0,
        application_deadline: DateTime.add(now, 1800),
        starts_at: DateTime.add(now, 3600),
        ends_at: DateTime.add(now, 7200)
      })
    end
  end
end

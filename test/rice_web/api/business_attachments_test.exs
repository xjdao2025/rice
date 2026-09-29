defmodule RiceWeb.Api.BusinessAttachmentsTest do
  use RiceWeb.ConnCase, async: true
  import Mox
  alias Rice.Repo
  alias Rice.Files.Attachment

  setup :verify_on_exit!

  test "上传图片归属由登录身份决定，客户端不能指定其他人" do
    {owner, token} = user_with_token()
    other = user_fixture()
    image = upload(token, "image", %{user_id: other.id})
    assert Repo.get!(Attachment, image["id"]).user_id == owner.id
    refute Map.has_key?(image, "user_id")
    refute Map.has_key?(image, "storage_key")
    expect(Rice.Files.StorageMock, :get, fn _key -> {:ok, "IMAGE"} end)
    assert build_conn() |> get(image["url"]) |> response(200) == "IMAGE"
  end

  for resource <- ~w(tasks events) do
    @resource resource

    test "#{resource} 草稿图片有序保存、替换、移除，并随发布公开返回" do
      {host, token} = user_with_token()
      node = node_fixture(%{user_id: host.id})
      first = upload(token)
      second = upload(token)
      extra = for _ <- 1..7, do: upload(token)
      ids = [second["id"], first["id"] | Enum.map(extra, & &1["id"])]
      attrs = attrs(@resource, node, "draft") |> Map.put(:attachment_ids, ids)
      created = create(@resource, token, attrs)
      id = created["id"]
      path = "/api/#{@resource}/#{id}"
      assert image_ids(created) == ids
      assert build_conn() |> get(path) |> json_response(404)

      revisited = build_conn() |> authed(token) |> get(path) |> json_response(200)
      assert image_ids(revisited["data"]) == ids

      # A request retried after a lost response retains the first complete result.
      retried = create(@resource, token, Map.put(attrs, :attachment_ids, []))
      assert retried["id"] == id
      assert image_ids(retried) == ids

      assert image_ids(update(path, token, %{description: "修改后的正文"})) == ids
      reordered = update(path, token, %{attachment_ids: Enum.reverse(ids)})
      assert image_ids(reordered) == Enum.reverse(ids)
      assert image_ids(update(path, token, %{attachment_ids: []})) == []
      assert Repo.get!(Attachment, first["id"])
      assert Repo.get!(Attachment, second["id"])

      assert image_ids(update(path, token, %{attachment_ids: ids})) == ids
      published = build_conn() |> authed(token) |> post(path <> "/publish") |> json_response(200)
      assert image_ids(published["data"]) == ids

      for public_path <- [path, "/api/#{@resource}"] do
        public = build_conn() |> get(public_path) |> json_response(200)
        data = if is_list(public["data"]), do: hd(public["data"]), else: public["data"]
        assert image_ids(data) == ids
        assert hd(data["attachments"])["url"] == second["url"]
        refute inspect(data["attachments"]) =~ "storage_key"
        refute inspect(data["attachments"]) =~ "user_id"
      end

      edited = update(path, token, %{attachment_ids: []})
      assert image_ids(edited) == []

      history = edited[if(@resource == "tasks", do: "events", else: "history")]
      assert List.last(history)["before"]["attachment_ids"] == ids
      assert List.last(history)["after"]["attachment_ids"] == []
    end

    test "#{resource} 拒绝他人、非图片、无文件、无效、重复及超过九张的附件且保存原子化" do
      {host, token} = user_with_token()
      {_other, other_token} = user_with_token()
      node = node_fixture(%{user_id: host.id})
      image = upload(token)
      foreign = upload(other_token)
      document = upload(token, "file")
      extra = for _ <- 1..9, do: upload(token)

      unstored =
        Repo.insert!(%Attachment{kind: "image", filename: "missing.png", user_id: host.id})

      invalid = [
        [foreign["id"]],
        [document["id"]],
        [unstored.id],
        [Rice.Tsid.generate()],
        ["bad-id"],
        [123],
        nil,
        "not-a-list",
        [image["id"], image["id"]],
        [image["id"] | Enum.map(extra, & &1["id"])]
      ]

      for ids <- invalid do
        result =
          build_conn()
          |> authed(token)
          |> post(
            "/api/#{@resource}",
            Map.put(attrs(@resource, node, "draft"), :attachment_ids, ids)
          )
          |> json_response(422)

        assert result["errors"]["attachment_ids"]
      end

      created =
        create(
          @resource,
          token,
          Map.put(attrs(@resource, node, "draft"), :attachment_ids, [image["id"]])
        )

      path = "/api/#{@resource}/#{created["id"]}"

      assert build_conn()
             |> authed(token)
             |> patch(path, %{description: "不能留下这次修改", attachment_ids: [foreign["id"]]})
             |> json_response(422)

      current = build_conn() |> authed(token) |> get(path) |> json_response(200)
      assert current["data"]["description"] == created["description"]
      assert image_ids(current["data"]) == [image["id"]]
    end

    test "#{resource} 直接发布支持图片，旧客户端省略字段仍返回空数组" do
      {host, token} = user_with_token()
      node = node_fixture(%{user_id: host.id})
      image = upload(token)

      with_image =
        create(
          @resource,
          token,
          Map.put(attrs(@resource, node, "open"), :attachment_ids, [image["id"]])
        )

      assert image_ids(with_image) == [image["id"]]
      assert image_ids(create(@resource, token, attrs(@resource, node, "open"))) == []
    end

    test "#{resource} 共同管理员编辑可保留原图并添加本人图片，不能引用未关联的他人图片" do
      {host, host_token} = user_with_token()
      {editor, editor_token} = user_with_token()
      {_outsider, outsider_token} = user_with_token()
      node = node_fixture(%{user_id: host.id})

      Repo.insert!(
        Rice.Community.Membership.changeset(%Rice.Community.Membership{
          node_id: node.id,
          user_id: editor.id,
          role: "admin"
        })
      )

      original = upload(host_token)
      unlinked_host = upload(host_token)
      editor_image = upload(editor_token)
      unlinked_editor = upload(editor_token)
      foreign = upload(outsider_token)

      created =
        create(
          @resource,
          host_token,
          Map.put(attrs(@resource, node, "open"), :attachment_ids, [original["id"]])
        )

      path = "/api/#{@resource}/#{created["id"]}"

      edited =
        update(path, editor_token, %{attachment_ids: [original["id"], editor_image["id"]]})

      assert image_ids(edited) == [original["id"], editor_image["id"]]
      history = edited[if(@resource == "tasks", do: "events", else: "history")] |> List.last()
      assert history["actor"]["id"] == editor.id
      assert history["after"]["attachment_ids"] == [original["id"], editor_image["id"]]

      for id <- [unlinked_host["id"], foreign["id"]] do
        assert build_conn()
               |> authed(editor_token)
               |> patch(path, %{creator_id: host.id, attachment_ids: [original["id"], id]})
               |> json_response(422)
               |> get_in(["errors", "attachment_ids"])
      end

      assert image_ids(
               update(path, host_token, %{attachment_ids: [editor_image["id"], original["id"]]})
             ) ==
               [editor_image["id"], original["id"]]

      assert build_conn()
             |> authed(host_token)
             |> patch(path, %{attachment_ids: [editor_image["id"], unlinked_editor["id"]]})
             |> json_response(422)

      current = build_conn() |> get(path) |> json_response(200) |> Map.fetch!("data")
      assert image_ids(current) == [editor_image["id"], original["id"]]

      draft = create(@resource, host_token, attrs(@resource, node, "draft"))

      assert build_conn()
             |> authed(editor_token)
             |> patch("/api/#{@resource}/#{draft["id"]}", %{attachment_ids: [editor_image["id"]]})
             |> json_response(404)
    end
  end

  defp create(resource, token, attrs),
    do:
      build_conn()
      |> authed(token)
      |> post("/api/#{resource}", attrs)
      |> json_response(201)
      |> Map.fetch!("data")

  defp update(path, token, attrs),
    do:
      build_conn()
      |> authed(token)
      |> patch(path, attrs)
      |> json_response(200)
      |> Map.fetch!("data")

  defp image_ids(data), do: Enum.map(data["attachments"], & &1["id"])

  defp upload(token, kind \\ "image", params \\ %{}) do
    path = Path.join(System.tmp_dir!(), "business-image-#{System.unique_integer([:positive])}")
    File.write!(path, "IMAGE")
    on_exit(fn -> File.rm(path) end)
    expect(Rice.Files.StorageMock, :put, fn _key, "IMAGE" -> :ok end)

    upload = %Plug.Upload{
      path: path,
      filename: if(kind == "image", do: "社区图片.png", else: "document.pdf"),
      content_type: if(kind == "image", do: "image/png", else: "application/pdf")
    }

    build_conn()
    |> authed(token)
    |> post("/api/attachments", Map.merge(params, %{file: upload, kind: kind}))
    |> json_response(201)
    |> Map.fetch!("data")
  end

  defp attrs(resource, node, status) do
    common = %{
      node_id: node.id,
      title: "社区协作",
      description: "正文与图片",
      organizer_contact: "社区服务台",
      status: status,
      client_request_id: "images-#{System.unique_integer([:positive])}"
    }

    if resource == "events" do
      now = DateTime.utc_now()

      Map.merge(common, %{
        location: "公共客厅",
        capacity: 3,
        application_deadline: DateTime.add(now, 600),
        starts_at: DateTime.add(now, 1200),
        ends_at: DateTime.add(now, 1800)
      })
    else
      common
    end
  end
end

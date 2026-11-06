defmodule Rice.Moderation.PostHttpTest do
  use ExUnit.Case, async: false

  setup do
    old = Application.get_env(:rice, :labeler)
    options = Req.default_options()

    Application.put_env(:rice, :labeler,
      url: "https://labeler.test",
      appview_url: "https://appview.test",
      admin_password: "test-only"
    )

    Req.default_options(plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:rice, :labeler, old || [])
      Req.default_options(options)
    end)
  end

  test "包含评论的查询走公开 AppView，不发送管理端 Basic 凭据" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "appview.test"
      assert conn.request_path == "/xrpc/app.bsky.feed.searchPosts"
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      params = Plug.Conn.fetch_query_params(conn).query_params
      assert params["q"] == "" and params["sort"] == "latest"
      assert params["since"] == "2026-10-20T00:00:00Z"
      assert params["cursor"] == "continued" and params["limit"] == "100"
      refute Map.has_key?(params, "takenDown")
      refute Map.has_key?(params, "include_replies")
      Req.Test.json(conn, %{posts: [%{uri: "at://reply", record: %{reply: %{}}}], cursor: "next"})
    end)

    assert {:ok, %{"posts" => [%{"post" => %{"uri" => "at://reply"}}], "cursor" => "next"}} =
             Rice.Admin.Posts.Http.query(
               include_replies: true,
               takenDown: "false",
               since: "2026-10-20T00:00:00Z",
               cursor: "continued",
               limit: 100
             )
  end

  test "人工管理列表仍走原带凭据的管理查询，不改变后台契约" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.host == "labeler.test"
      assert conn.request_path == "/xrpc/aerox.moderation.queryPosts"

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Basic " <> Base.encode64("admin:test-only")
             ]

      Req.Test.json(conn, %{posts: []})
    end)

    assert {:ok, %{"posts" => []}} = Rice.Admin.Posts.Http.query(limit: 20)
  end
end

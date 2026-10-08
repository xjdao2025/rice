defmodule RiceWeb.Api.ProposalCommentControllerTest do
  use RiceWeb.ConnCase, async: true

  setup do
    {me, token} = user_with_token()
    %{me: me, token: token, proposal: proposal_fixture(user_fixture())}
  end

  describe "评论" do
    test "发表并列出", %{conn: conn, token: token, proposal: p} do
      assert %{"data" => created} =
               conn
               |> authed(token)
               |> post(~p"/api/proposals/#{p.id}/comments", %{body: "支持"})
               |> json_response(201)

      assert created["body"] == "支持"
      assert created["author"]["id"]

      assert %{"data" => [one]} =
               build_conn() |> get(~p"/api/proposals/#{p.id}/comments") |> json_response(200)

      assert one["id"] == created["id"]
    end

    test "评论者的联系方式不外露", %{conn: conn, proposal: p} do
      {_u, token} = user_with_token(%{email: "secret@example.com"})
      conn |> authed(token) |> post(~p"/api/proposals/#{p.id}/comments", %{body: "x"})

      body = build_conn() |> get(~p"/api/proposals/#{p.id}/comments") |> response(200)
      refute body =~ "secret@example.com"
    end

    test "空内容 / 超长 422", %{conn: conn, token: token, proposal: p} do
      for body <- ["", "   ", String.duplicate("字", 513)] do
        assert conn
               |> authed(token)
               |> post(~p"/api/proposals/#{p.id}/comments", %{body: body})
               |> json_response(422)
      end
    end

    test "能删自己的", %{conn: conn, token: token, proposal: p} do
      id =
        conn
        |> authed(token)
        |> post(~p"/api/proposals/#{p.id}/comments", %{body: "待删"})
        |> json_response(201)
        |> get_in(["data", "id"])

      assert build_conn()
             |> authed(token)
             |> delete(~p"/api/proposals/#{p.id}/comments/#{id}")
             |> response(204)

      assert %{"data" => []} =
               build_conn() |> get(~p"/api/proposals/#{p.id}/comments") |> json_response(200)
    end

    test "删不了别人的 —— 403", %{conn: conn, proposal: p} do
      {_a, a_token} = user_with_token()
      {_b, b_token} = user_with_token()

      id =
        build_conn()
        |> authed(a_token)
        |> post(~p"/api/proposals/#{p.id}/comments", %{body: "别人的"})
        |> json_response(201)
        |> get_in(["data", "id"])

      assert conn
             |> authed(b_token)
             |> delete(~p"/api/proposals/#{p.id}/comments/#{id}")
             |> json_response(403)
    end

    # 评论 id 属于另一个提案时不能借道删除
    test "跨提案的评论 id 是 404", %{conn: conn, token: token, proposal: p} do
      other = proposal_fixture(user_fixture())

      id =
        conn
        |> authed(token)
        |> post(~p"/api/proposals/#{p.id}/comments", %{body: "x"})
        |> json_response(201)
        |> get_in(["data", "id"])

      assert build_conn()
             |> authed(token)
             |> delete(~p"/api/proposals/#{other.id}/comments/#{id}")
             |> json_response(404)
    end

    test "未认证不能发也不能删", %{conn: conn, proposal: p} do
      assert conn
             |> post(~p"/api/proposals/#{p.id}/comments", %{body: "x"})
             |> json_response(401)

      assert build_conn()
             |> delete(~p"/api/proposals/#{p.id}/comments/#{Rice.Tsid.generate()}")
             |> json_response(401)
    end
  end
end

defmodule RiceWeb.Api.ProposalVoteControllerTest do
  use RiceWeb.ConnCase, async: true

  setup do
    {voter, token} = user_with_token()
    %{voter: voter, token: token, proposal: proposal_fixture(user_fixture())}
  end

  describe "POST /api/proposals/:id/vote" do
    test "投票", %{conn: conn, token: token, proposal: p} do
      assert %{"data" => %{"choice" => "agree"}} =
               conn
               |> authed(token)
               |> post(~p"/api/proposals/#{p.id}/vote", %{choice: "agree"})
               |> json_response(201)

      assert Rice.Repo.get!(Rice.Governance.Proposal, p.id).agree_count == 1
    end

    test "重复投票 422", %{conn: conn, token: token, proposal: p} do
      conn |> authed(token) |> post(~p"/api/proposals/#{p.id}/vote", %{choice: "agree"})

      assert %{"errors" => errors} =
               build_conn()
               |> authed(token)
               |> post(~p"/api/proposals/#{p.id}/vote", %{choice: "oppose"})
               |> json_response(422)

      assert errors["proposal_id"] == ["已经投过票了"]
      assert Rice.Repo.get!(Rice.Governance.Proposal, p.id).oppose_count == 0
    end

    test "非法选项 422", %{conn: conn, token: token, proposal: p} do
      for bad <- ["yes", "", nil, "AGREE", 1] do
        assert conn
               |> authed(token)
               |> post(~p"/api/proposals/#{p.id}/vote", %{choice: bad})
               |> json_response(422)
      end
    end

    test "截止后 422", %{conn: conn, token: token, proposal: p} do
      Rice.Repo.update!(
        Ecto.Changeset.change(p, closes_at: DateTime.add(DateTime.utc_now(), -1, :second))
      )

      assert %{"errors" => %{"detail" => "投票已结束"}} =
               conn
               |> authed(token)
               |> post(~p"/api/proposals/#{p.id}/vote", %{choice: "agree"})
               |> json_response(422)
    end

    test "提案不存在 404", %{conn: conn, token: token} do
      assert conn
             |> authed(token)
             |> post(~p"/api/proposals/#{Rice.Tsid.generate()}/vote", %{choice: "agree"})
             |> json_response(404)
    end

    test "未认证 401", %{conn: conn, proposal: p} do
      assert conn
             |> post(~p"/api/proposals/#{p.id}/vote", %{choice: "agree"})
             |> json_response(401)
    end
  end

  describe "GET /api/proposals/:id/vote" do
    test "没投过返回 null", %{conn: conn, token: token, proposal: p} do
      assert %{"data" => nil} =
               conn |> authed(token) |> get(~p"/api/proposals/#{p.id}/vote") |> json_response(200)
    end

    test "投过返回选项", %{conn: conn, token: token, proposal: p} do
      conn |> authed(token) |> post(~p"/api/proposals/#{p.id}/vote", %{choice: "oppose"})

      assert %{"data" => %{"choice" => "oppose"}} =
               build_conn()
               |> authed(token)
               |> get(~p"/api/proposals/#{p.id}/vote")
               |> json_response(200)
    end

    test "未认证 401", %{conn: conn, proposal: p} do
      assert conn |> get(~p"/api/proposals/#{p.id}/vote") |> json_response(401)
    end
  end
end

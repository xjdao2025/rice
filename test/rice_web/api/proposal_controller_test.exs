defmodule RiceWeb.Api.ProposalControllerTest do
  use RiceWeb.ConnCase, async: true

  alias Rice.Governance

  defp future, do: DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second)

  describe "GET /api/proposals" do
    test "公开可读", %{conn: conn} do
      author = node_member_fixture(%{nickname: "发起人"})
      proposal_fixture(author, %{title: "修路提案"})

      assert %{"data" => [one]} = conn |> get(~p"/api/proposals") |> json_response(200)

      assert one["title"] == "修路提案"
      assert one["status"] == "open"
      assert one["agree_count"] == 0
      assert one["total_votes"] == 0
      assert one["author"]["nickname"] == "发起人"
    end

    test "total_votes 是现算的", %{conn: conn} do
      author = node_member_fixture()
      p = proposal_fixture(author)
      {:ok, _} = Governance.vote(node_member_fixture(), p, "agree")
      {:ok, _} = Governance.vote(node_member_fixture(), p, "oppose")

      assert %{"data" => [one]} = conn |> get(~p"/api/proposals") |> json_response(200)
      assert one["agree_count"] == 1
      assert one["oppose_count"] == 1
      assert one["total_votes"] == 2
    end

    test "发起人的联系方式不外露", %{conn: conn} do
      author = node_member_fixture(%{email: "secret@example.com", phone: "13800000000"})
      proposal_fixture(author)

      body = conn |> get(~p"/api/proposals") |> response(200)
      refute body =~ "secret@example.com"
      refute body =~ "13800000000"
    end

    test "按状态筛选", %{conn: conn} do
      author = node_member_fixture()
      open = proposal_fixture(author)
      passed = proposal_fixture(author)
      Rice.Repo.update!(Ecto.Changeset.change(passed, status: "passed"))

      assert %{"data" => [a]} = conn |> get(~p"/api/proposals?status=open") |> json_response(200)
      assert a["id"] == open.id

      assert %{"data" => [b]} =
               build_conn() |> get(~p"/api/proposals?status=passed") |> json_response(200)

      assert b["id"] == passed.id
    end

    test "mine=true 只返回自己的", %{conn: conn} do
      {me, token} = node_member_with_token()
      mine = proposal_fixture(me)
      proposal_fixture(node_member_fixture())

      assert %{"data" => [one]} =
               conn |> authed(token) |> get(~p"/api/proposals?mine=true") |> json_response(200)

      assert one["id"] == mine.id
    end

    test "mine=voted 返回我投过票的(不含我发起但没投的)", %{conn: conn} do
      {me, token} = node_member_with_token()
      _authored = proposal_fixture(me)
      voted = proposal_fixture(node_member_fixture())
      _untouched = proposal_fixture(node_member_fixture())
      {:ok, _} = Rice.Governance.vote(me, voted, "agree")

      assert %{"data" => [one]} =
               conn |> authed(token) |> get(~p"/api/proposals?mine=voted") |> json_response(200)

      assert one["id"] == voted.id
    end

    test "mine=all 是发起与投票的并集,且不重复", %{conn: conn} do
      {me, token} = node_member_with_token()
      both = proposal_fixture(me)
      voted = proposal_fixture(node_member_fixture())
      _untouched = proposal_fixture(node_member_fixture())
      # 自己发起的自己也投了 —— join 实现会让它出现两次,EXISTS 不会
      {:ok, _} = Rice.Governance.vote(me, both, "agree")
      {:ok, _} = Rice.Governance.vote(me, voted, "oppose")

      assert %{"data" => data} =
               conn |> authed(token) |> get(~p"/api/proposals?mine=all") |> json_response(200)

      assert Enum.map(data, & &1["id"]) |> Enum.sort() == Enum.sort([both.id, voted.id])
    end

    test "mine 与 status 可以叠加", %{conn: conn} do
      {me, token} = node_member_with_token()
      open = proposal_fixture(me)
      passed = proposal_fixture(me)
      Rice.Repo.update!(Ecto.Changeset.change(passed, status: "passed"))

      assert %{"data" => [one]} =
               conn
               |> authed(token)
               |> get(~p"/api/proposals?mine=created&status=open")
               |> json_response(200)

      assert one["id"] == open.id
    end

    test "未登录时 mine 被忽略,退回公开列表", %{conn: conn} do
      proposal_fixture(node_member_fixture())
      proposal_fixture(node_member_fixture())

      assert %{"data" => data} = conn |> get(~p"/api/proposals?mine=voted") |> json_response(200)
      assert length(data) == 2
    end

    test "my_vote 反映当前用户的投票,未登录恒为 null", %{conn: conn} do
      {me, token} = node_member_with_token()
      voted = proposal_fixture(node_member_fixture())
      untouched = proposal_fixture(node_member_fixture())
      {:ok, _} = Rice.Governance.vote(me, voted, "oppose")

      assert %{"data" => data} =
               conn |> authed(token) |> get(~p"/api/proposals") |> json_response(200)

      by_id = Map.new(data, &{&1["id"], &1["my_vote"]})
      assert by_id[voted.id] == "oppose"
      assert by_id[untouched.id] == nil

      # 详情页同样带上
      assert %{"data" => one} =
               build_conn()
               |> authed(token)
               |> get(~p"/api/proposals/#{voted.id}")
               |> json_response(200)

      assert one["my_vote"] == "oppose"

      # 未登录看到的永远是 null,不会泄露别人投了什么
      assert %{"data" => anon} =
               build_conn() |> get(~p"/api/proposals/#{voted.id}") |> json_response(200)

      assert anon["my_vote"] == nil
    end

    test "软删和下架的不出现", %{conn: conn} do
      author = node_member_fixture()
      deleted = proposal_fixture(author)
      Rice.Repo.update!(Ecto.Changeset.change(deleted, deleted_at: DateTime.utc_now()))
      unlisted = proposal_fixture(author)
      Rice.Repo.update!(Ecto.Changeset.change(unlisted, listed: false))

      assert %{"data" => []} = conn |> get(~p"/api/proposals") |> json_response(200)
    end

    test "分页", %{conn: conn} do
      author = node_member_fixture()
      for _ <- 1..25, do: proposal_fixture(author)

      page1 = conn |> get(~p"/api/proposals") |> json_response(200)
      assert length(page1["data"]) == 20

      page2 =
        build_conn()
        |> get(~p"/api/proposals?before=#{page1["meta"]["next_cursor"]}")
        |> json_response(200)

      assert length(page2["data"]) == 5
    end
  end

  describe "GET /api/proposals/:id" do
    test "命中", %{conn: conn} do
      p = proposal_fixture(node_member_fixture(), %{title: "详情"})

      assert %{"data" => %{"title" => "详情"}} =
               conn |> get(~p"/api/proposals/#{p.id}") |> json_response(200)
    end

    test "不存在 / 非法 id 都是 404", %{conn: conn} do
      for id <- [Rice.Tsid.generate(), "abc", "../../etc/passwd"] do
        assert conn |> get(~p"/api/proposals/#{id}") |> json_response(404)
      end
    end
  end

  describe "POST /api/proposals" do
    test "发起提案", %{conn: conn} do
      {_user, token} = node_member_with_token()

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> post(~p"/api/proposals", %{title: "新提案", closes_at: future()})
               |> json_response(201)

      assert data["title"] == "新提案"
      assert data["status"] == "open"
    end

    # status / 票数 / 上架状态都不能由客户端指定
    test "客户端不能自己指定状态和票数", %{conn: conn} do
      {_user, token} = node_member_with_token()

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> post(~p"/api/proposals", %{
                 title: "作弊提案",
                 closes_at: future(),
                 status: "passed",
                 agree_count: 9999,
                 listed: false
               })
               |> json_response(201)

      assert data["status"] == "open"
      assert data["agree_count"] == 0
    end

    test "截止时间在过去 422", %{conn: conn} do
      {_user, token} = node_member_with_token()

      assert conn
             |> authed(token)
             |> post(~p"/api/proposals", %{
               title: "x",
               closes_at: DateTime.add(DateTime.utc_now(), -1, :second)
             })
             |> json_response(422)
    end

    test "缺标题 / 标题超长 422", %{conn: conn} do
      {_user, token} = node_member_with_token()

      for params <- [
            %{closes_at: future()},
            %{title: "", closes_at: future()},
            %{title: String.duplicate("字", 129), closes_at: future()}
          ] do
        assert conn |> authed(token) |> post(~p"/api/proposals", params) |> json_response(422)
      end
    end

    test "未认证 401", %{conn: conn} do
      assert conn
             |> post(~p"/api/proposals", %{title: "x", closes_at: future()})
             |> json_response(401)
    end
  end

  describe "DELETE /api/proposals/:id" do
    test "能删自己的", %{conn: conn} do
      {me, token} = node_member_with_token()
      p = proposal_fixture(me)

      assert conn |> authed(token) |> delete(~p"/api/proposals/#{p.id}") |> response(204)
      assert build_conn() |> get(~p"/api/proposals/#{p.id}") |> json_response(404)
    end

    test "删不了别人的 —— 403", %{conn: conn} do
      {_me, token} = node_member_with_token()
      p = proposal_fixture(node_member_fixture())

      assert conn |> authed(token) |> delete(~p"/api/proposals/#{p.id}") |> json_response(403)
      refute Rice.Repo.get!(Rice.Governance.Proposal, p.id).deleted_at
    end

    test "未认证 401", %{conn: conn} do
      p = proposal_fixture(node_member_fixture())
      assert conn |> delete(~p"/api/proposals/#{p.id}") |> json_response(401)
    end
  end
end

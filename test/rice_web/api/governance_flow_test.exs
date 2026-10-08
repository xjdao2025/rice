defmodule RiceWeb.Api.GovernanceFlowTest do
  @moduledoc "提案从发起、投票、评论、后台下架到结票的完整 HTTP 流程。"
  use RiceWeb.ConnCase, async: true

  alias Rice.Governance

  defp vote(token, proposal_id, choice),
    do:
      build_conn()
      |> authed(token)
      |> post(~p"/api/proposals/#{proposal_id}/vote", %{choice: choice})

  defp show(token, proposal_id) do
    conn = if token, do: authed(build_conn(), token), else: build_conn()
    get(conn, ~p"/api/proposals/#{proposal_id}")
  end

  defp list(token, params \\ %{}) do
    conn = if token, do: authed(build_conn(), token), else: build_conn()
    conn |> get(~p"/api/proposals", params) |> json_response(200) |> Map.fetch!("data")
  end

  test "发起、投票、评论、下架复核、到期结票,每个身份看到的都是自己的那份" do
    {:ok, _} = Rice.Settings.update_site(%{proposal_approval_votes: 2})
    {_author, author_token} = user_with_token(%{nickname: "发起人"})
    {_v1, v1_token} = user_with_token(%{nickname: "甲"})
    {_v2, v2_token} = user_with_token(%{nickname: "乙"})
    {_v3, v3_token} = user_with_token(%{nickname: "丙"})
    {_admin, admin_token} = admin_with_token()
    closes_at = DateTime.add(DateTime.utc_now(), 3600)

    # ── 发起两条提案 ──────────────────────────────────────────────────
    assert build_conn()
           |> post(~p"/api/proposals", %{title: "x", closes_at: closes_at})
           |> response(401)

    first =
      build_conn()
      |> authed(author_token)
      |> post(~p"/api/proposals", %{title: "修村口的路", closes_at: closes_at})
      |> json_response(201)
      |> Map.fetch!("data")

    second =
      build_conn()
      |> authed(author_token)
      |> post(~p"/api/proposals", %{title: "换路灯", closes_at: closes_at})
      |> json_response(201)
      |> Map.fetch!("data")

    assert first["status"] == "open" and first["agree_count"] == 0
    assert Enum.map(list(nil), & &1["id"]) == [second["id"], first["id"]]

    # ── 投票:一人一票,计数现算 ────────────────────────────────────────
    assert vote(v1_token, first["id"], "agree") |> json_response(201)
    assert vote(v2_token, first["id"], "agree") |> json_response(201)
    assert vote(v3_token, first["id"], "oppose") |> json_response(201)
    assert vote(v1_token, second["id"], "agree") |> json_response(201)
    assert vote(author_token, first["id"], "agree") |> json_response(201)
    # 甲改投反对不行:票已投出
    assert %{"errors" => %{"proposal_id" => _}} =
             vote(v1_token, first["id"], "oppose") |> json_response(422)

    detail = show(v1_token, first["id"]) |> json_response(200) |> Map.fetch!("data")
    assert {detail["agree_count"], detail["oppose_count"], detail["total_votes"]} == {3, 1, 4}
    assert detail["my_vote"] == "agree"

    assert show(v3_token, first["id"]) |> json_response(200) |> get_in(["data", "my_vote"]) ==
             "oppose"

    assert show(nil, first["id"]) |> json_response(200) |> get_in(["data", "my_vote"]) == nil

    assert build_conn()
           |> authed(v3_token)
           |> get(~p"/api/proposals/#{first["id"]}/vote")
           |> json_response(200)
           |> get_in(["data", "choice"]) == "oppose"

    # 我投过的 / 我发起的
    assert Enum.map(list(v3_token, %{mine: "voted"}), & &1["id"]) == [first["id"]]
    assert Enum.map(list(v1_token, %{mine: "voted"}), & &1["id"]) == [second["id"], first["id"]]

    assert Enum.map(list(author_token, %{mine: "created"}), & &1["id"]) == [
             second["id"],
             first["id"]
           ]

    assert list(v2_token, %{mine: "created"}) == []

    # ── 评论:自己能删,别人不能,后台谁的都能删 ──────────────────────
    comment =
      build_conn()
      |> authed(v1_token)
      |> post(~p"/api/proposals/#{first["id"]}/comments", %{body: "支持,顺便修排水"})
      |> json_response(201)
      |> Map.fetch!("data")

    assert build_conn()
           |> authed(v2_token)
           |> delete(~p"/api/proposals/#{first["id"]}/comments/#{comment["id"]}")
           |> response(403)

    assert build_conn()
           |> get(~p"/api/proposals/#{first["id"]}/comments")
           |> json_response(200)
           |> Map.fetch!("data")
           |> length() == 1

    assert build_conn()
           |> authed(admin_token)
           |> delete(~p"/api/admin/proposals/#{first["id"]}/comments/#{comment["id"]}")
           |> response(204)

    assert build_conn()
           |> get(~p"/api/proposals/#{first["id"]}/comments")
           |> json_response(200)
           |> Map.fetch!("data") == []

    # ── 后台下架:C 端看不见也投不了,后台能看见、能恢复 ───────────────
    assert build_conn()
           |> authed(admin_token)
           |> patch(~p"/api/admin/proposals/#{second["id"]}", %{listed: false})
           |> json_response(200)
           |> get_in(["data", "listed"]) == false

    assert show(nil, second["id"]) |> response(404)
    assert Enum.map(list(nil), & &1["id"]) == [first["id"]]
    assert vote(v2_token, second["id"], "agree") |> response(404)

    admin_list =
      build_conn() |> authed(admin_token) |> get(~p"/api/admin/proposals") |> json_response(200)

    assert Enum.any?(admin_list["data"], &(&1["id"] == second["id"] and &1["listed"] == false))

    assert build_conn()
           |> authed(admin_token)
           |> patch(~p"/api/admin/proposals/#{second["id"]}", %{listed: true})
           |> json_response(200)

    assert show(nil, second["id"]) |> json_response(200)

    # ── 到期结票:同意票达到门槛通过,否则否决;结了就不能再投 ──────────
    assert %{passed: 1, rejected: 1} = Governance.close_due_proposals(DateTime.add(closes_at, 1))
    assert %{passed: 0, rejected: 0} = Governance.close_due_proposals(DateTime.add(closes_at, 1))
    assert show(nil, first["id"]) |> json_response(200) |> get_in(["data", "status"]) == "passed"

    assert show(nil, second["id"]) |> json_response(200) |> get_in(["data", "status"]) ==
             "rejected"

    assert vote(v2_token, second["id"], "agree") |> json_response(422)
    assert Enum.map(list(nil, %{status: "passed"}), & &1["id"]) == [first["id"]]

    assert Enum.map(list(v1_token, %{mine: "voted", status: "rejected"}), & &1["id"]) == [
             second["id"]
           ]

    # ── 删除:只能删自己的;有人投过票就删不掉,删了就查不到 ─────────────
    assert build_conn()
           |> authed(v1_token)
           |> delete(~p"/api/proposals/#{second["id"]}")
           |> response(403)

    assert build_conn()
           |> authed(author_token)
           |> delete(~p"/api/proposals/#{second["id"]}")
           |> response(409)

    unvoted =
      build_conn()
      |> authed(author_token)
      |> post(~p"/api/proposals", %{title: "写错了", closes_at: closes_at})
      |> json_response(201)
      |> Map.fetch!("data")

    assert build_conn()
           |> authed(author_token)
           |> delete(~p"/api/proposals/#{unvoted["id"]}")
           |> response(204)

    assert show(author_token, unvoted["id"]) |> response(404)
  end
end

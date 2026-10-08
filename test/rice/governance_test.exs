defmodule Rice.GovernanceTest do
  use Rice.DataCase, async: true

  alias Rice.Governance
  alias Rice.Governance.{Proposal, Vote}

  defp reload(p), do: Rice.Repo.get!(Proposal, p.id)

  describe "投票" do
    setup do
      author = user_fixture()
      %{author: author, proposal: proposal_fixture(author), voter: user_fixture()}
    end

    test "投票后计数增加", %{proposal: p, voter: voter} do
      assert {:ok, _} = Governance.vote(voter, p, "agree")

      assert reload(p).agree_count == 1
      assert reload(p).oppose_count == 0
    end

    # core 靠应用层先查后插,并发能重复投。这里由唯一索引挡下。
    test "同一个人不能投两次", %{proposal: p, voter: voter} do
      assert {:ok, _} = Governance.vote(voter, p, "agree")
      assert {:error, changeset} = Governance.vote(voter, reload(p), "oppose")
      assert "已经投过票了" in errors_on(changeset).proposal_id

      assert reload(p).agree_count == 1
      assert reload(p).oppose_count == 0
    end

    test "并发投票:计数不丢、不重", %{proposal: p} do
      voters = for _ <- 1..20, do: user_fixture()
      parent = self()

      voters
      |> Task.async_stream(
        fn voter ->
          Ecto.Adapters.SQL.Sandbox.allow(Rice.Repo, parent, self())
          Governance.vote(voter, p, "agree")
        end,
        max_concurrency: 20,
        timeout: 30_000
      )
      |> Stream.run()

      assert reload(p).agree_count == 20
      assert Rice.Repo.aggregate(Vote, :count) == 20
    end

    # 同一个人并发狂点,只能算一票
    test "同一个人并发重复投票只成功一次", %{proposal: p, voter: voter} do
      parent = self()

      results =
        1..10
        |> Task.async_stream(
          fn _ ->
            Ecto.Adapters.SQL.Sandbox.allow(Rice.Repo, parent, self())
            Governance.vote(voter, p, "agree")
          end,
          max_concurrency: 10,
          timeout: 30_000
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.count(results, &match?({:ok, _}, &1)) == 1
      assert reload(p).agree_count == 1
    end

    test "非法选项被拒", %{proposal: p, voter: voter} do
      for bad <- ["yes", "", nil, "AGREE"] do
        assert {:error, :invalid_choice} = Governance.vote(voter, p, bad)
      end

      assert reload(p).agree_count == 0
    end

    test "截止后不能再投", %{author: author, voter: voter} do
      p = proposal_fixture(author)

      Rice.Repo.update_all(Proposal,
        set: [closes_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert {:error, :proposal_closed} = Governance.vote(voter, reload(p), "agree")
    end

    test "已结票的提案不能再投", %{proposal: p, voter: voter} do
      Rice.Repo.update!(Ecto.Changeset.change(p, status: "passed"))
      assert {:error, :proposal_closed} = Governance.vote(voter, reload(p), "agree")
    end

    test "软删的提案不能再投", %{proposal: p, voter: voter} do
      Rice.Repo.update!(Ecto.Changeset.change(p, deleted_at: DateTime.utc_now()))
      assert {:error, :proposal_closed} = Governance.vote(voter, reload(p), "agree")
    end
  end

  describe "结票" do
    setup do
      site_settings_fixture(%{proposal_approval_votes: 3})
      %{author: user_fixture()}
    end

    defp make_due(proposal) do
      Rice.Repo.update!(
        Ecto.Changeset.change(proposal,
          closes_at: DateTime.add(DateTime.utc_now(), -60, :second)
        )
      )
    end

    test "达到门槛的通过", %{author: author} do
      p = proposal_fixture(author)
      for _ <- 1..3, do: {:ok, _} = Governance.vote(user_fixture(), p, "agree")
      make_due(p)

      assert %{passed: 1, rejected: 0} = Governance.close_due_proposals()
      assert reload(p).status == "passed"
    end

    # 投票前读到的提案还是 open,结票却先一步落了库:这一票不能计数后又不算进结果
    test "结票之后到达的票整张回滚", %{author: author} do
      p = proposal_fixture(author)
      make_due(p)
      Governance.close_due_proposals()
      voter = user_fixture()

      assert {:error, :proposal_closed} =
               Governance.vote(
                 voter,
                 %{p | closes_at: DateTime.add(DateTime.utc_now(), 60)},
                 "agree"
               )

      assert reload(p).agree_count == 0
      refute Governance.get_my_vote(voter, p)
    end

    test "差一票就不通过", %{author: author} do
      p = proposal_fixture(author)
      for _ <- 1..2, do: {:ok, _} = Governance.vote(user_fixture(), p, "agree")
      make_due(p)

      assert %{passed: 0, rejected: 1} = Governance.close_due_proposals()
      assert reload(p).status == "rejected"
    end

    test "反对票不影响门槛判定 —— 只看同意票数", %{author: author} do
      p = proposal_fixture(author)
      for _ <- 1..3, do: {:ok, _} = Governance.vote(user_fixture(), p, "agree")
      for _ <- 1..99, do: {:ok, _} = Governance.vote(user_fixture(), p, "oppose")
      make_due(p)

      assert %{passed: 1} = Governance.close_due_proposals()
    end

    test "没到期的不动", %{author: author} do
      p = proposal_fixture(author)
      assert %{passed: 0, rejected: 0} = Governance.close_due_proposals()
      assert reload(p).status == "open"
    end

    test "幂等:重复跑不会改变已结的提案", %{author: author} do
      p = proposal_fixture(author) |> make_due()

      assert %{rejected: 1} = Governance.close_due_proposals()
      assert %{passed: 0, rejected: 0} = Governance.close_due_proposals()
      assert reload(p).status == "rejected"
    end

    test "软删的提案不参与结票", %{author: author} do
      p = proposal_fixture(author) |> make_due()
      Rice.Repo.update!(Ecto.Changeset.change(p, deleted_at: DateTime.utc_now()))

      assert %{passed: 0, rejected: 0} = Governance.close_due_proposals()
      assert reload(p).status == "open"
    end
  end

  describe "提案的增删" do
    test "截止时间必须在将来" do
      user = user_fixture()

      assert {:error, changeset} =
               Governance.create_proposal(user, %{
                 title: "过去的提案",
                 closes_at: DateTime.add(DateTime.utc_now(), -1, :second)
               })

      assert "截止时间必须在将来" in errors_on(changeset).closes_at
    end

    test "只能删自己的" do
      author = user_fixture()
      other = user_fixture()
      p = proposal_fixture(author)

      assert {:error, :forbidden} = Governance.delete_proposal(other, p)
      assert {:ok, _} = Governance.delete_proposal(author, p)
      assert Governance.fetch_proposal(p.id) == {:error, :not_found}
    end
  end
end

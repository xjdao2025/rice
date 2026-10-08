defmodule Rice.Governance do
  @moduledoc """
  提案、投票、评论。

  结票逻辑:到 `closes_at` 时,同意票数达到 `site_settings.proposal_approval_votes`
  即 `passed`,否则 `rejected`。core 用 Hangfire 每分钟跑一次 `ProposalEndJob`
  (任务状态存 Redis);这里换成 Oban 的 cron,任务表和业务表同库同事务。
  """
  import Ecto.Query

  alias Ecto.Multi
  alias Rice.Accounts.User
  alias Rice.Governance.{Comment, Proposal, Vote}
  alias Rice.{Pagination, Repo}

  # ── 提案 ────────────────────────────────────────────────────────────────

  @spec list_proposals(map()) :: Pagination.page(Proposal.t())
  def list_proposals(params \\ %{}) do
    base()
    |> filter_status(params["status"])
    |> filter_author(params["user_id"])
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  @doc """
  与当前用户相关的提案。`mine` 决定关系:

    * `"created"`(默认)—— 我发起的
    * `"voted"` —— 我投过票的
    * `"all"` —— 前两者的并集

  core 那边是 `/proposal/my-proposal-list` 的数字 `type`(0/1/2)。
  """
  @spec list_my_proposals(User.t(), map()) :: Pagination.page(Proposal.t())
  def list_my_proposals(%User{id: id}, params \\ %{}) do
    base()
    |> filter_status(params["status"])
    |> scope_mine(id, params["mine"])
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  defp base do
    from p in Proposal,
      as: :proposal,
      where: is_nil(p.deleted_at) and p.listed == true,
      preload: [:attachment, user: :avatar]
  end

  # 用 EXISTS 而不是 join —— join 会让投过多次的提案重复出现,再靠 distinct 去重
  # 又会和游标分页的 order_by 打架。
  defp voted_by(user_id) do
    from v in Vote,
      where: v.proposal_id == parent_as(:proposal).id and v.user_id == ^user_id,
      select: 1
  end

  defp scope_mine(query, id, "voted"),
    do: from(p in query, where: exists(voted_by(id)))

  defp scope_mine(query, id, "all"),
    do: from(p in query, where: p.user_id == ^id or exists(voted_by(id)))

  defp scope_mine(query, id, _created),
    do: from(p in query, where: p.user_id == ^id)

  defp filter_status(query, status) when status in ~w(open passed rejected),
    do: from(p in query, where: p.status == ^status)

  defp filter_status(query, _), do: query

  defp filter_author(query, user_id) do
    if is_binary(user_id) and Rice.Tsid.valid?(user_id),
      do: from(p in query, where: p.user_id == ^user_id),
      else: query
  end

  @doc """
  当前用户在这批提案上的投票,`%{proposal_id => choice}`。未登录返回空 map。

  一次查询解决列表的「我投过没」,不做 N+1。
  """
  @spec my_votes(User.t() | nil, [Proposal.t()]) :: %{optional(Rice.Tsid.t()) => String.t()}
  def my_votes(nil, _proposals), do: %{}

  def my_votes(%User{id: uid}, proposals) do
    ids = Enum.map(proposals, & &1.id)

    from(v in Vote,
      where: v.user_id == ^uid and v.proposal_id in ^ids,
      select: {v.proposal_id, v.choice}
    )
    |> Repo.all()
    |> Map.new()
  end

  @spec fetch_proposal(String.t()) :: {:ok, Proposal.t()} | {:error, :not_found}
  def fetch_proposal(id), do: Repo.fetch(base(), id)

  # 提案和投票都只给节点用户(node_member),和 core 一致:
  # "非节点用户不能提案" / "非节点用户不能投票提案"
  @spec create_proposal(User.t(), map()) ::
          {:ok, Proposal.t()} | {:error, :forbidden | Ecto.Changeset.t()}
  def create_proposal(%User{node_member: false}, _attrs), do: {:error, :forbidden}

  def create_proposal(%User{} = user, attrs) do
    %Proposal{user_id: user.id}
    |> Proposal.create_changeset(attrs)
    |> Repo.insert()
    |> Repo.preload_ok([:attachment, user: :avatar])
  end

  @doc """
  删自己的提案(软删)。别人的返回 :forbidden 而不是假装成功。
  有人投过票就不能删了 —— 否则作者看势头不对删掉,这次表决就没有结果。
  """
  @spec delete_proposal(User.t(), Proposal.t()) ::
          {:ok, Proposal.t()} | {:error, :conflict | :forbidden}
  def delete_proposal(%User{id: user_id}, %Proposal{user_id: user_id} = proposal) do
    # "没人投过票"和删除放在同一条语句里:先查后删的话,中间进来的一票会跟着提案一起消失
    unvoted =
      from p in Proposal,
        where:
          p.id == ^proposal.id and is_nil(p.deleted_at) and
            p.agree_count + p.oppose_count == 0

    case Repo.update_all(unvoted, set: [deleted_at: DateTime.utc_now()]) do
      {1, _} -> {:ok, proposal}
      {0, _} -> {:error, :conflict}
    end
  end

  def delete_proposal(%User{}, %Proposal{}), do: {:error, :forbidden}

  # ── 投票 ────────────────────────────────────────────────────────────────

  @doc """
  投票。一人一票,由 `(proposal_id, user_id)` 唯一索引保证 ——
  并发重复投票会被数据库挡下,而不是靠先查后插。
  """
  @spec vote(User.t(), Proposal.t(), String.t()) ::
          {:ok, Vote.t()}
          | {:error, :forbidden | :proposal_closed | :invalid_choice | Ecto.Changeset.t()}
  def vote(%User{} = user, %Proposal{} = proposal, choice) do
    cond do
      not user.node_member ->
        {:error, :forbidden}

      not Proposal.open?(proposal) ->
        {:error, :proposal_closed}

      DateTime.compare(proposal.closes_at, DateTime.utc_now()) != :gt ->
        {:error, :proposal_closed}

      choice not in Vote.choices() ->
        {:error, :invalid_choice}

      true ->
        changeset =
          Vote.changeset(%Vote{}, %{
            proposal_id: proposal.id,
            user_id: user.id,
            choice: choice
          })

        Multi.new()
        |> Multi.insert(:vote, changeset)
        |> Multi.run(:count, fn repo, _ -> bump_count(repo, proposal.id, choice) end)
        |> Repo.transaction()
        |> case do
          {:ok, %{vote: vote}} -> {:ok, vote}
          {:error, _step, %Ecto.Changeset{} = cs, _} -> {:error, cs}
          {:error, _step, reason, _} -> {:error, reason}
        end
    end
  end

  # 原子自增,不读-改-写。条件里再判一次"还开着":和结票抢同一行时,
  # 要么计进结果,要么整张票回滚成"已截止",不会计了数却没算进结果。
  defp bump_count(repo, proposal_id, choice) do
    field = if choice == "agree", do: :agree_count, else: :oppose_count
    now = DateTime.utc_now()

    open =
      from p in Proposal,
        where:
          p.id == ^proposal_id and p.status == "open" and is_nil(p.deleted_at) and
            p.closes_at > ^now

    case repo.update_all(open, inc: [{field, 1}]) do
      {1, _} -> {:ok, choice}
      {0, _} -> {:error, :proposal_closed}
    end
  end

  @spec get_my_vote(User.t(), Proposal.t()) :: Vote.t() | nil
  def get_my_vote(%User{id: user_id}, %Proposal{id: proposal_id}) do
    Repo.one(from v in Vote, where: v.proposal_id == ^proposal_id and v.user_id == ^user_id)
  end

  # ── 评论 ────────────────────────────────────────────────────────────────

  @spec list_comments(Proposal.t(), map()) :: Pagination.page(Comment.t())
  def list_comments(%Proposal{id: proposal_id}, params \\ %{}) do
    from(c in Comment,
      where: c.proposal_id == ^proposal_id and is_nil(c.deleted_at),
      preload: [user: :avatar]
    )
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  @spec create_comment(User.t(), Proposal.t(), String.t()) ::
          {:ok, Comment.t()} | {:error, Ecto.Changeset.t()}
  def create_comment(%User{} = user, %Proposal{} = proposal, body) do
    %Comment{}
    |> Comment.changeset(%{proposal_id: proposal.id, user_id: user.id, body: body})
    |> Repo.insert()
    |> Repo.preload_ok(user: :avatar)
  end

  @spec fetch_comment(Proposal.t(), String.t()) :: {:ok, Comment.t()} | {:error, :not_found}
  def fetch_comment(%Proposal{id: proposal_id}, id) do
    Repo.fetch(
      from(c in Comment, where: c.proposal_id == ^proposal_id and is_nil(c.deleted_at)),
      id
    )
  end

  @spec delete_comment(User.t(), Comment.t()) ::
          {:ok, Comment.t()} | {:error, :forbidden | Ecto.Changeset.t()}
  def delete_comment(%User{id: user_id}, %Comment{} = comment) do
    if comment.user_id == user_id do
      comment |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()
    else
      {:error, :forbidden}
    end
  end

  # ── 后台 ────────────────────────────────────────────────────────────────

  @doc """
  后台的提案列表。和 C 端那份的区别:**看得到已下架和已软删的**。
  下架之后后台自己也找不回来的话,就没法复核了。
  """
  @spec list_all_proposals(map()) :: Pagination.page(Proposal.t())
  def list_all_proposals(params \\ %{}) do
    from(p in Proposal, as: :proposal, preload: [:attachment, user: :avatar])
    |> filter_status(params["status"])
    |> filter_listed(params["listed"])
    |> filter_title(params["q"])
    |> Repo.inserted_between(params["since"], params["until"])
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  defp filter_listed(query, "true"), do: from(p in query, where: p.listed == true)
  defp filter_listed(query, "false"), do: from(p in query, where: p.listed == false)
  defp filter_listed(query, _), do: query

  defp filter_title(query, q) when is_binary(q) and q != "" do
    pattern = Repo.contains(q)

    from p in query,
      left_join: u in assoc(p, :user),
      where: ilike(p.title, ^pattern) or ilike(u.nickname, ^pattern)
  end

  defp filter_title(query, _), do: query

  @doc "后台取单条 —— 下架的也取得到。"
  @spec fetch_any_proposal(String.t()) :: {:ok, Proposal.t()} | {:error, :not_found}
  def fetch_any_proposal(id),
    do: Repo.fetch(from(p in Proposal, preload: [:attachment, user: :avatar]), id)

  @doc "下架 / 恢复。core 的 take-off 只能单向下架,没有恢复的入口。"
  @spec set_listed(Proposal.t(), term()) ::
          {:ok, Proposal.t()} | {:error, :invalid_listed | Ecto.Changeset.t()}
  def set_listed(%Proposal{} = proposal, listed) when is_boolean(listed) do
    proposal
    |> Ecto.Changeset.change(listed: listed)
    |> Repo.update()
    |> Repo.preload_ok([:attachment, user: :avatar])
  end

  def set_listed(_proposal, _), do: {:error, :invalid_listed}

  @doc "后台删任意评论。C 端只能删自己的。"
  @spec admin_delete_comment(Proposal.t(), String.t()) ::
          {:ok, Comment.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def admin_delete_comment(%Proposal{} = proposal, comment_id) do
    with {:ok, comment} <- fetch_comment(proposal, comment_id) do
      comment |> Ecto.Changeset.change(deleted_at: DateTime.utc_now()) |> Repo.update()
    end
  end

  # ── 结票 ────────────────────────────────────────────────────────────────

  @doc """
  把所有已过截止时间、仍是 open 的提案结掉。由 Oban 的 cron 每分钟调用。

  返回 `%{passed: n, rejected: n}`。幂等 —— 已结的提案不会被再处理一次。
  """
  @spec close_due_proposals(DateTime.t()) :: %{
          passed: non_neg_integer(),
          rejected: non_neg_integer()
        }
  def close_due_proposals(now \\ DateTime.utc_now()) do
    threshold = Rice.Settings.get_site().proposal_approval_votes

    # 一条 UPDATE 里读票数、定结果:正在投的票要么已提交被算进来,要么被
    # `bump_count` 的截止条件挡掉。status = 'open' 让重跑不会重复计数。
    {_, statuses} =
      Repo.update_all(
        from(p in Proposal,
          where: p.status == "open" and is_nil(p.deleted_at) and p.closes_at <= ^now,
          update: [
            set: [
              status:
                fragment(
                  "CASE WHEN ? >= ? THEN 'passed' ELSE 'rejected' END",
                  p.agree_count,
                  ^threshold
                ),
              updated_at: ^DateTime.utc_now()
            ]
          ],
          select: p.status
        ),
        []
      )

    %{
      passed: Enum.count(statuses, &(&1 == "passed")),
      rejected: Enum.count(statuses, &(&1 == "rejected"))
    }
  end
end

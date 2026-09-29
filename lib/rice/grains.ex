defmodule Rice.Grains do
  @moduledoc """
  稻米(积分)。

  **并发扣款不需要分布式锁。** core 为此拉了 Redis
  (`IXiangjiandaoDistributedDisLock`,对付款方和收款方各 acquire 一次,5 秒超时)。
  这里靠一条带条件的 UPDATE:

      update users set grain_balance = grain_balance - $1
      where id = $2 and grain_balance >= $1

  匹配 0 行就是余额不足,整个事务回滚。数据库上还有
  `check (grain_balance >= 0)` 兜底,即使代码写错也不可能出现负余额。
  """
  import Ecto.Query

  alias Ecto.Multi
  alias Rice.Accounts.User
  alias Rice.Community.Node
  alias Rice.Grains.Transfer
  alias Rice.{Pagination, Repo}

  @doc """
  转账。`kind` 是 `reward` 或 `gift`。

  返回 `{:ok, transfer}`,或 `{:error, :insufficient_balance | :recipient_not_found |
  :recipient_disabled | changeset}`。
  """
  def transfer(%User{} = from, to_identifier, amount, opts \\ []) do
    with {:ok, to} <- resolve_recipient(to_identifier),
         :ok <- ensure_not_self(from, to) do
      attrs = %{
        kind: Keyword.get(opts, :kind, "gift"),
        from_user_id: from.id,
        to_user_id: to.id,
        amount: amount,
        memo: Keyword.get(opts, :memo, "") || "",
        subject_uri: Keyword.get(opts, :subject_uri)
      }

      changeset = Transfer.changeset(%Transfer{}, attrs)

      Multi.new()
      |> Multi.run(:accounts, fn repo, _ ->
        ids = [from.id, to.id]

        {:ok,
         repo.all(from u in User, where: u.id in ^ids, order_by: [asc: u.id], lock: "FOR UPDATE")}
      end)
      |> Multi.insert(:transfer, changeset)
      |> Multi.run(:debit, fn repo, _ -> debit(repo, from.id, amount) end)
      |> Multi.run(:credit, fn repo, _ -> credit(repo, to.id, amount) end)
      |> Repo.transaction()
      |> case do
        # 预加载双方 —— 渲染层要用,而且这里刚写完就取,不会有额外一轮查询的惊喜
        {:ok, %{transfer: transfer}} -> {:ok, Repo.preload(transfer, [:from_user, :to_user])}
        {:error, :debit, reason, _} -> {:error, reason}
        {:error, _step, %Ecto.Changeset{} = changeset, _} -> {:error, changeset}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  @doc "后台发放(增发)。没有付款方,总量增加。"
  def grant(%User{} = to, amount, opts \\ []) do
    attrs = %{
      kind: "grant",
      to_user_id: to.id,
      amount: amount,
      memo: Keyword.get(opts, :memo, "") || ""
    }

    Multi.new()
    |> Multi.insert(:transfer, Transfer.changeset(%Transfer{}, attrs))
    |> Multi.run(:credit, fn repo, _ -> credit(repo, to.id, amount) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{transfer: transfer}} -> {:ok, Repo.preload(transfer, [:from_user, :to_user])}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc "Reserve against a personal ID or {:node, id} inside the business transaction."
  def reserve_business(repo, account, amount, uri) when is_integer(amount) and amount > 0 do
    lock_business_accounts(repo, [account])

    case repo.get_by(Rice.Grains.Receipt, subject_uri: uri, kind: "reserved") do
      nil ->
        with {:ok, _} <- reserve_balance(repo, account, amount) do
          receipt(repo, "reserved", account, nil, amount, uri)
        end

      existing ->
        if matches_account?(existing, :from, account) and existing.amount == amount,
          do: {:ok, existing},
          else: {:error, :conflict}
    end
  end

  def refund_business(repo, account, amount, uri),
    do: finish_business(repo, account, nil, amount, uri, "refunded")

  def settle_business(repo, account, recipient, amount, uri),
    do: finish_business(repo, account, recipient, amount, uri, "settled")

  # All users, then all nodes, sorted by ID. Callers settling multiple applications
  # acquire the complete set first, so opposite transfers cannot reverse lock order.
  def lock_business_accounts(repo, accounts) do
    accounts = accounts |> Enum.reject(&is_nil/1) |> Enum.map(&account/1)

    for schema <- [User, Node] do
      ids = for {^schema, id} <- accounts, do: id
      repo.all(from a in schema, where: a.id in ^ids, order_by: [asc: a.id], lock: "FOR UPDATE")
    end
  end

  defp finish_business(repo, payer, recipient, amount, uri, kind) do
    lock_business_accounts(repo, [payer, recipient])
    reserved = repo.get_by(Rice.Grains.Receipt, subject_uri: uri, kind: "reserved")

    if not is_nil(reserved) and matches_account?(reserved, :from, payer) and
         reserved.amount == amount do
      outcome =
        repo.one(
          from r in Rice.Grains.Receipt, where: r.subject_uri == ^uri and r.kind != "reserved"
        )

      cond do
        is_nil(outcome) -> release_business(repo, payer, recipient, amount, uri, kind)
        outcome.kind == kind and matches_account?(outcome, :to, recipient) -> {:ok, outcome}
        true -> {:error, :conflict}
      end
    else
      {:error, :grain_reservation_missing}
    end
  end

  defp reserve_balance(repo, payer, amount) do
    {schema, id} = account(payer)

    case repo.update_all(from(a in schema, where: a.id == ^id and a.grain_balance >= ^amount),
           inc: [grain_balance: -amount, grain_frozen_balance: amount]
         ) do
      {1, _} -> {:ok, :reserved}
      _ -> {:error, :insufficient_balance}
    end
  end

  defp release_business(repo, payer, recipient, amount, uri, kind) do
    {schema, id} = account(payer)

    increments =
      if kind == "refunded",
        do: [grain_frozen_balance: -amount, grain_balance: amount],
        else: [grain_frozen_balance: -amount]

    case repo.update_all(
           from(a in schema, where: a.id == ^id and a.grain_frozen_balance >= ^amount),
           inc: increments
         ) do
      {1, _} ->
        if kind == "refunded" do
          receipt(repo, kind, payer, nil, amount, uri)
        else
          transfer_kind =
            if String.starts_with?(uri, "rice://tasks/"), do: "task_reward", else: "event_fee"

          attrs =
            Map.merge(parties(payer, recipient), %{
              kind: transfer_kind,
              amount: amount,
              subject_uri: uri,
              memo: if(transfer_kind == "task_reward", do: "任务完成奖励", else: "活动报名费用")
            })

          with {:ok, _} <- credit_account(repo, recipient, amount),
               {:ok, transfer} <- repo.insert(Transfer.changeset(%Transfer{}, attrs)) do
            receipt(repo, kind, payer, recipient, amount, uri, transfer.id)
          end
        end

      _ ->
        {:error, :grain_reservation_missing}
    end
  end

  defp receipt(repo, kind, payer, recipient, amount, uri, transfer_id \\ nil) do
    attrs =
      Map.merge(parties(payer, recipient), %{
        kind: kind,
        amount: amount,
        subject_uri: uri,
        transfer_id: transfer_id
      })

    repo.insert(Rice.Grains.Receipt.changeset(%Rice.Grains.Receipt{}, attrs))
  end

  defp account({:node, id}), do: {Node, id}
  defp account(id), do: {User, id}
  defp party(:from, {:node, id}), do: %{from_node_id: id}
  defp party(:to, {:node, id}), do: %{to_node_id: id}
  defp party(:from, id), do: %{from_user_id: id}
  defp party(:to, id), do: %{to_user_id: id}
  defp parties(from, to), do: Map.merge(party(:from, from), party(:to, to))

  defp matches_account?(entry, side, value) do
    expected =
      Map.merge(parties(nil, nil), %{from_node_id: nil, to_node_id: nil})
      |> Map.merge(party(side, value))

    keys = if side == :from, do: [:from_user_id, :from_node_id], else: [:to_user_id, :to_node_id]
    Map.take(entry, keys) == Map.take(expected, keys)
  end

  defp credit_account(repo, recipient, amount) do
    {schema, id} = account(recipient)

    case repo.update_all(from(a in schema, where: a.id == ^id), inc: [grain_balance: amount]) do
      {1, _} -> {:ok, :credited}
      _ -> {:error, :recipient_not_found}
    end
  end

  @doc "Explicit, retry-safe personal contribution; never automatically migrates a balance."
  def fund_node(%User{} = user, %Node{} = node, amount, request_id) do
    cond do
      not is_integer(amount) or amount <= 0 or amount > 999_999_999 ->
        {:error, :invalid_amount}

      not is_binary(request_id) or byte_size(request_id) not in 1..128 ->
        {:error, :missing_request_id}

      true ->
        Repo.transaction(fn ->
          lock_business_accounts(Repo, [user.id, {:node, node.id}])

          unless Rice.Community.admin?(Repo.get!(Node, node.id), user),
            do: Repo.rollback(:forbidden)

          uri = "rice://nodes/#{node.id}/fund/#{request_id}"

          existing =
            Repo.get_by(Transfer, kind: "community_fund", from_user_id: user.id, subject_uri: uri)

          cond do
            existing && existing.amount == amount ->
              existing

            existing ->
              Repo.rollback(:conflict)

            true ->
              attrs = %{
                kind: "community_fund",
                from_user_id: user.id,
                to_node_id: node.id,
                amount: amount,
                subject_uri: uri,
                memo: "转入节点稻米"
              }

              with {:ok, transfer} <- Repo.insert(Transfer.changeset(%Transfer{}, attrs)),
                   {:ok, _} <- debit(Repo, user.id, amount),
                   {:ok, _} <- credit_account(Repo, {:node, node.id}, amount) do
                transfer
              else
                {:error, reason} -> Repo.rollback(reason)
              end
          end
        end)
    end
  end

  def wallet(owner, params \\ %{}) do
    {schema, from_field, to_field} =
      case owner do
        %Node{} -> {Node, :from_node_id, :to_node_id}
        %User{} -> {User, :from_user_id, :to_user_id}
      end

    id = owner.id
    owner = Repo.get!(schema, id)

    earned =
      Repo.one(
        from t in Transfer, where: field(t, ^to_field) == ^id, select: coalesce(sum(t.amount), 0)
      )

    opts = Pagination.params(Map.take(params, ["before", "limit"]))

    transfers =
      from(t in Transfer,
        where: field(t, ^from_field) == ^id or field(t, ^to_field) == ^id,
        preload: [:from_user, :to_user, :from_node, :to_node]
      )
      |> Pagination.paginate(Repo, opts)

    receipts =
      from(r in Rice.Grains.Receipt,
        where: field(r, ^from_field) == ^id and r.kind != "settled",
        preload: [:from_user, :to_user, :from_node, :to_node]
      )
      |> Pagination.paginate(Repo, opts)

    combined = Enum.sort_by(transfers.entries ++ receipts.entries, & &1.id, :desc)
    page = Enum.take(combined, opts.limit)

    more? =
      length(combined) > opts.limit or transfers.next_cursor != nil or receipts.next_cursor != nil

    next_cursor = if more? and page != [], do: List.last(page).id

    entries =
      page
      |> Enum.map(fn entry ->
        %{
          id: entry.id,
          kind: entry.kind,
          amount: entry.amount,
          subject_uri: entry.subject_uri,
          inserted_at: entry.inserted_at,
          from_user: wallet_user(entry.from_user),
          to_user: wallet_user(entry.to_user),
          from_node: wallet_node(entry.from_node),
          to_node: wallet_node(entry.to_node)
        }
      end)

    %{
      balance: owner.grain_balance,
      frozen: owner.grain_frozen_balance,
      earned: to_integer(earned),
      entries: entries,
      next_cursor: next_cursor
    }
  end

  defp wallet_node(nil), do: nil
  defp wallet_node(node), do: %{id: node.id, name: node.name}

  defp wallet_user(nil), do: nil
  defp wallet_user(user), do: %{id: user.id, nickname: user.nickname, handle: user.handle}

  # 这一条 SQL 就是全部的并发控制。`grain_balance >= amount` 让扣款和余额检查
  # 在同一个原子操作里完成,不存在"查完到扣之间被插一脚"的窗口。
  defp debit(repo, user_id, amount) do
    {count, _} =
      repo.update_all(
        from(u in User, where: u.id == ^user_id and u.grain_balance >= ^amount),
        inc: [grain_balance: -amount]
      )

    if count == 1, do: {:ok, count}, else: {:error, :insufficient_balance}
  end

  defp credit(repo, user_id, amount) do
    {count, _} =
      repo.update_all(from(u in User, where: u.id == ^user_id), inc: [grain_balance: amount])

    if count == 1, do: {:ok, count}, else: {:error, :recipient_not_found}
  end

  @doc "解析转账收款人，不扣款或创建流水；联系方式查询只供认证后的转账流程使用。"
  def resolve_recipient(%User{} = user), do: {:ok, user}

  # 收款方可以用 rice 的 id、DID、handle、邮箱或手机号指定 —— 转账界面只有
  # 一个输入框,用户填什么都得认。不能把这些塞进一条 or:id 是
  # Rice.Tsid.Type,拿一个 DID 去比会在 dump 阶段直接报错。
  #
  # 注意这里确实能区分「联系方式存在 / 不存在」(找不到会报
  # recipient_not_found)。core 也是如此,而且转账本身必须给出这个反馈 ——
  # 想收敛枚举风险要靠接口限流,不是靠把错误信息含糊掉。
  def resolve_recipient(identifier) when is_binary(identifier) do
    identifier = String.trim(identifier)

    user =
      find_by_id(identifier) || find_by_did(identifier) || find_by_handle(identifier) ||
        find_by_contact(identifier)

    cond do
      is_nil(user) -> {:error, :recipient_not_found}
      not is_nil(user.disabled_at) -> {:error, :recipient_disabled}
      true -> {:ok, user}
    end
  end

  def resolve_recipient(_), do: {:error, :recipient_not_found}

  defp find_by_id(identifier) do
    if Rice.Tsid.valid?(identifier) do
      Repo.one(from u in User, where: is_nil(u.deleted_at) and u.id == ^identifier)
    end
  end

  defp find_by_did("did:" <> _ = identifier),
    do: Repo.one(from u in User, where: is_nil(u.deleted_at) and u.did == ^identifier)

  defp find_by_did(_), do: nil

  defp find_by_handle(identifier) do
    Repo.one(
      from u in User,
        where:
          is_nil(u.deleted_at) and fragment("lower(?)", u.handle) == ^String.downcase(identifier)
    )
  end

  # 邮箱大小写不敏感;手机号只比号码本身,不含区号 —— 界面上没地方填区号。
  defp find_by_contact(identifier) do
    cond do
      String.contains?(identifier, "@") ->
        Repo.one(
          from u in User,
            where:
              is_nil(u.deleted_at) and
                fragment("lower(?)", u.email) == ^String.downcase(identifier)
        )

      Regex.match?(~r/^\d{5,20}$/, identifier) ->
        case Repo.all(
               from u in User,
                 where: is_nil(u.deleted_at) and u.phone == ^identifier,
                 limit: 2
             ) do
          [user] -> user
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp ensure_not_self(%User{id: id}, %User{id: id}), do: {:error, :cannot_transfer_to_self}
  defp ensure_not_self(_, _), do: :ok

  # ── 查询 ────────────────────────────────────────────────────────────────

  @doc "我的稻米明细:收和付都算。按 id 倒序 —— TSID 的字典序就是时间序。"
  def list_transfers(%User{id: id}, params \\ %{}) do
    from(t in Transfer,
      where: t.from_user_id == ^id or t.to_user_id == ^id,
      preload: [:from_user, :to_user, :from_node, :to_node]
    )
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  @doc "后台发放记录(全站公开,原 /score-distribute-record/page)。"
  def list_grants(params \\ %{}) do
    from(t in Transfer, where: t.kind == "grant", preload: [:to_user])
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  @doc "对账用:全站可用与冻结余额之和应当等于发放总额。"
  def reconcile do
    balances =
      Repo.one(
        from u in User, where: is_nil(u.deleted_at), select: coalesce(sum(u.grain_balance), 0)
      )

    granted =
      Repo.one(from t in Transfer, where: t.kind == "grant", select: coalesce(sum(t.amount), 0))

    frozen =
      Repo.one(
        from u in User,
          where: is_nil(u.deleted_at),
          select: coalesce(sum(u.grain_frozen_balance), 0)
      )

    # Postgres 对 bigint 求和返回 numeric,Ecto 映射成 Decimal。
    # 对账数字是整数,直接转回来,免得调用方到处判类型。
    node_balances = Repo.one(from n in Node, select: coalesce(sum(n.grain_balance), 0))
    node_frozen = Repo.one(from n in Node, select: coalesce(sum(n.grain_frozen_balance), 0))
    balances = to_integer(balances) + to_integer(node_balances)
    granted = to_integer(granted)
    frozen = to_integer(frozen) + to_integer(node_frozen)

    %{balances: balances, frozen: frozen, granted: granted, ok?: balances + frozen == granted}
  end

  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_integer(n) when is_integer(n), do: n
  defp to_integer(nil), do: 0
end

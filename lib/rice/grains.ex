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

  @typedoc "个人账户是用户 id,节点账户是 `{:node, id}`。"
  @type account :: Rice.Tsid.t() | {:node, Rice.Tsid.t()}

  @doc """
  转账。`kind` 是 `reward` 或 `gift`。

  带 `request_id` 时可以安全重试:同一付款人的同一个标识只记一笔,内容一致就
  返回原来那笔,不一致返回 `:conflict`。

  返回 `{:ok, transfer}`,或 `{:error, :insufficient_balance | :recipient_not_found |
  :recipient_disabled | :cannot_transfer_to_self | :invalid_reward_post | :conflict |
  changeset}`。
  """
  @spec transfer(User.t(), User.t() | String.t(), integer(), keyword()) ::
          {:ok, Transfer.t()}
          | {:error,
             :recipient_not_found
             | :recipient_disabled
             | :cannot_transfer_to_self
             | :invalid_reward_post
             | :insufficient_balance
             | :conflict
             | Ecto.Changeset.t()}
  def transfer(%User{} = from, to_identifier, amount, opts \\ []) do
    kind = Keyword.get(opts, :kind, "gift")
    subject_uri = Keyword.get(opts, :subject_uri)

    with {:ok, to} <- resolve_recipient(to_identifier),
         :ok <- ensure_not_self(from, to),
         :ok <- ensure_reward_post(kind, to, subject_uri) do
      attrs = %{
        kind: kind,
        from_user_id: from.id,
        to_user_id: to.id,
        amount: amount,
        memo: Keyword.get(opts, :memo, "") || "",
        subject_uri: subject_uri,
        request_id: Keyword.get(opts, :request_id)
      }

      Repo.transaction(fn ->
        # 锁住付款人:同一个 request_id 的并发重试在这里排队,第二个一定看得到第一笔
        lock_business_accounts(Repo, [from.id, to.id])

        case attrs.request_id &&
               Repo.get_by(Transfer, from_user_id: from.id, request_id: attrs.request_id) do
          nil ->
            book!(attrs, from.id, to.id)

          %Transfer{to_user_id: to_id, amount: ^amount, kind: ^kind, subject_uri: ^subject_uri} =
              existing
          when to_id == to.id ->
            existing

          _ ->
            Repo.rollback(:conflict)
        end
      end)
      |> Repo.preload_ok([:from_user, :to_user])
    end
  end

  @doc "后台发放(增发)。没有付款方,总量增加。"
  @spec grant(User.t(), integer(), keyword()) ::
          {:ok, Transfer.t()}
          | {:error, :recipient_not_found | :point_issuance_required | Ecto.Changeset.t()}
  def grant(%User{} = to, amount, opts \\ []) do
    if Rice.Points.LegacyCutover.point_id() do
      {:error, :point_issuance_required}
    else
      grant_legacy(to, amount, opts)
    end
  end

  defp grant_legacy(to, amount, opts) do
    attrs = %{
      kind: "grant",
      to_user_id: to.id,
      amount: amount,
      memo: Keyword.get(opts, :memo, "") || ""
    }

    Multi.new()
    |> Multi.insert(:transfer, Transfer.changeset(%Transfer{}, attrs))
    |> Multi.run(:credit, fn repo, _ -> credit_account(repo, to.id, amount) end)
    |> Repo.transaction()
    |> case do
      {:ok, %{transfer: transfer}} -> {:ok, Repo.preload(transfer, [:from_user, :to_user])}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

  @doc "Reserve against a personal ID or {:node, id} inside the business transaction."
  @spec reserve_business(Ecto.Repo.t(), account(), pos_integer(), String.t()) ::
          {:ok, Rice.Grains.Receipt.t() | map()} | {:error, atom() | Ecto.Changeset.t()}
  def reserve_business(repo, account, amount, uri) when is_integer(amount) and amount > 0 do
    case Rice.Points.LegacyCutover.point_id() do
      nil ->
        reserve_legacy(repo, account, amount, uri)

      point_id ->
        Rice.Points.LegacyHolds.reserve(
          point_id,
          account,
          payer_actor(repo, account),
          amount,
          uri
        )
    end
  end

  defp reserve_legacy(repo, account, amount, uri) do
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

  @spec refund_business(Ecto.Repo.t(), account(), integer(), String.t()) ::
          {:ok, Rice.Grains.Receipt.t() | map()}
          | {:error, atom() | Ecto.Changeset.t()}
  def refund_business(repo, account, amount, uri),
    do: finish_or_move(repo, account, nil, amount, uri, uri, "refunded")

  @spec settle_business(Ecto.Repo.t(), account(), account(), integer(), String.t()) ::
          {:ok, Rice.Grains.Receipt.t() | map()} | {:error, atom() | Ecto.Changeset.t()}
  def settle_business(repo, account, recipient, amount, uri),
    do: finish_or_move(repo, account, recipient, amount, uri, uri, "settled")

  @doc """
  从一笔已经冻结的总额里划出 `amount`。划出的凭证记在 `outcome_uri` 上，
  冻结凭证留在 `reservation_uri`，金额不变。

  同一 `outcome_uri` 重试时，付款方、金额、收款方一致就返回原凭证，否则 `:conflict`。
  已划出的合计加上这次超过冻结总额也是 `:conflict`。`outcome_uri` 必须是
  `reservation_uri` 下面的路径，这样多次发放和一次退回才能对上同一笔冻结。
  """
  @spec draw_reservation(
          Ecto.Repo.t(),
          account(),
          account() | nil,
          pos_integer(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          {:ok, Rice.Grains.Receipt.t() | map()} | {:error, atom() | Ecto.Changeset.t()}
  def draw_reservation(repo, payer, recipient, amount, reservation_uri, outcome_uri, kind)
      when is_integer(amount) and amount > 0 and kind in ["settled", "refunded"] do
    if String.starts_with?(outcome_uri, reservation_uri <> "/") do
      finish_or_move(repo, payer, recipient, amount, reservation_uri, outcome_uri, kind)
    else
      {:error, :conflict}
    end
  end

  defp finish_or_move(repo, payer, recipient, amount, reservation, outcome, kind) do
    case Rice.Points.LegacyCutover.point_id() do
      nil ->
        finish_legacy(repo, payer, recipient, amount, reservation, outcome, kind)

      point_id ->
        move_imported(repo, point_id, payer, recipient, amount, reservation, outcome, kind)
    end
  end

  defp finish_legacy(repo, payer, recipient, amount, uri, uri, kind),
    do: finish_business(repo, payer, recipient, amount, uri, kind)

  defp finish_legacy(repo, payer, recipient, amount, reservation, outcome, kind) do
    lock_business_accounts(repo, [payer, recipient])
    reserved = repo.get_by(Rice.Grains.Receipt, subject_uri: reservation, kind: "reserved")

    if is_nil(reserved) or not matches_account?(reserved, :from, payer) do
      {:error, :grain_reservation_missing}
    else
      draw_outcome(repo, payer, recipient, amount, reservation, outcome, kind, reserved)
    end
  end

  defp move_imported(repo, point_id, payer, recipient, amount, reservation, outcome, kind) do
    alias Rice.Points.LegacyHolds

    with {:ok, hold} <- LegacyHolds.find(point_id, reservation),
         true <- LegacyHolds.owned_by?(hold, payer) do
      action = if kind == "settled", do: :settle, else: :release

      LegacyHolds.move(point_id, action, %{
        reservation_uri: reservation,
        outcome_uri: outcome,
        actor_id: payer_actor(repo, payer),
        amount: amount,
        recipient: recipient
      })
    else
      _ -> {:error, :grain_reservation_missing}
    end
  end

  defp payer_actor(repo, {:node, id}), do: repo.get!(Node, id).user_id
  defp payer_actor(_repo, id), do: id

  # All users, then all nodes, sorted by ID. Callers settling multiple applications
  # acquire the complete set first, so opposite transfers cannot reverse lock order.
  @spec lock_business_accounts(Ecto.Repo.t(), [account() | nil]) :: [[User.t() | Node.t()]]
  def lock_business_accounts(repo, accounts) do
    accounts = accounts |> Enum.reject(&is_nil/1) |> Enum.map(&account/1)

    for schema <- [User, Node],
        ids = for({^schema, id} <- accounts, do: id),
        ids != [] do
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

  defp draw_outcome(repo, payer, recipient, amount, reservation_uri, outcome_uri, kind, reserved) do
    case repo.get_by(Rice.Grains.Receipt, subject_uri: outcome_uri, kind: kind) do
      %Rice.Grains.Receipt{} = existing ->
        if existing.amount == amount and matches_account?(existing, :from, payer) and
             matches_account?(existing, :to, recipient) do
          {:ok, existing}
        else
          {:error, :conflict}
        end

      nil ->
        other_outcome? =
          repo.exists?(
            from r in Rice.Grains.Receipt,
              where: r.subject_uri == ^outcome_uri and r.kind != "reserved"
          )

        cond do
          other_outcome? ->
            {:error, :conflict}

          consumed_amount(repo, reservation_uri) + amount > reserved.amount ->
            {:error, :conflict}

          true ->
            release_business(repo, payer, recipient, amount, outcome_uri, kind)
        end
    end
  end

  # 只加总这条冻结自己名下的发放和退回。重开任务会换一条更长的冻结地址，
  # 不能把旧任务地址当成前缀，否则会把下一轮的流水算进来。
  defp consumed_amount(repo, reservation_uri) do
    prefix = reservation_uri <> "/"

    pattern =
      prefix
      |> String.replace("\\", "\\\\")
      |> String.replace("%", "\\%")
      |> String.replace("_", "\\_")
      |> Kernel.<>("%")

    repo.one(
      from r in Rice.Grains.Receipt,
        where:
          r.kind in ["settled", "refunded"] and
            fragment("? LIKE ? ESCAPE '\\'", r.subject_uri, ^pattern),
        select: coalesce(sum(r.amount), 0)
    )
    |> to_integer()
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

    query = from(a in schema, where: a.id == ^id)
    query = if schema == User, do: where(query, [u], is_nil(u.deleted_at)), else: query

    case repo.update_all(query, inc: [grain_balance: amount]) do
      {1, _} -> {:ok, :credited}
      _ -> {:error, :recipient_not_found}
    end
  end

  @doc "任何人把自己的稻米转入节点(节点的「接收稻米」);可以安全重试,从不自动迁移余额。"
  @spec fund_node(User.t(), Node.t(), term(), term()) ::
          {:ok, Transfer.t()}
          | {:error,
             :invalid_amount
             | :missing_request_id
             | :conflict
             | :insufficient_balance
             | :recipient_not_found
             | Ecto.Changeset.t()}
  def fund_node(%User{} = user, %Node{} = node, amount, request_id) do
    cond do
      not is_integer(amount) or amount <= 0 or amount > 999_999_999 ->
        {:error, :invalid_amount}

      not is_binary(request_id) or byte_size(request_id) not in 1..128 ->
        {:error, :missing_request_id}

      true ->
        Repo.transaction(fn ->
          lock_business_accounts(Repo, [user.id, {:node, node.id}])
          uri = "rice://nodes/#{node.id}/fund/#{request_id}"

          existing =
            Repo.get_by(Transfer, kind: "community_fund", from_user_id: user.id, subject_uri: uri)

          cond do
            existing && existing.amount == amount ->
              existing

            existing ->
              Repo.rollback(:conflict)

            true ->
              book!(
                %{
                  kind: "community_fund",
                  from_user_id: user.id,
                  to_node_id: node.id,
                  amount: amount,
                  subject_uri: uri,
                  memo: "转入节点稻米"
                },
                user.id,
                {:node, node.id}
              )
          end
        end)
    end
  end

  @doc """
  节点管理员把节点账户里的稻米发给某人(节点的「发放稻米」)。
  带 `request_id` 可以安全重试:同一节点的同一个标识只记一笔。
  """
  @spec send_from_node(User.t(), Node.t(), User.t() | String.t(), pos_integer(), keyword()) ::
          {:ok, Transfer.t()}
          | {:error,
             :forbidden
             | :recipient_not_found
             | :recipient_disabled
             | :insufficient_balance
             | :conflict
             | Ecto.Changeset.t()}
  def send_from_node(%User{} = admin, %Node{} = node, to_identifier, amount, opts \\ []) do
    request_id = Keyword.get(opts, :request_id)

    with {:ok, to} <- resolve_recipient(to_identifier) do
      Repo.transaction(fn ->
        lock_business_accounts(Repo, [to.id, {:node, node.id}])

        unless Rice.Community.admin?(Repo.get!(Node, node.id), admin),
          do: Repo.rollback(:forbidden)

        case request_id && Repo.get_by(Transfer, from_node_id: node.id, request_id: request_id) do
          nil ->
            book!(
              %{
                kind: "gift",
                from_node_id: node.id,
                actor_id: admin.id,
                to_user_id: to.id,
                amount: amount,
                memo: Keyword.get(opts, :memo, "") || "",
                request_id: request_id
              },
              {:node, node.id},
              to.id
            )

          %Transfer{to_user_id: to_id, amount: ^amount} = existing when to_id == to.id ->
            existing

          _ ->
            Repo.rollback(:conflict)
        end
      end)
      |> Repo.preload_ok([:from_user, :to_user, :from_node, :to_node])
    end
  end

  @doc "Reads the wallet balance from the configured ledger."
  @spec balances(User.t() | Node.t()) :: {integer(), integer()}
  def balances(%{grain_balance: available, grain_frozen_balance: held} = owner) do
    case Rice.Points.LegacyCutover.point_id() do
      nil ->
        {available, held}

      point_id ->
        type = if is_struct(owner, Node), do: "node", else: "user"

        Repo.one(
          from account in Rice.Points.Account,
            join: balance in Rice.Points.Balance,
            on: balance.account_id == account.id,
            where:
              account.point_id == ^point_id and account.owner_type == ^type and
                account.owner_id == ^owner.id,
            select: {balance.available, balance.held}
        ) || {0, 0}
    end
  end

  @spec wallet(User.t() | Node.t(), map()) :: %{
          balance: integer(),
          frozen: integer(),
          earned: integer(),
          entries: [map()],
          next_cursor: Rice.Tsid.t() | nil
        }
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

    points = point_wallet_history(owner, opts)
    legacy = Enum.map(transfers.entries ++ receipts.entries, &legacy_wallet_entry/1)
    combined = Enum.sort_by(legacy ++ points.entries, & &1.id, :desc)
    entries = Enum.take(combined, opts.limit)

    more? =
      length(combined) > opts.limit or transfers.next_cursor != nil or
        receipts.next_cursor != nil or points.next_cursor != nil

    next_cursor = if more? and entries != [], do: List.last(entries).id

    {available, held} = balances(owner)

    %{
      balance: available,
      frozen: held,
      earned: to_integer(earned) + points.earned,
      entries: entries,
      next_cursor: next_cursor
    }
  end

  defp legacy_wallet_entry(entry) do
    %{
      id: entry.id,
      kind: entry.kind,
      amount: entry.amount,
      memo: Map.get(entry, :memo),
      subject_uri: entry.subject_uri,
      inserted_at: entry.inserted_at,
      from_user: wallet_user(entry.from_user),
      to_user: wallet_user(entry.to_user),
      from_node: wallet_node(entry.from_node),
      to_node: wallet_node(entry.to_node)
    }
  end

  defp point_wallet_history(owner, opts) do
    alias Rice.Points.{Entry, Transaction}

    with point_id when is_binary(point_id) <- Rice.Points.LegacyCutover.point_id(),
         {:ok, account} <-
           point_account(
             point_id,
             if(is_struct(owner, Node), do: {:node, owner.id}, else: owner.id)
           ) do
      entries = from e in Entry, where: e.account_id == ^account.id

      posted =
        from t in Transaction,
          where:
            t.point_id == ^point_id and t.kind not in ["legacy_opening", "legacy_opening_hold"],
          where: t.id in subquery(from e in entries, select: e.transaction_id)

      page = Pagination.paginate(posted, Repo, opts)
      ids = Enum.map(page.entries, & &1.id)

      by_transaction =
        Repo.all(from e in Entry, where: e.transaction_id in ^ids, preload: [:account])
        |> Enum.group_by(& &1.transaction_id)

      earned =
        Repo.one(
          from e in entries,
            join: t in Transaction,
            on: t.id == e.transaction_id,
            where:
              e.bucket == "available" and e.delta > 0 and
                t.kind not in ["legacy_opening", "legacy_opening_hold", "hold_release"],
            select: coalesce(sum(e.delta), 0)
        )

      %{
        page
        | entries:
            Enum.map(page.entries, fn t ->
              point_wallet_entry(t, account.id, Map.fetch!(by_transaction, t.id))
            end)
      }
      |> Map.put(:earned, to_integer(earned))
    else
      _ -> %{entries: [], next_cursor: nil, earned: 0}
    end
  end

  defp point_wallet_entry(tx, account_id, entries) do
    owned = Enum.filter(entries, &(&1.account_id == account_id))
    available = Enum.sum(for entry <- owned, entry.bucket == "available", do: entry.delta)
    held = Enum.sum(for entry <- owned, entry.bucket == "held", do: entry.delta)
    incoming? = available > 0 and tx.kind != "hold_release"
    own = hd(owned).account

    counterparty =
      if incoming? do
        Enum.find(entries, &(&1.delta < 0 and &1.account_id != account_id))
      else
        entries
        |> Enum.filter(&(&1.delta > 0 and &1.account_id != account_id))
        |> Enum.uniq_by(& &1.account_id)
        |> case do
          [entry] -> entry
          _ -> nil
        end
      end

    other = if counterparty, do: counterparty.account
    {from_user, from_node} = wallet_point_party(if incoming?, do: other, else: own)
    {to_user, to_node} = wallet_point_party(if incoming?, do: own, else: other)

    %{
      id: tx.id,
      kind: point_wallet_kind(tx),
      amount: abs(if available == 0, do: held, else: available),
      memo: tx.public_note,
      subject_uri: if(tx.reference_type in ["reward", "community_fund"], do: tx.reference_id),
      inserted_at: tx.inserted_at,
      from_user: from_user,
      from_node: from_node,
      to_user: to_user,
      to_node: to_node
    }
  end

  defp point_wallet_kind(%{kind: kind}) when kind in ["hold_reserve", "approved_hold_reserve"],
    do: "reserved"

  defp point_wallet_kind(%{kind: "hold_release"}), do: "refunded"
  defp point_wallet_kind(%{kind: "hold_settle"}), do: "task_reward"
  defp point_wallet_kind(%{kind: kind}) when kind in ["mint", "initial_allocation"], do: "grant"

  defp point_wallet_kind(%{reference_type: type}) when type in ["reward", "community_fund"],
    do: type

  defp point_wallet_kind(_), do: "gift"

  defp wallet_point_party(%{owner_type: "user", owner_id: id}),
    do: {wallet_user(Repo.get(User, id)), nil}

  defp wallet_point_party(%{owner_type: "node", owner_id: id}),
    do: {nil, wallet_node(Repo.get(Node, id))}

  defp wallet_point_party(_), do: {nil, nil}

  defp wallet_node(nil), do: nil
  defp wallet_node(node), do: %{id: node.id, name: node.name}

  defp wallet_user(nil), do: nil
  defp wallet_user(user), do: %{id: user.id, nickname: user.nickname, handle: user.handle}

  # 付款(个人或节点):记流水、扣付款人、给收款账户入账,任何一步失败整个事务回滚。
  defp book!(attrs, payer, recipient) do
    case Rice.Points.LegacyCutover.point_id() do
      nil -> book_legacy!(attrs, payer, recipient)
      point_id -> book_point!(point_id, attrs, payer, recipient)
    end
  end

  defp book_point!(point_id, attrs, payer, recipient) do
    with {:ok, payer_account} <- point_account(point_id, payer),
         {:ok, payee_account} <- Rice.Points.WalletAccounts.ensure_recipient(point_id, recipient),
         {:ok, tx} <-
           Rice.Points.transfer(%{
             payer_account_id: payer_account.id,
             actor_id: Map.get(attrs, :actor_id) || payer_actor(Repo, payer),
             idempotency_key: point_transfer_key(attrs),
             public_note: Map.get(attrs, :memo),
             reference_type: attrs.kind,
             reference_id: Map.get(attrs, :subject_uri),
             recipients: [%{account_id: payee_account.id, amount: attrs.amount}]
           }) do
      struct(
        Transfer,
        Map.merge(Map.drop(attrs, [:actor_id]), %{id: tx.id, inserted_at: tx.inserted_at})
      )
    else
      {:error, :idempotency_conflict} -> Repo.rollback(:conflict)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp point_transfer_key(%{kind: "community_fund", subject_uri: uri}) do
    "fund:" <> Base.url_encode64(:crypto.hash(:sha256, uri), padding: false)
  end

  defp point_transfer_key(attrs), do: Map.get(attrs, :request_id) || Rice.Tsid.generate()

  defp point_account(point_id, owner), do: Rice.Points.WalletAccounts.fetch(point_id, owner)

  defp book_legacy!(%{amount: amount} = attrs, payer, recipient) do
    with {:ok, transfer} <- Repo.insert(Transfer.changeset(%Transfer{}, attrs)),
         {:ok, _} <- debit(Repo, payer, amount),
         {:ok, _} <- credit_account(Repo, recipient, amount) do
      transfer
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # 这一条 SQL 就是全部的并发控制。`grain_balance >= amount` 让扣款和余额检查
  # 在同一个原子操作里完成,不存在"查完到扣之间被插一脚"的窗口。
  defp debit(repo, payer, amount) do
    {schema, id} = account(payer)

    {count, _} =
      repo.update_all(
        from(a in schema, where: a.id == ^id and a.grain_balance >= ^amount),
        inc: [grain_balance: -amount]
      )

    if count == 1, do: {:ok, count}, else: {:error, :insufficient_balance}
  end

  @doc "解析转账收款人，不扣款或创建流水；联系方式查询只供认证后的转账流程使用。"
  @spec resolve_recipient(term()) ::
          {:ok, User.t()} | {:error, :recipient_not_found | :recipient_disabled}
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

    user = Rice.Accounts.get_public_user(identifier) || find_by_contact(identifier)

    cond do
      is_nil(user) -> {:error, :recipient_not_found}
      not is_nil(user.disabled_at) -> {:error, :recipient_disabled}
      true -> {:ok, user}
    end
  end

  def resolve_recipient(_), do: {:error, :recipient_not_found}

  @doc """
  转账界面「送给谁」的找人:先按 `resolve_recipient/1` 精确找;找不到再按昵称 /
  handle 模糊找,不含自己和停用账号,最多 10 个。

  昵称或 handle 第一段(`harold.web5.xjdao.net` 的 `harold`)整个相同的排最前,
  其次是前缀匹配。整个相同的只有一个人时也算精确 —— 只回他,不再列别的候选。
  """
  @spec search_recipients(User.t(), term()) ::
          {:ok, %{exact: boolean(), users: [User.t()]}} | {:error, :recipient_disabled}
  def search_recipients(%User{} = viewer, q) do
    q = if is_binary(q), do: String.trim(q), else: ""

    case resolve_recipient(q) do
      {:ok, user} ->
        {:ok, %{exact: true, users: [Repo.preload(user, :avatar)]}}

      {:error, :recipient_not_found} when q != "" ->
        {:ok, fuzzy_recipients(viewer, q)}

      {:error, :recipient_not_found} ->
        {:ok, %{exact: false, users: []}}

      error ->
        error
    end
  end

  defp fuzzy_recipients(viewer, q) do
    lower = String.downcase(q)
    pattern = Repo.contains(q)
    prefix = String.replace_prefix(pattern, "%", "")

    ranked =
      Repo.all(
        from u in User,
          where:
            is_nil(u.deleted_at) and is_nil(u.disabled_at) and u.id != ^viewer.id and
              (ilike(u.nickname, ^pattern) or ilike(u.handle, ^pattern)),
          select: %{
            rank:
              fragment(
                "CASE WHEN lower(?) = ? OR split_part(lower(?), '.', 1) = ? THEN 0 WHEN ? ILIKE ? OR ? ILIKE ? THEN 1 ELSE 2 END",
                u.nickname,
                ^lower,
                u.handle,
                ^lower,
                u.nickname,
                ^prefix,
                u.handle,
                ^prefix
              )
              |> selected_as(:rank),
            user: u
          },
          order_by: [selected_as(:rank), u.handle],
          limit: 10
      )

    users = Repo.preload(Enum.map(ranked, & &1.user), :avatar)

    case Enum.count(ranked, &(&1.rank == 0)) do
      1 -> %{exact: true, users: [hd(users)]}
      _ -> %{exact: false, users: users}
    end
  end

  @doc "是不是按手机号 / 邮箱找人 —— 这类查询等于问\"这个号是谁\",调用方要限流。"
  @spec contact_identifier?(term()) :: boolean()
  def contact_identifier?(identifier) when is_binary(identifier) do
    identifier = String.trim(identifier)
    String.contains?(identifier, "@") or Regex.match?(~r/^\d{5,20}$/, identifier)
  end

  def contact_identifier?(_), do: false

  # 不同于 `Accounts.find_user/1`:停用的人也要找出来(好报 recipient_disabled)。
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

  defp ensure_reward_post("reward", _, uri) when uri in [nil, ""], do: :ok

  defp ensure_reward_post("reward", %User{did: did}, uri) when is_binary(uri) do
    case String.split(uri, "/") do
      ["at:", "", ^did, "app.bsky.feed.post", rkey] when rkey != "" ->
        if String.contains?(rkey, ["?", "#"]), do: {:error, :invalid_reward_post}, else: :ok

      _ ->
        {:error, :invalid_reward_post}
    end
  end

  defp ensure_reward_post("reward", _, _), do: {:error, :invalid_reward_post}
  defp ensure_reward_post(_, _, _), do: :ok

  # ── 查询 ────────────────────────────────────────────────────────────────

  @doc "我的稻米明细:收和付都算。按 id 倒序 —— TSID 的字典序就是时间序。"
  @spec list_transfers(User.t(), map()) :: Pagination.page(Transfer.t())
  def list_transfers(%User{id: id}, params \\ %{}) do
    from(t in Transfer,
      where: t.from_user_id == ^id or t.to_user_id == ^id,
      preload: [:from_user, :to_user, :from_node, :to_node]
    )
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  @doc "后台发放记录(全站公开,原 /score-distribute-record/page)。"
  @spec list_grants(map()) :: Pagination.page(Transfer.t())
  def list_grants(params \\ %{}) do
    from(t in Transfer, where: t.kind == "grant", preload: [:to_user, :to_node])
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  @doc "已发行稻米总量，以发放流水为准。"
  @spec total_granted() :: integer()
  def total_granted do
    Repo.one(from t in Transfer, where: t.kind == "grant", select: coalesce(sum(t.amount), 0))
    |> to_integer()
  end

  @doc "对账用:全站可用与冻结余额之和应当等于发放总额。"
  @spec reconcile() :: %{
          balances: integer(),
          frozen: integer(),
          granted: integer(),
          ok?: boolean()
        }
  def reconcile do
    # A lifecycle flag must not erase financial liabilities from reconciliation,
    # including balances on accounts retired before the current safeguards.
    {user_balances, user_frozen} = sum_balances(User)
    {node_balances, node_frozen} = sum_balances(Node)
    balances = user_balances + node_balances
    frozen = user_frozen + node_frozen
    granted = total_granted()

    %{balances: balances, frozen: frozen, granted: granted, ok?: balances + frozen == granted}
  end

  defp sum_balances(query) do
    {balances, frozen} =
      Repo.one(
        from a in query,
          select: {coalesce(sum(a.grain_balance), 0), coalesce(sum(a.grain_frozen_balance), 0)}
      )

    {to_integer(balances), to_integer(frozen)}
  end

  # Postgres 对 bigint 求和返回 numeric,Ecto 映射成 Decimal。
  # 对账数字是整数,直接转回来,免得调用方到处判类型。
  defp to_integer(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_integer(n) when is_integer(n), do: n
  defp to_integer(nil), do: 0
end

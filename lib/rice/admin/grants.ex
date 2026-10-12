defmodule Rice.Admin.Grants do
  @moduledoc """
  后台发放稻米。

  增发对象只能是节点，不向用户个人账户增发。历史个人增发流水保留用于对账。

  **全有或全无**:任何一个收款人解析不出来,整批都不发。
  core 也是这个语义(数量对不上就抛异常),但它是在拿到分布式锁之后才发现的。
  """
  import Ecto.Query

  alias Rice.Admin.AdminUser
  alias Rice.Community.Node
  alias Rice.Grains.Transfer
  alias Rice.{Pagination, Repo}

  # nodes.grain_balance and grain_transfers.amount are PostgreSQL bigint.
  @max_bigint 9_223_372_036_854_775_807

  @doc "批量向节点增发。同一管理员的请求标识可安全重试；整批全有或全无。"
  @spec grant_nodes(AdminUser.t(), term(), term(), term(), term(), keyword()) ::
          {:ok, non_neg_integer(), :created | :replayed}
          | {:error,
             :unprocessable_entity
             | :invalid_amount
             | :missing_request_id
             | :not_found
             | :conflict
             | :contact_not_set
             | Rice.Accounts.code_error()
             | Ecto.Changeset.t()}
  def grant_nodes(admin, ids, amount, request_id, code, opts \\ []) do
    with :ok <- validate_node_ids(ids),
         :ok <- validate_node_amount(amount),
         :ok <- validate_request_id(request_id) do
      ids = Enum.sort(Enum.uniq(ids))
      memo = Keyword.get(opts, :memo) || ""
      prefix = "rice://node-grants/#{admin.id}/#{Base.url_encode64(request_id, padding: false)}/"

      Repo.transaction(fn ->
        # 同一管理员的批次先排队，确保更换节点名单的重试也能识别为冲突。
        Repo.one!(from a in AdminUser, where: a.id == ^admin.id, lock: "FOR UPDATE")
        nodes = Repo.all(from n in Node, where: n.id in ^ids, order_by: n.id, lock: "FOR UPDATE")
        if length(nodes) != length(ids), do: Repo.rollback(:not_found)

        changesets =
          Enum.map(nodes, fn node ->
            cs =
              Transfer.changeset(%Transfer{}, %{
                kind: "grant",
                to_node_id: node.id,
                amount: amount,
                memo: memo,
                subject_uri: prefix <> node.id
              })

            case Ecto.Changeset.apply_action(cs, :insert) do
              {:ok, _} -> cs
              {:error, invalid} -> Repo.rollback(invalid)
            end
          end)

        memo = Ecto.Changeset.get_field(hd(changesets), :memo)

        existing =
          Repo.all(
            from t in Transfer,
              where:
                t.kind == "grant" and
                  fragment("left(?, ?) = ?", t.subject_uri, ^String.length(prefix), ^prefix)
          )

        cond do
          existing != [] ->
            same? =
              Enum.sort(Enum.map(existing, & &1.to_node_id)) == ids and
                Enum.all?(existing, &(&1.amount == amount and &1.memo == memo))

            if same?, do: {length(ids), :replayed}, else: Repo.rollback(:conflict)

          Enum.any?(nodes, &(&1.grain_balance > @max_bigint - amount)) ->
            Repo.rollback(:invalid_amount)

          true ->
            case Rice.Admin.verify_grant_code(admin, code) do
              :ok ->
                Enum.each(changesets, fn cs ->
                  case Repo.insert(cs) do
                    {:ok, _} -> :ok
                    {:error, reason} -> Repo.rollback(reason)
                  end
                end)

                {count, _} =
                  Repo.update_all(from(n in Node, where: n.id in ^ids),
                    inc: [grain_balance: amount]
                  )

                if count != length(ids), do: Repo.rollback(:not_found)
                {count, :created}

              {:error, reason} ->
                {:verification_error, reason}
            end
        end
      end)
      |> case do
        {:ok, {:verification_error, reason}} -> {:error, reason}
        {:ok, {count, status}} -> {:ok, count, status}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_node_ids(ids) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &Rice.Tsid.valid?/1), do: :ok, else: {:error, :unprocessable_entity}
  end

  defp validate_node_ids(_), do: {:error, :unprocessable_entity}

  @doc """
  管理员向节点账户发放稻米。`client_request_id` 在同一管理员、节点下标识一次发放。

  锁住节点后先检查流水，再消费一次性验证码。重试相同请求返回原流水，不会
  再增加余额；同一请求标识对应不同金额或备注则返回冲突。
  """
  @spec grant_node(AdminUser.t(), String.t(), term(), term(), String.t() | nil, keyword()) ::
          {:ok, Transfer.t(), :created | :replayed}
          | {:error,
             :not_found
             | :invalid_amount
             | :missing_request_id
             | :conflict
             | :contact_not_set
             | Rice.Accounts.code_error()
             | Ecto.Changeset.t()}
  def grant_node(%AdminUser{} = admin, node_id, amount, request_id, code, opts \\ []) do
    memo = Keyword.get(opts, :memo) || ""

    with :ok <- validate_node_id(node_id),
         :ok <- validate_node_amount(amount),
         :ok <- validate_request_id(request_id),
         {:ok, changeset} <- node_grant_changeset(admin, node_id, amount, request_id, memo) do
      memo = Ecto.Changeset.get_field(changeset, :memo)

      Repo.transaction(fn ->
        node = Repo.one(from n in Node, where: n.id == ^node_id, lock: "FOR UPDATE")
        if is_nil(node), do: Repo.rollback(:not_found)

        uri = Ecto.Changeset.get_field(changeset, :subject_uri)
        existing = Repo.get_by(Transfer, kind: "grant", to_node_id: node.id, subject_uri: uri)

        cond do
          existing && existing.amount == amount && existing.memo == memo ->
            {existing, :replayed}

          existing ->
            Repo.rollback(:conflict)

          node.grain_balance > @max_bigint - amount ->
            Repo.rollback(:invalid_amount)

          true ->
            case Rice.Admin.verify_grant_code(admin, code) do
              :ok ->
                with {:ok, transfer} <- Repo.insert(changeset),
                     {1, _} <-
                       Repo.update_all(
                         from(n in Node, where: n.id == ^node.id),
                         inc: [grain_balance: amount]
                       ) do
                  {transfer, :created}
                else
                  {:error, reason} -> Repo.rollback(reason)
                  _ -> Repo.rollback(:not_found)
                end

              {:error, reason} ->
                # Keep a failed verification's attempt counter; no money was touched.
                {:verification_error, reason}
            end
        end
      end)
      |> case do
        {:ok, {:verification_error, reason}} -> {:error, reason}
        {:ok, {transfer, status}} -> {:ok, transfer, status}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_node_id(id) do
    if Rice.Tsid.valid?(id), do: :ok, else: {:error, :not_found}
  end

  defp validate_node_amount(amount)
       when is_integer(amount) and amount > 0 and amount <= @max_bigint,
       do: :ok

  defp validate_node_amount(_), do: {:error, :invalid_amount}

  defp validate_request_id(id) when is_binary(id) and byte_size(id) in 1..128 do
    if String.trim(id) == "", do: {:error, :missing_request_id}, else: :ok
  end

  defp validate_request_id(_), do: {:error, :missing_request_id}

  defp node_grant_changeset(admin, node_id, amount, request_id, memo) do
    uri = "rice://nodes/#{node_id}/grants/#{admin.id}/#{request_id}"

    changeset =
      Transfer.changeset(%Transfer{}, %{
        kind: "grant",
        to_node_id: node_id,
        amount: amount,
        memo: memo,
        subject_uri: uri
      })

    case Ecto.Changeset.apply_action(changeset, :insert) do
      {:ok, _} -> {:ok, changeset}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "发放记录。可按收款人和时间范围筛。"
  @spec list_grants(map()) :: Pagination.page(Transfer.t())
  def list_grants(params \\ %{}) do
    from(t in Transfer,
      where: t.kind == "grant",
      preload: [to_user: :avatar, to_node: []]
    )
    |> filter_recipient(params["q"])
    |> Repo.inserted_between(params["since"], params["until"])
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  defp filter_recipient(query, q) when is_binary(q) and q != "" do
    pattern = Repo.contains(q)

    from t in query,
      left_join: u in assoc(t, :to_user),
      left_join: n in assoc(t, :to_node),
      where:
        ilike(u.nickname, ^pattern) or ilike(u.email, ^pattern) or ilike(u.phone, ^pattern) or
          ilike(u.handle, ^pattern) or ilike(n.name, ^pattern) or ilike(n.id, ^pattern)
  end

  defp filter_recipient(query, _), do: query
end

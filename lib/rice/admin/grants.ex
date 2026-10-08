defmodule Rice.Admin.Grants do
  @moduledoc """
  后台发放稻米。

  core 有 single 和 batch 两个接口:single 收一个手机号/邮箱,batch 收一个
  上传文件的 fileId、由服务端去解析。这里只有一个接口,收一个收款人数组 ——
  解析 Excel 是前端的事,服务端不该为了一个功能长出一个表格解析器。

  **全有或全无**:任何一个收款人解析不出来,整批都不发。
  core 也是这个语义(数量对不上就抛异常),但它是在拿到分布式锁之后才发现的。
  """
  import Ecto.Query

  alias Rice.Accounts.User
  alias Rice.Admin.AdminUser
  alias Rice.Community.Node
  alias Rice.Grains.Transfer
  alias Rice.{Pagination, Repo}

  # nodes.grain_balance and grain_transfers.amount are PostgreSQL bigint.
  @max_bigint 9_223_372_036_854_775_807

  @doc """
  校验一批发放请求,但**不动账**。返回解析好的收款人。

  单独拿出来是为了让调用方能在验短信码之前先把参数问题挑出来。验证码是一次性的,
  而发放又常常是粘一列几百个手机号 —— 要是先验码再校验收款人,一个笔误就把码烧掉了,
  还得等 60 秒重发。先校验参数(不写任何东西),码留到真要动账的时候再验。
  """
  @spec prepare(term(), term()) ::
          {:ok, [User.t()]}
          | {:error,
             :no_recipients
             | :invalid_amount
             | {:unknown_recipients, [String.t()]}
             | {:invalid_recipients, [term()]}}
  def prepare(recipients, amount) when is_list(recipients) and recipients != [] do
    with :ok <- validate_amount(amount) do
      case Rice.Accounts.find_users(recipients) do
        {:ok, []} -> {:error, :no_recipients}
        result -> result
      end
    end
  end

  def prepare(_, _), do: {:error, :no_recipients}

  @doc "把 `prepare/2` 解析出来的收款人真正入账。一个事务:要么每个人都到账,要么一个都不动。"
  @spec credit([User.t()], pos_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, Ecto.Changeset.t()}
  def credit(users, amount, opts \\ []) do
    memo = Keyword.get(opts, :memo, "") || ""

    users
    |> Enum.reduce(Ecto.Multi.new(), fn user, multi ->
      changeset =
        Transfer.changeset(%Transfer{}, %{
          kind: "grant",
          to_user_id: user.id,
          amount: amount,
          memo: memo
        })

      multi
      |> Ecto.Multi.insert({:transfer, user.id}, changeset)
      |> Ecto.Multi.update_all(
        {:credit, user.id},
        from(u in User, where: u.id == ^user.id),
        inc: [grain_balance: amount]
      )
    end)
    |> Repo.transaction()
    |> case do
      {:ok, _} -> {:ok, length(users)}
      {:error, _step, reason, _} -> {:error, reason}
    end
  end

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

  defp validate_amount(amount) when is_integer(amount) and amount > 0, do: :ok
  defp validate_amount(_), do: {:error, :invalid_amount}

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

defmodule Rice.Admin.Users do
  @moduledoc """
  后台的用户管理。

  core 有 9 个接口做这件事(user/page、node-user/page、search、search-by-name、
  unbound-node-user-search、enable、disable、set-node-user、cancel-node-user)。
  前 5 个是同一个列表的不同过滤,后 4 个是同一行的两个布尔位。Task V1
  又在同一个 PATCH 增加 `can_publish_tasks`，不另造权限接口。
  """
  import Ecto.Query

  alias Rice.Accounts.User
  alias Rice.{Pagination, Repo}

  @doc """
  用户列表。过滤都走 query 参数:

    * `q` —— 昵称 / handle / DID / 邮箱 / 手机号,模糊匹配
    * `node_member` —— `"true"` 只看节点用户,`"false"` 只看非节点用户
    * `disabled` —— `"true"` 只看已停用
  """
  def list_users(params \\ %{}) do
    from(u in User, where: is_nil(u.deleted_at), preload: [:avatar])
    |> search(params["q"])
    |> filter_bool(:node_member, params["node_member"])
    |> filter_disabled(params["disabled"])
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  defp search(query, q) when is_binary(q) and q != "" do
    # 用户自己输入的串会进 LIKE,`%` 和 `_` 必须转义,否则一个 "%" 就是全表
    pattern = "%" <> escape_like(String.trim(q)) <> "%"

    from u in query,
      where:
        ilike(u.nickname, ^pattern) or ilike(u.handle, ^pattern) or
          ilike(u.did, ^pattern) or ilike(u.email, ^pattern) or ilike(u.phone, ^pattern)
  end

  defp search(query, _), do: query

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp filter_bool(query, field, "true"), do: from(u in query, where: field(u, ^field) == true)
  defp filter_bool(query, field, "false"), do: from(u in query, where: field(u, ^field) == false)
  defp filter_bool(query, _field, _), do: query

  defp filter_disabled(query, "true"), do: from(u in query, where: not is_nil(u.disabled_at))
  defp filter_disabled(query, "false"), do: from(u in query, where: is_nil(u.disabled_at))
  defp filter_disabled(query, _), do: query

  def fetch_user(id) do
    case Rice.Accounts.get_user(id) do
      nil -> {:error, :not_found}
      user -> {:ok, user}
    end
  end

  @doc """
  改用户的管理位:`disabled`、`node_member` 和 `can_publish_tasks`。

  停用会**同时撤销该用户的全部令牌** —— core 只改标记,手上的 JWT
  还能用满 30 天,等于"禁用"要等一个月才生效。
  """
  def update_user(%User{} = user, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    changes =
      %{}
      |> put_disabled(attrs["disabled"], user)
      |> put_node_member(attrs["node_member"])
      |> put_task_publisher(attrs["can_publish_tasks"])

    if changes == %{} do
      {:error, :no_changes}
    else
      Ecto.Multi.new()
      |> Ecto.Multi.update(:user, Ecto.Changeset.change(user, changes))
      |> maybe_revoke(changes)
      |> Repo.transaction()
      |> case do
        {:ok, %{user: user}} -> {:ok, Repo.preload(user, :avatar)}
        {:error, _, reason, _} -> {:error, reason}
      end
    end
  end

  defp put_disabled(changes, true, %User{disabled_at: nil}),
    do: Map.put(changes, :disabled_at, DateTime.utc_now())

  defp put_disabled(changes, false, _user), do: Map.put(changes, :disabled_at, nil)
  defp put_disabled(changes, _, _user), do: changes

  defp put_node_member(changes, value) when is_boolean(value),
    do: Map.put(changes, :node_member, value)

  defp put_node_member(changes, _), do: changes

  defp put_task_publisher(changes, value) when is_boolean(value),
    do: Map.put(changes, :can_publish_tasks, value)

  defp put_task_publisher(changes, _), do: changes

  defp maybe_revoke(multi, %{disabled_at: %DateTime{}}) do
    Ecto.Multi.run(multi, :revoke, fn _repo, %{user: user} ->
      Rice.Accounts.revoke_all_tokens(user)
    end)
  end

  defp maybe_revoke(multi, _), do: multi
end

defmodule Rice.Community do
  @moduledoc "节点与勋章。"
  import Ecto.Query

  alias Rice.Accounts.User
  alias Rice.Community.{Badge, BadgeAward, JoinApplication, Membership, Node}
  alias Rice.{Pagination, Repo}

  # ── 节点 ────────────────────────────────────────────────────────────────

  def admin?(%Node{user_id: id}, %User{id: id}), do: true

  def admin?(%Node{id: node_id}, %User{id: user_id}),
    do:
      Repo.exists?(
        from m in Membership,
          where: m.node_id == ^node_id and m.user_id == ^user_id and m.role == "admin"
      )

  def admin?(_node, _user), do: false

  def managed_node_ids(%User{id: user_id}) do
    memberships =
      from m in Membership, where: m.user_id == ^user_id and m.role == "admin", select: m.node_id

    Repo.all(
      from n in Node, where: n.user_id == ^user_id or n.id in subquery(memberships), select: n.id
    )
  end

  def managed_node_ids(_), do: []

  def admin_ids(%Node{} = node) do
    members =
      Repo.all(
        from m in Membership,
          where: m.node_id == ^node.id and m.role == "admin",
          select: m.user_id
      )

    Enum.uniq(Enum.reject([node.user_id | members], &is_nil/1))
  end

  def set_member_role(%User{} = user, %Node{} = node, user_id, role)
      when role in ~w(admin member) do
    if Rice.Tsid.valid?(user_id) do
      Repo.transaction(fn ->
        node = Repo.one!(from n in Node, where: n.id == ^node.id, lock: "FOR UPDATE")
        if node.user_id != user.id or node.user_id == user_id, do: Repo.rollback(:forbidden)
        member = Repo.get_by(Membership, node_id: node.id, user_id: user_id)
        if is_nil(member), do: Repo.rollback(:not_found)

        member
        |> Ecto.Changeset.change(role: role)
        |> Membership.changeset()
        |> Repo.update()
        |> write_result!()
      end)
    else
      {:error, :not_found}
    end
  end

  def set_member_role(_user, _node, _user_id, _role), do: {:error, :unprocessable_entity}

  @doc "公开目录附带本人身份；申请读取范围仅本人或本节点管理员。"
  def list_nodes(user \\ nil, params \\ %{}) do
    from(n in Node, order_by: [asc: n.position, asc: n.id])
    |> filter_node_query(params["q"])
    |> filter_node_identity(user, params["mine"])
    |> Repo.all()
    |> preload_nodes(user)
  end

  def fetch_node(id, user \\ nil) do
    with true <- Rice.Tsid.valid?(id), %Node{} = node <- Repo.get(Node, id) do
      {:ok, preload_nodes(node, user)}
    else
      _ -> {:error, :not_found}
    end
  end

  defp preload_nodes(nodes, user) do
    applications =
      from a in JoinApplication,
        order_by: [desc: a.id],
        preload: [user: :avatar]

    applications =
      if user do
        managed_ids = managed_node_ids(user)
        from a in applications, where: a.user_id == ^user.id or a.node_id in ^managed_ids
      else
        from a in applications, where: false
      end

    Repo.preload(nodes, [
      :logo,
      user: :avatar,
      memberships: [user: :avatar],
      applications: applications
    ])
  end

  defp filter_node_query(query, q) when is_binary(q) and q != "" do
    pattern = "%" <> String.replace(String.trim(q), ["\\", "%", "_"], &"\\#{&1}") <> "%"
    from n in query, where: ilike(n.name, ^pattern) or ilike(n.description, ^pattern)
  end

  defp filter_node_query(query, _), do: query

  defp filter_node_identity(query, nil, mine) when mine in ~w(joined pending managed identity),
    do: from(n in query, where: false)

  defp filter_node_identity(query, %User{id: user_id}, mine)
       when mine in ~w(joined pending managed identity) do
    memberships = from m in Membership, where: m.user_id == ^user_id, select: m.node_id

    pending =
      from a in JoinApplication,
        where: a.user_id == ^user_id and a.status == "pending",
        select: a.node_id

    case mine do
      "managed" ->
        ids = managed_node_ids(%User{id: user_id})
        from n in query, where: n.id in ^ids

      "joined" ->
        from n in query, where: n.user_id == ^user_id or n.id in subquery(memberships)

      "pending" ->
        from n in query, where: n.id in subquery(pending)

      "identity" ->
        from n in query,
          where:
            n.user_id == ^user_id or n.id in subquery(memberships) or n.id in subquery(pending)
    end
  end

  defp filter_node_identity(query, _, _), do: query

  @doc "入会申请与审批按节点加锁，重复提交返回原待审记录。"
  # ponytail: serialize joins per node; use per-applicant locks if node traffic grows.
  def apply_to_node(%User{} = user, %Node{} = node, attrs) do
    Repo.transaction(fn ->
      node = Repo.one!(from n in Node, where: n.id == ^node.id, lock: "FOR UPDATE")

      cond do
        is_nil(node.user_id) ->
          Repo.rollback(:forbidden)

        node.user_id == user.id ->
          Repo.rollback(:conflict)

        Repo.exists?(from m in Membership, where: m.node_id == ^node.id and m.user_id == ^user.id) ->
          Repo.rollback(:conflict)

        true ->
          existing =
            Repo.get_by(JoinApplication, node_id: node.id, user_id: user.id, status: "pending")

          existing || create_join_application(user, node, attrs)
      end
    end)
  end

  defp create_join_application(user, node, attrs) do
    application =
      %JoinApplication{node_id: node.id, user_id: user.id}
      |> JoinApplication.create_changeset(attrs)
      |> Repo.insert()
      |> write_result!()

    for admin_id <- admin_ids(node) do
      Rice.Inbox.notify(
        Repo,
        admin_id,
        user.id,
        "node_application_created",
        "申请加入#{node.name}",
        "node",
        node.id
      )
      |> write_result!()
    end

    application
  end

  def review_join_application(%User{} = user, %Node{} = node, application_id, status, attrs)
      when status in ~w(approved rejected) do
    if Rice.Tsid.valid?(application_id) do
      Repo.transaction(fn ->
        node = Repo.one!(from n in Node, where: n.id == ^node.id, lock: "FOR UPDATE")
        if not admin?(node, user), do: Repo.rollback(:forbidden)

        application = Repo.get_by(JoinApplication, id: application_id, node_id: node.id)

        cond do
          is_nil(application) -> Repo.rollback(:not_found)
          application.status == status -> application
          application.status != "pending" -> Repo.rollback(:conflict)
          true -> finish_join_review(user, node, application, status, attrs)
        end
      end)
    else
      {:error, :not_found}
    end
  end

  defp finish_join_review(user, node, application, status, attrs) do
    application =
      application
      |> JoinApplication.review_changeset(user, status, attrs)
      |> Repo.update()
      |> write_result!()

    if status == "approved" do
      %Membership{node_id: node.id, user_id: application.user_id}
      |> Membership.changeset()
      |> Repo.insert(on_conflict: :nothing, conflict_target: [:node_id, :user_id])
      |> write_result!()
    end

    detail = if status == "approved", do: "加入#{node.name}的申请已通过", else: "加入#{node.name}的申请未通过"

    Rice.Inbox.notify(
      Repo,
      application.user_id,
      user.id,
      "node_application_#{status}",
      detail,
      "node",
      node.id
    )
    |> write_result!()

    application
  end

  defp write_result!({:ok, value}), do: value
  defp write_result!({:error, reason}), do: Repo.rollback(reason)

  @doc "节点用户列表(原 /user/node-user-list)。"
  def list_node_members do
    Repo.all(
      from u in Rice.Accounts.User,
        where: u.node_member == true and is_nil(u.deleted_at) and is_nil(u.disabled_at),
        order_by: [asc: u.id],
        preload: [:avatar]
    )
  end

  # ── 勋章 ────────────────────────────────────────────────────────────────

  @doc "某人获得的勋章。"
  def list_badge_awards(user, params \\ %{}) do
    from(a in BadgeAward,
      where: a.user_id == ^user.id,
      preload: [badge: :image]
    )
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  @doc """
  勋章全集,附上**指定用户**的获得时间(没获得就是 nil)。勋章墙要把没拿到的
  也灰着显示出来 —— core 是让 `/user-medal/page` 同时返回已获得和未获得,
  再靠 `getTime` 是不是 null 区分,这里把这层含义放进了 `awarded_at`。

  传 nil 就是"谁也不是",全部为 nil。
  """
  def list_badges(user \\ nil) do
    awarded =
      case user do
        nil ->
          %{}

        %{id: id} ->
          from(a in BadgeAward, where: a.user_id == ^id, select: {a.badge_id, a.awarded_at})
          |> Repo.all()
          |> Map.new()
      end

    from(b in Badge, order_by: [asc: b.id], preload: [:image])
    |> Repo.all()
    |> Enum.map(&{&1, Map.get(awarded, &1.id)})
  end

  @doc """
  后台的勋章列表,带持有人数。

  持有人数是一条 `left_join + count` 现算的 —— core 缓存在 `t_medal.quantity`,
  那是一份会和实际发放对不上的副本。
  """
  def list_all_badges(params \\ %{}) do
    from(b in Badge,
      left_join: a in assoc(b, :awards),
      group_by: b.id,
      select: %{b | holder_count: count(a.id)},
      preload: [:image]
    )
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  def fetch_badge(id) do
    if Rice.Tsid.valid?(id) do
      case Repo.one(from b in Badge, where: b.id == ^id, preload: [:image]) do
        nil -> {:error, :not_found}
        badge -> {:ok, badge}
      end
    else
      {:error, :not_found}
    end
  end

  @doc """
  建一枚勋章,可以顺带发给一批人。

  `recipients` 是手机号 / 邮箱 / handle / DID / rice id 的数组,和发放稻米认的
  写法一样。**建和发在同一个事务里** —— core 也是一次调用干完这两件事
  (`medal/create` 收一个名单文件)。分成两步的话,名单里有一个笔误就会留下
  一枚没有持有人的孤儿勋章,而名单恰恰是最容易出错的地方。

  全有或全无:任何一个收款人解析不出来,勋章也不建。
  """
  def create_badge(attrs, recipients \\ []) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    with {:ok, users} <- resolve_recipients(recipients) do
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:badge, Badge.changeset(%Badge{}, attrs))
      |> award_all(users)
      |> Repo.transaction()
      |> case do
        {:ok, %{badge: badge}} -> {:ok, Repo.preload(badge, :image)}
        {:error, _step, reason, _} -> {:error, reason}
      end
    end
  end

  @doc """
  给一枚**已有**的勋章补发持有人。

  core 没有这个入口:`medal/create` 建和发一次做完,建完就加不了人。漏了一个人
  只能重建一枚同名勋章,而那会把先拿到的人的获得时间也一起改掉。

  收款人的写法和 `create_badge/2` 完全一致,认不出来的人同样是**全有或全无**。
  不一样的只有一条:**已经持有的人不算错**。补名单的场景里运营粘的往往是完整
  名单而不是差集,重叠是常态而不是笔误 —— 报错的话这个接口就没法用了。

  返回 `%{awarded: 真正新发出去的人数, already_held: 名单里已经有的人数}`。

  写入是一条带 `on_conflict: :nothing` 的 `INSERT`,所以"已持有"和"两个运营
  同时点了提交"走的是同一条路 —— 数据库的唯一索引说了算,不靠先查后写那个
  会漏的窗口。
  """
  def award_badge_to(%Badge{} = badge, recipients) do
    with {:ok, users} <- resolve_recipients(recipients) do
      case users do
        [] -> {:error, :no_recipients}
        users -> insert_awards(badge, users)
      end
    end
  end

  defp insert_awards(%Badge{id: badge_id}, users) do
    now = DateTime.utc_now()

    entries =
      Enum.map(users, fn user ->
        %{
          id: Rice.Tsid.generate(),
          badge_id: badge_id,
          user_id: user.id,
          awarded_at: now,
          inserted_at: now,
          updated_at: now
        }
      end)

    {awarded, _} =
      Repo.insert_all(BadgeAward, entries,
        on_conflict: :nothing,
        conflict_target: [:badge_id, :user_id]
      )

    {:ok, %{awarded: awarded, already_held: length(users) - awarded}}
  end

  defp award_all(multi, users) do
    Enum.reduce(users, multi, fn user, acc ->
      Ecto.Multi.insert(acc, {:award, user.id}, fn %{badge: badge} ->
        BadgeAward.changeset(%BadgeAward{}, %{badge_id: badge.id, user_id: user.id})
      end)
    end)
  end

  # 收款人的写法和发放稻米保持一致 —— 运营在两个界面里粘的是同一份名单
  defp resolve_recipients([]), do: {:ok, []}

  defp resolve_recipients(recipients) when is_list(recipients) do
    case Enum.reject(recipients, &is_binary/1) do
      [] -> match_recipients(recipients)
      bad -> {:error, {:invalid_recipients, bad}}
    end
  end

  defp resolve_recipients(_), do: {:error, :invalid_recipients}

  defp match_recipients(recipients) do
    found =
      recipients
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()
      |> Enum.map(&{&1, Rice.Accounts.find_user(&1)})

    case Enum.filter(found, fn {_, user} -> is_nil(user) end) do
      [] -> {:ok, found |> Enum.map(&elem(&1, 1)) |> Enum.uniq_by(& &1.id)}
      missing -> {:error, {:unknown_recipients, Enum.map(missing, &elem(&1, 0))}}
    end
  end

  @doc "持有某枚勋章的人。"
  def list_badge_holders(%Badge{id: id}, params \\ %{}) do
    from(a in BadgeAward,
      where: a.badge_id == ^id,
      preload: [user: :avatar]
    )
    |> filter_holder(params["q"])
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  defp filter_holder(query, q) when is_binary(q) and q != "" do
    pattern =
      "%" <>
        (q
         |> String.trim()
         |> String.replace("\\", "\\\\")
         |> String.replace("%", "\\%")
         |> String.replace("_", "\\_")) <> "%"

    from a in query,
      join: u in assoc(a, :user),
      where:
        ilike(u.nickname, ^pattern) or ilike(u.email, ^pattern) or ilike(u.phone, ^pattern) or
          ilike(u.handle, ^pattern)
  end

  defp filter_holder(query, _), do: query

  @doc "发一枚勋章。同一枚勋章不会重复发给同一个人。"
  def award_badge(%Badge{} = badge, user) do
    %BadgeAward{}
    |> BadgeAward.changeset(%{badge_id: badge.id, user_id: user.id})
    |> Repo.insert()
  end

  @doc "持有某枚勋章的人数 —— core 把它缓存成 t_medal.quantity,这里现算。"
  def badge_holder_count(%Badge{id: id}),
    do: Repo.aggregate(from(a in BadgeAward, where: a.badge_id == ^id), :count)
end

defmodule RiceWeb.Api.NodeJSON do
  alias Rice.Accounts.User
  alias RiceWeb.Api.{AttachmentJSON, UserJSON}

  def index(%{nodes: nodes, current_user: user}),
    do: %{data: Enum.map(nodes, &data(&1, user))}

  def show(%{node: node, current_user: user}) do
    data = Map.put(data(node, user), :members, members_for(node))

    data =
      if Rice.Community.admin?(node, user) do
        Map.put(data, :applications, Enum.map(node.applications, &application(&1, true)))
      else
        data
      end

    %{data: data}
  end

  def members(%{users: users}), do: %{data: Enum.map(users, &UserJSON.public/1)}
  def node_members(%{node: node}), do: %{data: members_for(node)}

  def embed(node, owner_balances \\ nil)
  def embed(nil, _), do: nil
  def embed(%Ecto.Association.NotLoaded{}, _), do: nil

  def embed(node, owner_balances) do
    %{
      id: node.id,
      name: node.name,
      description: node.description,
      position: node.position,
      logo: AttachmentJSON.embed(node.logo),
      owner: owner(node.user, owner_balances)
    }
  end

  def owner_balances(nodes) do
    users = for %{user: %User{} = user} <- nodes, do: user

    case Rice.Points.LegacyCutover.point_id() do
      nil -> Map.new(users, &{&1.id, {&1.grain_balance, &1.grain_frozen_balance}})
      point_id -> point_owner_balances(users, point_id)
    end
  end

  defp point_owner_balances(users, point_id) do
    import Ecto.Query
    ids = Enum.map(users, & &1.id)

    Rice.Repo.all(
      from a in Rice.Points.Account,
        join: b in Rice.Points.Balance,
        on: b.account_id == a.id,
        where: a.point_id == ^point_id and a.owner_type == "user" and a.owner_id in ^ids,
        select: {a.owner_id, {b.available, b.held}}
    )
    |> Map.new()
  end

  defp owner(%User{} = user, balances) do
    {balance, frozen} =
      if is_map(balances),
        do: Map.get(balances, user.id, {0, 0}),
        else: Rice.Grains.balances(user)

    user |> UserJSON.embed() |> Map.merge(%{grain_balance: balance, grain_frozen_balance: frozen})
  end

  defp owner(user, _), do: UserJSON.embed(user)

  defp data(node, user) do
    own_application = if user, do: Enum.find(node.applications, &(&1.user_id == user.id))

    {balance, frozen} = Rice.Grains.balances(node)

    Map.merge(embed(node), %{
      grain_balance: balance,
      grain_frozen_balance: frozen,
      role: role(node, user),
      can_manage_members: not is_nil(user) and node.user_id == user.id,
      my_application: if(own_application, do: application(own_application))
    })
  end

  defp role(_node, nil), do: nil
  defp role(%{user_id: id}, %{id: id}), do: "admin"

  defp role(node, user) do
    case Enum.find(node.memberships, &(&1.user_id == user.id)) do
      nil -> nil
      membership -> membership.role
    end
  end

  defp members_for(node) do
    admin =
      if visible_user?(node.user),
        do: [%{user: UserJSON.public(node.user), role: "admin"}],
        else: []

    members =
      node.memberships
      |> Enum.filter(&(&1.user_id != node.user_id and visible_user?(&1.user)))
      |> Enum.map(&%{user: UserJSON.public(&1.user), role: &1.role})

    admin ++ members
  end

  defp visible_user?(%Rice.Accounts.User{deleted_at: nil, disabled_at: nil}), do: true
  defp visible_user?(_), do: false

  defp application(application, include_user \\ false) do
    data =
      Map.take(application, [:id, :status, :reason, :review_reason, :inserted_at, :reviewed_at])

    if include_user, do: Map.put(data, :user, UserJSON.public(application.user)), else: data
  end
end

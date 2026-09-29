defmodule RiceWeb.Api.NodeJSON do
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

  def embed(nil), do: nil
  def embed(%Ecto.Association.NotLoaded{}), do: nil

  def embed(node) do
    %{
      id: node.id,
      name: node.name,
      description: node.description,
      position: node.position,
      logo: AttachmentJSON.embed(node.logo),
      owner: owner(node.user)
    }
  end

  defp owner(%Ecto.Association.NotLoaded{}), do: nil
  defp owner(nil), do: nil

  defp owner(user) do
    UserJSON.public(user)
  end

  defp data(node, user) do
    own_application = if user, do: Enum.find(node.applications, &(&1.user_id == user.id))

    Map.merge(embed(node), %{
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
    admin = if visible_user?(node.user), do: [%{user: owner(node.user), role: "admin"}], else: []

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

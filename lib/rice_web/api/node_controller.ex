defmodule RiceWeb.Api.NodeController do
  @moduledoc "公开节点目录、社区成员角色与入会申请。"
  use RiceWeb, :controller

  action_fallback RiceWeb.Api.FallbackController

  alias Rice.Community

  def index(conn, params) do
    user = conn.assigns[:current_user]

    cond do
      params["mine"] not in [nil, "", "joined", "pending", "managed", "identity"] ->
        {:error, :unprocessable_entity}

      params["mine"] in ~w(joined pending managed identity) and is_nil(user) ->
        {:error, :unauthorized}

      true ->
        render(conn, :index, nodes: Community.list_nodes(user, params), current_user: user)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, node} <- Community.fetch_node(id, conn.assigns[:current_user]) do
      render(conn, :show, node: node, current_user: conn.assigns[:current_user])
    end
  end

  def members(conn, %{"node_id" => id}) do
    with {:ok, node} <- Community.fetch_node(id) do
      render(conn, :node_members, node: node)
    end
  end

  def members(conn, _params),
    do: render(conn, :members, users: Community.list_node_members())

  def apply(conn, %{"node_id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, node} <- Community.fetch_node(id, user),
         {:ok, _application} <- Community.apply_to_node(user, node, params),
         {:ok, node} <- Community.fetch_node(id, user) do
      render(conn, :show, node: node, current_user: user)
    end
  end

  def approve(conn, params), do: review(conn, params, "approved")
  def reject(conn, params), do: review(conn, params, "rejected")

  def update_member(conn, %{"node_id" => id, "user_id" => user_id} = params) do
    user = conn.assigns.current_user

    with {:ok, node} <- Community.fetch_node(id, user),
         {:ok, _member} <- Community.set_member_role(user, node, user_id, params["role"]),
         {:ok, node} <- Community.fetch_node(id, user) do
      render(conn, :show, node: node, current_user: user)
    end
  end

  defp review(conn, %{"node_id" => id, "application_id" => application_id} = params, status) do
    user = conn.assigns.current_user

    with {:ok, node} <- Community.fetch_node(id, user),
         {:ok, _application} <-
           Community.review_join_application(user, node, application_id, status, params),
         {:ok, node} <- Community.fetch_node(id, user) do
      render(conn, :show, node: node, current_user: user)
    end
  end
end

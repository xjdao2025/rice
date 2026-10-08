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

  def apply(conn, %{"node_id" => id} = params),
    do: change(conn, id, &Community.apply_to_node(&1, &2, params))

  def approve(conn, params), do: review(conn, params, "approved")
  def reject(conn, params), do: review(conn, params, "rejected")

  def update_member(conn, %{"node_id" => id, "user_id" => user_id} = params),
    do: change(conn, id, &Community.set_member_role(&1, &2, user_id, params["role"]))

  defp review(conn, %{"node_id" => id, "application_id" => application_id} = params, status) do
    change(conn, id, &Community.review_join_application(&1, &2, application_id, status, params))
  end

  # 取节点 → 改 → 重新取一遍(带上最新的成员和申请)渲染
  defp change(conn, id, action) do
    user = conn.assigns.current_user

    with {:ok, node} <- Community.fetch_node(id, user),
         {:ok, _} <- action.(user, node),
         {:ok, node} <- Community.fetch_node(id, user) do
      render(conn, :show, node: node, current_user: user)
    end
  end
end

defmodule RiceWeb.Api.NodeWalletController do
  use RiceWeb, :controller

  alias Rice.{Community, Grains}
  action_fallback RiceWeb.Api.FallbackController

  def show(conn, %{"node_id" => id} = params) do
    with {:ok, node} <- Community.fetch_node(id),
         :ok <- authorize(node, conn.assigns.current_user) do
      json(conn, %{data: Grains.wallet(node, params)})
    end
  end

  def fund(conn, %{"node_id" => id} = params) do
    with {:ok, node} <- Community.fetch_node(id),
         {:ok, _} <-
           Grains.fund_node(
             conn.assigns.current_user,
             node,
             params["amount"],
             params["client_request_id"]
           ) do
      json(conn, %{data: Grains.wallet(node)})
    end
  end

  defp authorize(node, user) do
    if Community.admin?(node, user), do: :ok, else: {:error, :forbidden}
  end
end

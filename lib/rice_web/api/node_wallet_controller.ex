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

  # 任何人都能向节点转入;节点账本只给管理员看,所以这里只回这一笔
  def fund(conn, %{"node_id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, node} <- Community.fetch_node(id),
         {:ok, transfer} <-
           Grains.fund_node(user, node, params["amount"], params["client_request_id"]) do
      render_transfer(conn, transfer, user)
    end
  end

  def transfer(conn, %{"node_id" => id} = params) do
    user = conn.assigns.current_user

    with {:ok, node} <- Community.fetch_node(id),
         {:ok, amount} when amount in 1..999_999_999 <- {:ok, params["amount"]},
         {:ok, transfer} <-
           Grains.send_from_node(user, node, params["to"], amount,
             memo: params["memo"],
             request_id: params["client_request_id"]
           ) do
      render_transfer(conn, transfer, user)
    else
      {:ok, _amount} -> {:error, :invalid_amount}
      error -> error
    end
  end

  defp render_transfer(conn, transfer, user) do
    conn
    |> put_status(:created)
    |> put_view(RiceWeb.Api.GrainTransferJSON)
    |> render(:show,
      transfer: Rice.Repo.preload(transfer, [:from_user, :to_user, :from_node, :to_node]),
      viewer: user
    )
  end

  defp authorize(node, user) do
    if Community.admin?(node, user), do: :ok, else: {:error, :forbidden}
  end
end

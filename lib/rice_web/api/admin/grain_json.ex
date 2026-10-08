defmodule RiceWeb.Api.Admin.GrainJSON do
  alias RiceWeb.Api.{GrainTransferJSON, UserJSON}

  def index(%{page: page}) do
    %{
      data: Enum.map(page.entries, &grant/1),
      meta: Rice.Pagination.meta(page)
    }
  end

  @doc "某人的明细。方向按这个人算,不是按当前登录的管理员算。"
  def transfers(%{page: page, user: user}) do
    %{
      data: Enum.map(page.entries, &GrainTransferJSON.data(&1, user)),
      meta: Rice.Pagination.meta(page)
    }
  end

  defp grant(transfer) do
    %{
      id: transfer.id,
      amount: transfer.amount,
      memo: transfer.memo,
      to: recipient(transfer.to_user),
      to_node: node_recipient(transfer.to_node),
      inserted_at: transfer.inserted_at
    }
  end

  defp recipient(%Ecto.Association.NotLoaded{}), do: nil
  defp recipient(nil), do: nil

  defp recipient(user) do
    user
    |> UserJSON.public()
    |> Map.merge(%{email: user.email, phone: user.phone, phone_region: user.phone_region})
  end

  defp node_recipient(%Ecto.Association.NotLoaded{}), do: nil
  defp node_recipient(nil), do: nil
  defp node_recipient(node), do: %{id: node.id, name: node.name}
end

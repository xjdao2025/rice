defmodule RiceWeb.Api.GrainTransferJSON do
  alias RiceWeb.Api.UserJSON

  def index(%{page: page} = assigns) do
    %{
      data: Enum.map(page.entries, &data(&1, assigns[:viewer])),
      meta: %{next_cursor: page.next_cursor}
    }
  end

  def show(%{transfer: transfer} = assigns), do: %{data: data(transfer, assigns[:viewer])}

  @doc """
  单笔转账。`viewer` 决定 direction —— 后台看别人的明细时传的是那个人,
  不是当前登录的管理员。
  """
  def data(transfer, viewer) do
    %{
      id: transfer.id,
      kind: transfer.kind,
      amount: transfer.amount,
      memo: transfer.memo,
      subject_uri: transfer.subject_uri,
      from: party(transfer.from_user),
      to: party(transfer.to_user),
      from_node: node_party(transfer.from_node),
      to_node: node_party(transfer.to_node),
      # 相对当前用户的方向:收到是正,付出是负。
      # core 是靠给每笔转账写两行带符号的记录来表达这件事的。
      direction: direction(transfer, viewer),
      inserted_at: transfer.inserted_at
    }
  end

  defp party(%Ecto.Association.NotLoaded{}), do: nil
  defp party(nil), do: nil
  defp party(user), do: UserJSON.public(user)

  defp node_party(%Rice.Community.Node{} = node), do: %{id: node.id, name: node.name}
  defp node_party(_), do: nil

  defp direction(_transfer, nil), do: nil
  defp direction(%{to_user_id: id}, %{id: id}), do: "in"
  defp direction(%{from_user_id: id}, %{id: id}), do: "out"
  defp direction(_, _), do: nil
end

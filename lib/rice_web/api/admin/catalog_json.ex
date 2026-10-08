# 后台的清单视图在 C 端那份上补字段:inserted_at 给列表显示,节点再加余额。
defmodule RiceWeb.Api.Admin.AppJSON do
  def index(%{records: records}), do: %{data: Enum.map(records, &data/1)}
  def show(%{record: record}), do: %{data: data(record)}

  def data(app), do: app |> RiceWeb.Api.AppJSON.data() |> Map.put(:inserted_at, app.inserted_at)
end

defmodule RiceWeb.Api.Admin.BannerJSON do
  def index(%{records: records}), do: %{data: Enum.map(records, &data/1)}
  def show(%{record: record}), do: %{data: data(record)}

  def data(banner),
    do: banner |> RiceWeb.Api.BannerJSON.data() |> Map.put(:inserted_at, banner.inserted_at)
end

defmodule RiceWeb.Api.Admin.AnnouncementJSON do
  def index(%{records: records}), do: %{data: Enum.map(records, &data/1)}
  def show(%{record: record}), do: %{data: data(record)}

  defdelegate data(announcement), to: RiceWeb.Api.AnnouncementJSON
end

defmodule RiceWeb.Api.Admin.NodeJSON do
  alias RiceWeb.Api.UserJSON

  def index(%{records: records}), do: %{data: Enum.map(records, &data/1)}
  def show(%{record: record}), do: %{data: data(record)}

  def data(node) do
    node
    |> RiceWeb.Api.NodeJSON.embed()
    |> Map.merge(%{
      grain_balance: node.grain_balance,
      grain_frozen_balance: node.grain_frozen_balance,
      owner: owner(node.user),
      inserted_at: node.inserted_at
    })
  end

  defp owner(%Rice.Accounts.User{} = user),
    do: user |> UserJSON.public() |> Map.put(:grain_balance, user.grain_balance)

  defp owner(_), do: nil
end

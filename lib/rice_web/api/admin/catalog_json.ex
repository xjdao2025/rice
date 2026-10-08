defmodule RiceWeb.Api.Admin.AppJSON do
  @moduledoc "后台看到的应用入口。比 C 端多一个 position —— 排序界面要用。"
  alias RiceWeb.Api.AttachmentJSON

  def index(%{records: records}), do: %{data: Enum.map(records, &data/1)}
  def show(%{record: record}), do: %{data: data(record)}

  def data(app) do
    %{
      id: app.id,
      name: app.name,
      description: app.description,
      url: app.url,
      position: app.position,
      logo: AttachmentJSON.embed(app.logo),
      inserted_at: app.inserted_at
    }
  end
end

defmodule RiceWeb.Api.Admin.BannerJSON do
  alias RiceWeb.Api.AttachmentJSON

  def index(%{records: records}), do: %{data: Enum.map(records, &data/1)}
  def show(%{record: record}), do: %{data: data(record)}

  def data(banner) do
    %{
      id: banner.id,
      url: banner.url,
      position: banner.position,
      image: AttachmentJSON.embed(banner.image),
      inserted_at: banner.inserted_at
    }
  end
end

defmodule RiceWeb.Api.Admin.AnnouncementJSON do
  alias RiceWeb.Api.AttachmentJSON

  def index(%{records: records}), do: %{data: Enum.map(records, &data/1)}
  def show(%{record: record}), do: %{data: data(record)}

  def data(announcement) do
    %{
      id: announcement.id,
      title: announcement.title,
      position: announcement.position,
      attachment: AttachmentJSON.embed(announcement.attachment),
      inserted_at: announcement.inserted_at
    }
  end
end

defmodule RiceWeb.Api.Admin.NodeJSON do
  alias RiceWeb.Api.{AttachmentJSON, UserJSON}

  def index(%{records: records}), do: %{data: Enum.map(records, &data/1)}
  def show(%{record: record}), do: %{data: data(record)}

  def data(node) do
    %{
      id: node.id,
      name: node.name,
      description: node.description,
      position: node.position,
      grain_balance: node.grain_balance,
      grain_frozen_balance: node.grain_frozen_balance,
      logo: AttachmentJSON.embed(node.logo),
      owner: owner(node.user),
      inserted_at: node.inserted_at
    }
  end

  defp owner(%Ecto.Association.NotLoaded{}), do: nil
  defp owner(nil), do: nil

  defp owner(user) do
    user |> UserJSON.public() |> Map.put(:grain_balance, user.grain_balance)
  end
end

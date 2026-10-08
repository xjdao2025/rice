defmodule RiceWeb.Api.AppJSON do
  alias RiceWeb.Api.AttachmentJSON

  def index(%{apps: apps}), do: %{data: Enum.map(apps, &data/1)}

  def data(app) do
    %{
      id: app.id,
      name: app.name,
      description: app.description,
      url: app.url,
      position: app.position,
      logo: AttachmentJSON.embed(app.logo)
    }
  end
end

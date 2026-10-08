defmodule RiceWeb.Api.BannerJSON do
  alias RiceWeb.Api.AttachmentJSON

  def index(%{banners: banners}), do: %{data: Enum.map(banners, &data/1)}

  def data(banner) do
    %{
      id: banner.id,
      url: banner.url,
      position: banner.position,
      image: AttachmentJSON.embed(banner.image)
    }
  end
end

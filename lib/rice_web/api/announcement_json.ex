defmodule RiceWeb.Api.AnnouncementJSON do
  alias RiceWeb.Api.AttachmentJSON

  def index(%{page: page}) do
    %{
      data: Enum.map(page.entries, &data/1),
      meta: %{next_cursor: page.next_cursor}
    }
  end

  def show(%{announcement: announcement}), do: %{data: data(announcement)}

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

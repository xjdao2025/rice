defmodule RiceWeb.Api.AttachmentJSON do
  @moduledoc "附件在各处响应里的内嵌形状。"

  alias Rice.Files.Attachment

  def show(%{attachment: attachment}), do: %{data: embed(attachment)}

  @doc "附件的紧凑表示。没有附件时是 null,不是空对象。"
  def embed(nil), do: nil
  def embed(%Ecto.Association.NotLoaded{}), do: nil

  def embed(%Attachment{} = a) do
    %{
      id: a.id,
      kind: a.kind,
      filename: a.filename,
      content_type: a.content_type,
      byte_size: a.byte_size,
      url: "/api/attachments/#{a.id}"
    }
  end
end

defmodule RiceWeb.Api.LegacyAttachmentController do
  use RiceWeb, :controller

  import Ecto.Query

  alias Rice.Files.Attachment
  alias Rice.Repo
  alias RiceWeb.Api.AttachmentController

  action_fallback RiceWeb.Api.FallbackController

  def show(conn, %{"fileId" => file_id, "fileType" => file_type})
      when is_binary(file_id) and file_type in ["1", "2"] do
    if Regex.match?(~r/\A[0-9a-fA-F]{32}\z/, file_id) do
      prefix = "#{file_type}-#{String.downcase(file_id)}-%"

      case Repo.all(from a in Attachment, where: ilike(a.legacy_id, ^prefix), limit: 2) do
        [attachment] -> AttachmentController.show(conn, %{"id" => attachment.id})
        _ -> {:error, :not_found}
      end
    else
      {:error, :not_found}
    end
  end

  def show(_conn, _params), do: {:error, :not_found}
end

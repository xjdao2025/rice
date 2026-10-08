defmodule Rice.Content.Announcement do
  @moduledoc "公告(原 t_information)。正文是一个 html 附件,不是数据库字段。"
  use Rice.Schema

  schema "announcements" do
    field :legacy_id, :string
    field :title, :string
    field :position, :integer, default: 0

    belongs_to :attachment, Rice.Files.Attachment

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(announcement, attrs) do
    announcement
    |> cast(attrs, [:legacy_id, :title, :position, :attachment_id])
    |> validate_required([:title])
    |> validate_length(:title, max: 128)
    |> foreign_key_constraint(:attachment_id)
    |> unique_constraint(:legacy_id)
  end
end

defmodule Rice.Content.Banner do
  @moduledoc "首页轮播位(原 t_banner)。"
  use Rice.Schema

  schema "banners" do
    field :legacy_id, :string
    field :url, :string, default: ""
    field :position, :integer, default: 0

    belongs_to :image, Rice.Files.Attachment

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(banner, attrs) do
    banner
    |> cast(attrs, [:legacy_id, :url, :position, :image_id])
    |> validate_length(:url, max: 512)
    |> foreign_key_constraint(:image_id)
    |> unique_constraint(:legacy_id)
  end
end

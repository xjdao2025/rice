defmodule Rice.Content.App do
  @moduledoc "首页的应用入口(原 t_app)。"
  use Rice.Schema

  schema "apps" do
    field :legacy_id, :string
    field :name, :string
    field :description, :string, default: ""
    field :url, :string, default: ""
    field :position, :integer, default: 0

    belongs_to :logo, Rice.Files.Attachment

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(app, attrs) do
    app
    |> cast(attrs, [:legacy_id, :name, :description, :url, :position, :logo_id])
    |> validate_required([:name])
    |> validate_length(:name, max: 256)
    |> foreign_key_constraint(:logo_id)
    |> unique_constraint(:legacy_id)
  end
end

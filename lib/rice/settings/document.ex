defmodule Rice.Settings.Document do
  @moduledoc """
  基金会公开信息文件。

  core 把它存成 `t_global_config.foundation_public_document` 里的一个 json 字符串数组
  (裸 fileId),没有顺序语义也挂不上外键。这里拆成关联表。
  """
  use Rice.Schema

  schema "site_setting_documents" do
    field :position, :integer, default: 0

    belongs_to :site_setting, Rice.Settings.Site
    belongs_to :attachment, Rice.Files.Attachment

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(document, attrs) do
    document
    |> cast(attrs, [:site_setting_id, :attachment_id, :position])
    |> validate_required([:site_setting_id, :attachment_id])
    |> foreign_key_constraint(:site_setting_id)
    |> foreign_key_constraint(:attachment_id)
    |> unique_constraint([:site_setting_id, :attachment_id])
  end
end

defmodule Rice.Files.Attachment do
  @moduledoc """
  上传的文件。落盘路径(`storage_key`)只由 TSID 决定,与用户提供的文件名无关 ——
  `filename` 只在下载时的 `Content-Disposition` 里出现。

  `legacy_id` 存 core 那个拼接出来的 fileId(`1-<guid>-<原始文件名>`),
  用于导入时解析外键,也让旧引用在过渡期还能查得到。
  """
  use Rice.Schema

  @kinds ~w(image file)

  schema "attachments" do
    field :legacy_id, :string
    field :kind, :string
    field :filename, :string
    field :content_type, :string
    field :byte_size, :integer
    field :checksum, :string
    field :storage_key, :string
    belongs_to :user, Rice.Accounts.User

    timestamps()
  end

  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [
      :legacy_id,
      :kind,
      :filename,
      :content_type,
      :byte_size,
      :checksum,
      :storage_key
    ])
    |> validate_required([:kind, :filename])
    |> validate_inclusion(:kind, @kinds)
    |> unique_constraint(:legacy_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc """
  解析 core 的 fileId。格式 `<类型码>-<guid32>-<原始文件名>`,
  类型码 1 = 图片、2 = 文件;原始文件名本身可能含 `-`,所以只切前两段。

      iex> Rice.Files.Attachment.parse_legacy_id("1-b656bee8-GU logo 1-512.jpg")
      {:ok, %{kind: "image", filename: "GU logo 1-512.jpg"}}
  """
  def parse_legacy_id(file_id) when is_binary(file_id) do
    case String.split(file_id, "-", parts: 3) do
      [code, _guid, filename] when filename != "" ->
        case kind_of(code) do
          nil -> :error
          kind -> {:ok, %{kind: kind, filename: filename}}
        end

      _ ->
        :error
    end
  end

  def parse_legacy_id(_), do: :error

  defp kind_of("1"), do: "image"
  defp kind_of("2"), do: "file"
  defp kind_of(_), do: nil
end

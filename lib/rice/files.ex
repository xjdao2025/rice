defmodule Rice.Files do
  @moduledoc """
  附件。

  职责分两半:元数据在 Postgres(`attachments`),字节在 `Rice.Files.Storage`。
  落盘路径只由 TSID 决定,**任何时候都不把用户提供的文件名拼进路径** ——
  原始文件名只在下载时的 `Content-Disposition` 里出现。

  上传需要认证；新增业务图片须由操作者上传，已有图片可继续引用。
  """
  import Ecto.Query

  alias Rice.Files.{Attachment, Storage}
  alias Rice.Repo

  # 与 core 的行为对齐:只收图片和文档。上传端点接上去时这就是白名单。
  #
  # 表格是后来补的:后台批量发放的模板是 Excel,没有这两项的话换一版模板
  # 根本传不上来。新旧格式都收 —— 和 doc/docx 一样,运营的 Excel 存成
  # 哪个版本不由我们决定。
  @allowed_content_types %{
    "image" => ~w(image/png image/jpeg image/gif image/webp image/svg+xml),
    "file" => ~w(application/pdf text/html text/plain
                 application/msword
                 application/vnd.openxmlformats-officedocument.wordprocessingml.document
                 application/vnd.ms-excel
                 application/vnd.openxmlformats-officedocument.spreadsheetml.sheet)
  }

  @max_byte_size 20 * 1024 * 1024

  def max_byte_size, do: @max_byte_size
  def allowed_content_types(kind), do: Map.get(@allowed_content_types, kind, [])

  # ── 读 ──────────────────────────────────────────────────────────────────

  def fetch_attachment(id) do
    if Rice.Tsid.valid?(id) do
      case Repo.get(Attachment, id) do
        nil -> {:error, :not_found}
        attachment -> {:ok, attachment}
      end
    else
      # 长度/字符不合法的 id 不可能存在,直接当 404,不去打数据库
      {:error, :not_found}
    end
  end

  @doc "读出附件的字节。元数据存在但字节还没回填时返回 `{:error, :not_stored}`。"
  def read(%Attachment{storage_key: nil}), do: {:error, :not_stored}

  def read(%Attachment{storage_key: key}) do
    case Storage.get(key) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, :not_stored}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "按 core 的 fileId 找附件 —— 导入和回填时解析用。"
  def get_by_legacy_id(nil), do: nil
  def get_by_legacy_id(""), do: nil

  def get_by_legacy_id(legacy_id),
    do: Repo.one(from a in Attachment, where: a.legacy_id == ^legacy_id)

  @doc "TSID 对应的落盘 key。分两级目录,避免单目录堆几十万文件。"
  def storage_key(<<prefix::binary-size(2), _rest::binary>> = id), do: prefix <> "/" <> id

  # ── 写 ──────────────────────────────────────────────────────────────────

  @doc """
  建一个附件:先校验,再落盘,最后写元数据。

  顺序是刻意的 —— 先写库再落盘的话,落盘失败会留下一条指向不存在文件的记录;
  反过来,写库失败最多留下一个孤儿文件,由清理任务回收,不会让接口返回坏数据。
  """
  def create_attachment(content, attrs, user_id \\ nil) when is_binary(content) do
    id = Rice.Tsid.generate()
    key = storage_key(id)

    changeset =
      %Attachment{id: id, user_id: user_id}
      |> Attachment.changeset(
        Map.merge(attrs, %{
          byte_size: byte_size(content),
          checksum: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
          storage_key: key
        })
      )
      |> validate_size()
      |> validate_content_type()

    with {:ok, _} <- Ecto.Changeset.apply_action(changeset, :insert),
         :ok <- Storage.put(key, content) do
      Repo.insert(changeset)
    else
      {:error, %Ecto.Changeset{} = invalid} -> {:error, invalid}
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  @doc "按提交顺序替换业务图片；省略字段保留，空数组移除，最多九张。"
  def put_images(changeset, attrs, user_id) do
    ids = Map.fetch(attrs, "attachment_ids")
    ids = if ids == :error, do: Map.fetch(attrs, :attachment_ids), else: ids

    case ids do
      :error ->
        changeset

      {:ok, ids} ->
        valid? =
          is_list(ids) and length(ids) <= 9 and Enum.all?(ids, &Rice.Tsid.valid?/1) and
            length(Enum.uniq(ids)) == length(ids)

        if valid? do
          data = Repo.preload(changeset.data, :image_links)
          existing = Map.new(data.image_links, &{&1.attachment_id, &1})
          new_ids = Enum.reject(ids, &Map.has_key?(existing, &1))

          if owned_images?(new_ids, user_id) do
            links =
              ids
              |> Enum.with_index()
              |> Enum.map(fn {id, position} ->
                link = Map.get(existing, id) || Ecto.build_assoc(data, :image_links)
                Ecto.Changeset.change(link, attachment_id: id, position: position)
              end)

            Ecto.Changeset.put_assoc(%{changeset | data: data}, :image_links, links)
          else
            Ecto.Changeset.add_error(changeset, :attachment_ids, "最多选择9张本人上传或当前内容已有的有效图片，不能重复")
          end
        else
          Ecto.Changeset.add_error(changeset, :attachment_ids, "最多选择9张本人上传或当前内容已有的有效图片，不能重复")
        end
    end
  end

  defp owned_images?([], _user_id), do: true

  defp owned_images?(ids, user_id) do
    Repo.aggregate(
      from(a in Attachment,
        where:
          a.id in ^ids and a.user_id == ^user_id and a.kind == "image" and
            not is_nil(a.storage_key)
      ),
      :count
    ) == length(ids)
  end

  defp validate_size(changeset) do
    Ecto.Changeset.validate_number(changeset, :byte_size,
      greater_than: 0,
      less_than_or_equal_to: @max_byte_size,
      message: "超过 #{div(@max_byte_size, 1024 * 1024)}MB 上限"
    )
  end

  defp validate_content_type(changeset) do
    kind = Ecto.Changeset.get_field(changeset, :kind)
    allowed = allowed_content_types(kind)

    if allowed == [] do
      changeset
    else
      Ecto.Changeset.validate_inclusion(changeset, :content_type, allowed, message: "不支持的文件类型")
    end
  end

  @doc "把已存在的附件行补上字节和校验信息 —— 从 core 回填时用。"
  def attach_content(%Attachment{} = attachment, content, content_type) do
    key = storage_key(attachment.id)

    with :ok <- Storage.put(key, content) do
      attachment
      |> Attachment.changeset(%{
        byte_size: byte_size(content),
        checksum: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower),
        storage_key: key,
        content_type: content_type
      })
      |> Repo.update()
    end
  end

  @doc "还没有字节的附件 —— 回填任务的工作清单。"
  def list_unstored do
    Repo.all(from a in Attachment, where: is_nil(a.storage_key), order_by: [asc: a.id])
  end
end

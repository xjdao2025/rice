defmodule Rice.Import.Attachments do
  @moduledoc """
  把 core 磁盘上的文件搬进 rice 的存储,并补上 `byte_size` / `checksum` /
  `content_type` / `storage_key`。

  core 的落盘布局(容器内 `/app/Data`,宿主机 `/opt/xjdao/data/core`):

      Picture/<guid32>-<原始文件名>
      File/<guid32>-<原始文件名>

  而 `attachments.legacy_id` 存的是 `<类型码>-<guid32>-<原始文件名>`,
  去掉类型码前缀就是磁盘上的文件名。
  """
  alias Rice.Files

  @doc """
  回填。`source_dir` 指向 core 的 Data 目录(里面有 Picture/ 和 File/)。
  `commit?` 为 false 时只检查文件在不在、算大小,不写任何东西。
  """
  def run(source_dir, commit?) do
    pending = Files.list_unstored()

    Enum.reduce(pending, %{copied: 0, missing: [], failed: [], bytes: 0}, fn attachment, acc ->
      case locate(source_dir, attachment) do
        {:ok, path} ->
          copy(attachment, path, commit?, acc)

        :error ->
          %{acc | missing: acc.missing ++ [attachment.legacy_id || attachment.id]}
      end
    end)
  end

  defp copy(attachment, path, commit?, acc) do
    with {:ok, content} <- File.read(path) do
      if commit? do
        case Files.attach_content(attachment, content, content_type(path)) do
          {:ok, _} ->
            %{acc | copied: acc.copied + 1, bytes: acc.bytes + byte_size(content)}

          {:error, reason} ->
            %{acc | failed: acc.failed ++ [{attachment.id, inspect(reason)}]}
        end
      else
        %{acc | copied: acc.copied + 1, bytes: acc.bytes + byte_size(content)}
      end
    else
      {:error, reason} -> %{acc | failed: acc.failed ++ [{attachment.id, inspect(reason)}]}
    end
  end

  # legacy_id 是 `<码>-<guid>-<文件名>`,磁盘上是 `<guid>-<文件名>`。
  # 只切掉第一段,文件名里的连字符不受影响。
  defp locate(source_dir, %{legacy_id: legacy_id, kind: kind}) when is_binary(legacy_id) do
    case String.split(legacy_id, "-", parts: 2) do
      [_code, disk_name] ->
        path = Path.join([source_dir, subdir(kind), disk_name])
        if File.regular?(path), do: {:ok, path}, else: :error

      _ ->
        :error
    end
  end

  defp locate(_source_dir, _attachment), do: :error

  defp subdir("image"), do: "Picture"
  defp subdir("file"), do: "File"

  # core 没有存 content type,只能从扩展名推。推不出来的按 octet-stream,
  # 由下载接口的 Content-Disposition 兜住。
  def content_type(path) do
    case path |> Path.extname() |> String.downcase() do
      ".png" -> "image/png"
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      ".svg" -> "image/svg+xml"
      ".pdf" -> "application/pdf"
      ".html" -> "text/html"
      ".htm" -> "text/html"
      ".txt" -> "text/plain"
      ".doc" -> "application/msword"
      ".docx" -> "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      ".mp4" -> "video/mp4"
      ".mov" -> "video/quicktime"
      _ -> "application/octet-stream"
    end
  end
end

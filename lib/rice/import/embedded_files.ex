defmodule Rice.Import.EmbeddedFiles do
  @moduledoc """
  修正文里内嵌的 core 下载地址。

  提案和公告的正文是一个 HTML 附件,里面的 `<img>` / `<video>` 直接写死了
  core 的地址:

      https://xjdao.xyz/api/v1/file/download?fileId=<guid32>&fileType=1

  这些 fileId 不在任何数据库列里,`Rice.Import` 按外键导附件时看不到它们,
  所以既没搬过来、地址也没改 —— core 一停,正文里的图就全裂了(2026-09-28 发现)。

  这里做三件事:

    1. 扫所有文本类附件,找出 core 地址;
    2. 把地址指向的文件从 core 的 Data 目录搬进 rice(`legacy_id` 照旧格式,
       已经搬过的直接复用);
    3. 把改写后的正文存成**新的附件**,再把提案/公告/站点文档改指过去。

  第 3 步不原地覆盖,因为 `/api/attachments/:id` 发的是一年的 `immutable` 缓存 ——
  原地改,看过这篇提案的浏览器会一直拿着旧正文。旧附件行留着不删。

  源文件找不到的地址原样保留,记进 `missing`,不让一个坏链接拖住整篇正文。
  幂等:改写过的正文里不再有 core 地址,重跑是空操作。
  """
  import Ecto.Query

  alias Rice.Files
  alias Rice.Files.Attachment
  alias Rice.Repo

  # 主机名不写死:线上同时存在 http/https 两种写法,早期还有别的域名。
  # 认的是路径 + 32 位 guid,后面可能还挂着 `&autoDownload=false` 之类的参数。
  @core_url ~r/https?:\/\/[^\/"'\s<>]+\/api\/v1\/file\/download\?fileId=([0-9a-f]{32})(?:&amp;|&)fileType=([12])(?:(?:&amp;|&)[A-Za-z]+=[^"'\s<>&]*)*/

  # 正文附件挂在这几张表上
  @referrers [
    {"proposals", :attachment_id},
    {"announcements", :attachment_id},
    {"site_setting_documents", :attachment_id}
  ]

  @doc """
  `source_dir` 是 core 的 Data 目录(里面有 `Picture/` 和 `File/`),
  `base_url` 是 rice 对外的地址(例如 `https://rice.xjdao.xyz`)。

  正文是在前端域名下渲染的,所以改写后必须是绝对地址。
  """
  def run(source_dir, base_url, commit?) do
    base_url = String.trim_trailing(base_url, "/")

    Enum.reduce(text_attachments(), empty_result(), fn host, acc ->
      with {:ok, content} <- Files.read(host),
           [_ | _] = matches <- Regex.scan(@core_url, content) do
        fix_host(host, content, matches, source_dir, base_url, commit?, acc)
      else
        _ -> acc
      end
    end)
  end

  defp empty_result,
    do: %{hosts: [], files_copied: 0, files_reused: 0, missing: [], failed: []}

  # 只看还被引用着的正文。被替换下来的旧附件还留着 core 地址,
  # 不排除的话每跑一次就会为它再生成一份没人指的新附件。
  defp text_attachments do
    referenced =
      @referrers
      |> Enum.flat_map(fn {table, column} ->
        Repo.all(from r in table, where: not is_nil(field(r, ^column)), select: field(r, ^column))
      end)
      |> Enum.uniq()

    Repo.all(
      from a in Attachment,
        where:
          a.id in ^referenced and not is_nil(a.storage_key) and like(a.content_type, "text/%"),
        order_by: [asc: a.id]
    )
  end

  defp fix_host(host, content, matches, source_dir, base_url, commit?, acc) do
    guids = matches |> Enum.map(fn [_, guid, code] -> {guid, code} end) |> Enum.uniq()

    {resolved, acc} =
      Enum.reduce(guids, {%{}, acc}, fn {guid, code}, {resolved, acc} ->
        case resolve(guid, code, source_dir, commit?) do
          {:ok, id, how} ->
            acc =
              Map.update!(
                acc,
                if(how == :copied, do: :files_copied, else: :files_reused),
                &(&1 + 1)
              )

            {Map.put(resolved, guid, id), acc}

          :missing ->
            {resolved, %{acc | missing: acc.missing ++ [{host.id, guid}]}}

          {:error, reason} ->
            {resolved, %{acc | failed: acc.failed ++ [{host.id, guid, inspect(reason)}]}}
        end
      end)

    rewritten =
      Regex.replace(@core_url, content, fn whole, guid, _code ->
        case resolved do
          %{^guid => id} -> "#{base_url}/api/attachments/#{id}"
          _ -> whole
        end
      end)

    report = %{attachment_id: host.id, urls: length(matches), rewritten: map_size(resolved)}

    cond do
      rewritten == content ->
        %{acc | hosts: acc.hosts ++ [report]}

      not commit? ->
        %{acc | hosts: acc.hosts ++ [report]}

      true ->
        case replace_host(host, rewritten) do
          {:ok, new_id, refs} ->
            %{
              acc
              | hosts: acc.hosts ++ [Map.merge(report, %{new_attachment_id: new_id, refs: refs})]
            }

          {:error, reason} ->
            %{acc | failed: acc.failed ++ [{host.id, nil, inspect(reason)}]}
        end
    end
  end

  # ── 被嵌的文件 ─────────────────────────────────────────────────────────────

  defp resolve(guid, code, source_dir, commit?) do
    case existing(guid) do
      %Attachment{id: id} ->
        {:ok, id, :reused}

      nil ->
        case locate(source_dir, guid, code) do
          {:ok, path, filename, code} -> copy(path, filename, guid, code, commit?)
          :error -> :missing
        end
    end
  end

  # 只认已经有字节的行 —— 元数据在、字节没回填的,交给 `Rice.Import.Attachments`。
  defp existing(guid) do
    Repo.one(
      from a in Attachment,
        where: like(a.legacy_id, ^"_-#{guid}-%") and not is_nil(a.storage_key),
        limit: 1
    )
  end

  # fileType 说的目录优先,找不到再看另一个 —— 早期数据两者对不上的情况有过。
  defp locate(source_dir, guid, code) do
    [code, other(code)]
    |> Enum.find_value(:error, fn c ->
      case Path.wildcard(Path.join([source_dir, subdir(c), guid <> "-*"])) do
        [path | _] -> {:ok, path, String.replace_prefix(Path.basename(path), guid <> "-", ""), c}
        [] -> nil
      end
    end)
  end

  defp other("1"), do: "2"
  defp other("2"), do: "1"

  defp subdir("1"), do: "Picture"
  defp subdir("2"), do: "File"

  defp copy(path, filename, guid, code, commit?) do
    with {:ok, content} <- File.read(path) do
      if commit? do
        attrs = %{
          kind: if(code == "1", do: "image", else: "file"),
          filename: filename,
          legacy_id: "#{code}-#{guid}-#{filename}",
          content_type: Rice.Import.Attachments.content_type(path)
        }

        case Files.create_legacy_attachment(content, attrs) do
          {:ok, attachment} -> {:ok, attachment.id, :copied}
          {:error, reason} -> {:error, reason}
        end
      else
        {:ok, "(dry-run)", :copied}
      end
    end
  end

  # ── 正文本身 ───────────────────────────────────────────────────────────────

  defp replace_host(host, rewritten) do
    attrs = %{kind: host.kind, filename: host.filename, content_type: host.content_type}

    Repo.transaction(fn ->
      with {:ok, new} <- Files.create_legacy_attachment(rewritten, attrs) do
        refs =
          for {table, column} <- @referrers, into: %{} do
            {n, _} =
              from(r in table, where: field(r, ^column) == ^host.id)
              |> Repo.update_all(set: [{column, new.id}])

            {table, n}
          end

        {new.id, refs}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {new_id, refs}} -> {:ok, new_id, refs}
      error -> error
    end
  end
end

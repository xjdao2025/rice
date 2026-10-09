defmodule Rice.Thumbs do
  @moduledoc """
  帖子图片和头像的缩略图。

  帖子的图是用户直接传到 PDS 的原图(每张 0.7~1MB),信息流一页几十张,
  按原图下发要几十 MB。这里按固定档位缩成 WebP(800px 约 100KB),
  缓存在 `storage_root/thumbs` 下。

  * **直接读 PDS 的磁盘**(`PDS_BLOB_ROOT`,只读挂载),不走 getBlob。
  * **缓存不用失效**:CID 是内容哈希,同一个 CID 永远是同一张图。
  * **每次都确认原图还在**:PDS 下架会把 blob 移走,缩略图跟着 404。
  * **只认固定档位**,did/cid 严格校验 —— 没有任意尺寸可刷,也拼不出别的路径。
  * 缩放在两个分区进程里串行做:同时打开一页几十张图时内存不会被顶穿,
    同一个 CID 永远落在同一个分区,不会重复缩。
  """
  use GenServer

  alias Vix.Vips.{Image, Operation}

  @partitions 2

  @presets %{
    "feed" => [width: 800, height: 800],
    "full" => [width: 1600, height: 1600],
    "avatar" => [width: 256, height: 256, crop: :VIPS_INTERESTING_CENTRE]
  }

  @doc "缩略图(或原样的 GIF 动图)在磁盘上的路径和类型。"
  @spec fetch(String.t(), String.t(), String.t()) ::
          {:ok, Path.t(), String.t()} | {:error, :not_found}
  def fetch(preset, did, cid) do
    with {:ok, opts} <- Map.fetch(@presets, preset),
         true <- did =~ ~r/\Adid:plc:[a-z2-7]{24}\z/ and cid =~ ~r/\Abafkrei[a-z2-7]{52}\z/,
         root when is_binary(root) <- Application.get_env(:rice, :pds_blob_root),
         source = Path.join([root, did, cid]),
         {:ok, magic} <- head(source) do
      cached = Path.join([cache_root(), preset, String.slice(cid, -2, 2), cid <> ".webp"])

      cond do
        # Canvas/libvips 都只取第一帧,动图原样给
        magic == "GIF8" -> {:ok, source, "image/gif"}
        File.exists?(cached) -> {:ok, cached, "image/webp"}
        true -> GenServer.call(worker(cid), {:render, source, cached, opts}, 30_000)
      end
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "把已有的帖子图片预先缩好(上线时跑一次)。返回 `%{ok: n, skipped: n}`。"
  @spec warm(String.t()) :: %{ok: non_neg_integer(), skipped: non_neg_integer()}
  def warm(preset \\ "feed") do
    root = Application.fetch_env!(:rice, :pds_blob_root)

    for did <- File.ls!(root),
        File.dir?(Path.join(root, did)),
        cid <- File.ls!(Path.join(root, did)) do
      {did, cid}
    end
    |> Task.async_stream(fn {did, cid} -> fetch(preset, did, cid) end,
      max_concurrency: @partitions,
      timeout: :infinity
    )
    |> Enum.reduce(%{ok: 0, skipped: 0}, fn
      {:ok, {:ok, _, _}}, acc -> Map.update!(acc, :ok, &(&1 + 1))
      _, acc -> Map.update!(acc, :skipped, &(&1 + 1))
    end)
  end

  @spec child_spec(term()) :: Supervisor.child_spec()
  def child_spec(_) do
    PartitionSupervisor.child_spec(
      child_spec: %{id: __MODULE__, start: {GenServer, :start_link, [__MODULE__, nil]}},
      name: __MODULE__,
      partitions: @partitions
    )
  end

  @impl true
  def init(nil), do: {:ok, nil}

  @impl true
  def handle_call({:render, source, cached, opts}, _from, state) do
    # 排队期间可能已经被前一个请求缩好了
    reply =
      if File.exists?(cached), do: {:ok, cached, "image/webp"}, else: render(source, cached, opts)

    {:reply, reply, state}
  end

  defp render(source, cached, opts) do
    {width, opts} = Keyword.pop!(opts, :width)

    # 先写临时文件再改名:别的请求永远读不到写了一半的图。扩展名决定编码器。
    tmp = Path.join(Path.dirname(cached), ".#{System.unique_integer([:positive])}.webp")

    with {:ok, image} <- Operation.thumbnail(source, width, [size: :VIPS_SIZE_DOWN] ++ opts),
         :ok <- File.mkdir_p(Path.dirname(cached)),
         :ok <- Image.write_to_file(image, tmp <> "[Q=75,strip]"),
         :ok <- File.rename(tmp, cached) do
      {:ok, cached, "image/webp"}
    else
      # 视频之类解不开的 blob
      _ ->
        File.rm(tmp)
        {:error, :not_found}
    end
  end

  defp head(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 4)) do
      {:ok, magic} when is_binary(magic) -> {:ok, magic}
      _ -> :error
    end
  end

  defp worker(cid), do: {:via, PartitionSupervisor, {__MODULE__, cid}}
  defp cache_root, do: Path.join(Application.fetch_env!(:rice, :storage_root), "thumbs")
end

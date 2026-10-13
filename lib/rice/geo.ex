defmodule Rice.Geo do
  @moduledoc """
  IP → 粗粒度地点,数据用 ip2region 的离线 xdb(境内到城市,境外到国家/省州)。

  xdb 两份共 48MB,但 dev-rice 只有 256MB 内存,所以不整份读进来 —— 每次查询只
  按需 `pread` 几十字节(header、vector index 的一项、二分中的 segment、数据区),
  常驻内存为零。一次查询二十几次系统调用、几十微秒,发帖本来就要过审核和 PDS,
  可以忽略。

  文件不在(开发、测试没下载 xdb)一律返回 `nil`,发帖照常,只是没有地点。
  """
  require Logger

  @header_size 256
  # vector index 紧跟 header:65536 项(前两个字节的组合),每项 8 字节的起止指针
  @vector_index_offset 256
  @vector_index_entry 8
  @vector_cols 256
  # segment index 一条的长度:v4 = 起止 IP(4+4) + 数据长度(2) + 数据指针(4);v6 前两个是 16 字节
  @segment_size v4: 14, v6: 38

  @doc """
  查一个 IP 的地点:境内给 `省·市`,境外给国家(库里带省/州就一起给)。

  IP 解析不了、库里没有、文件不在 —— 都是 `nil`。
  """
  @spec place(String.t() | nil) :: String.t() | nil
  def place(nil), do: nil

  def place(ip) when is_binary(ip) do
    with {:ok, tuple} <- :inet.parse_address(String.to_charlist(ip)),
         {:ok, version, bytes} <- ip_bytes(tuple),
         {:ok, file} <- open(version) do
      try do
        case search(file, bytes, version) do
          {:ok, region} -> label(region)
          _ -> nil
        end
      after
        File.close(file)
      end
    else
      _ -> nil
    end
  end

  def place(_), do: nil

  # ── IP → 文件版本 + 比较用的字节串 ─────────────────────────────────
  defp ip_bytes({a, b, c, d}), do: {:ok, :v4, <<a, b, c, d>>}
  # IPv4 映射的 IPv6(::ffff:1.2.3.4)按 v4 查
  defp ip_bytes({0, 0, 0, 0, 0, 0xFFFF, hi, lo}),
    do: {:ok, :v4, <<hi::16, lo::16>>}

  defp ip_bytes({a, b, c, d, e, f, g, h}),
    do: {:ok, :v6, <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>}

  # ── 文件 ───────────────────────────────────────────────────────────
  defp open(version) do
    path = path(version)

    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        {:ok, file}

      {:error, reason} ->
        warn_once(version, path, reason)
        :error
    end
  end

  # 缺文件是常态(开发、测试),只在第一次抱怨
  defp warn_once(version, path, reason) do
    key = {__MODULE__, :warned, version}

    unless :persistent_term.get(key, false) do
      Logger.warning("geo: 打不开 #{path}(#{inspect(reason)}),IP 地点一律留空")
      :persistent_term.put(key, true)
    end
  end

  defp path(version) do
    config = Application.get_env(:rice, __MODULE__, [])

    # 测试用它把版本指到自己造的 fixture;线上走 priv/geo(镜像里带的两份 xdb)
    Keyword.get(config, version) ||
      Path.join([Application.app_dir(:rice), "priv", "geo", file(version)])
  end

  defp file(:v4), do: "ip2region_v4.xdb"
  defp file(:v6), do: "ip2region_v6.xdb"

  # ── 查找 ───────────────────────────────────────────────────────────
  defp search(file, bytes, version) do
    with {:ok, header} <- read(file, 0, @header_size),
         :ok <- check_header(header, version),
         <<first, second, _::binary>> <- bytes,
         {:ok, s_ptr, e_ptr} <- read_vector_index(file, first, second) do
      segment(
        file,
        bytes,
        version,
        s_ptr,
        e_ptr,
        0,
        div(e_ptr - s_ptr, @segment_size[version]) - 1
      )
    end
  end

  # version 2 = 只有 IPv4 的老格式;version 3 带 ip_version 字段(4 / 6)
  defp check_header(header, version) do
    with <<file_version::16-little, _index_policy::16-little, _created_at::32-little,
           _start_ptr::32-little, _end_ptr::32-little, ip_version::16-little, _rest::binary>> <-
           header,
         expected <- if(version == :v4, do: 4, else: 6),
         ^expected <- if(file_version == 2, do: 4, else: ip_version) do
      :ok
    else
      _ -> :error
    end
  end

  defp read_vector_index(file, first, second) do
    offset = @vector_index_offset + (first * @vector_cols + second) * @vector_index_entry

    with {:ok, <<s_ptr::32-little, e_ptr::32-little>>} <- read(file, offset, @vector_index_entry),
         true <- e_ptr > s_ptr do
      {:ok, s_ptr, e_ptr}
    else
      _ -> :error
    end
  end

  # 在 [low, high] 上二分 segment index,找到 IP 落在的那段,读它的数据区
  defp segment(_file, _bytes, _version, _s_ptr, _e_ptr, low, high) when low > high, do: :error

  defp segment(file, bytes, version, s_ptr, e_ptr, low, high) do
    size = @segment_size[version]
    middle = div(low + high, 2)

    with {:ok, raw} <- read(file, s_ptr + middle * size, size),
         {:ok, s_ip, e_ip, data_len, data_ptr} <- decode_segment(raw, version) do
      case compare(bytes, s_ip, e_ip, version) do
        :below -> segment(file, bytes, version, s_ptr, e_ptr, low, middle - 1)
        :above -> segment(file, bytes, version, s_ptr, e_ptr, middle + 1, high)
        :inside -> read_region(file, data_ptr, data_len)
      end
    end
  end

  defp decode_segment(raw, :v4) do
    case raw do
      <<s_ip::32-little, e_ip::32-little, data_len::16-little, data_ptr::32-little>> ->
        {:ok, s_ip, e_ip, data_len, data_ptr}

      _ ->
        :error
    end
  end

  defp decode_segment(raw, :v6) do
    case raw do
      <<s_ip::binary-size(16), e_ip::binary-size(16), data_len::16-little, data_ptr::32-little>> ->
        {:ok, s_ip, e_ip, data_len, data_ptr}

      _ ->
        :error
    end
  end

  defp compare(bytes, s_ip, e_ip, :v4) do
    <<value::32>> = bytes
    if value < s_ip, do: :below, else: if(value > e_ip, do: :above, else: :inside)
  end

  defp compare(bytes, s_ip, e_ip, :v6) do
    if bytes < s_ip, do: :below, else: if(bytes > e_ip, do: :above, else: :inside)
  end

  defp read_region(file, data_ptr, data_len) do
    case read(file, data_ptr, data_len) do
      {:ok, raw} -> {:ok, String.trim_trailing(raw, <<0>>)}
      error -> error
    end
  end

  defp read(file, offset, length) do
    case :file.pread(file, offset, length) do
      {:ok, data} -> {:ok, data}
      :eof -> :error
      {:error, _reason} -> :error
    end
  end

  # ── 地点串 ─────────────────────────────────────────────────────────
  # 数据区是 `国家|省|市|运营商|国家代码`(顺序按现在这份 xdb 的实际内容,上游文档
  # 写的是另一版),没有的字段是 "0"。直辖市省和市同名,去重后只留一个。
  defp label(region) do
    parts = String.split(region, "|")

    case parts |> Enum.slice(1, 2) |> Enum.reject(&(&1 in [nil, "", "0"])) |> Enum.uniq() do
      [] -> plain(Enum.at(parts, 0))
      places -> Enum.join(places, "·")
    end
  end

  defp plain(nil), do: nil
  defp plain(value) when value in ["", "0"], do: nil
  defp plain(value), do: value
end

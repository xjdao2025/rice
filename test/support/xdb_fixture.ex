defmodule Rice.XdbFixture do
  @moduledoc """
  造一份只含一段的 xdb,给 IP 地点的测试用。

  真的 xdb 有几十 MB 不能进仓库;这里按 ip2region 的格式拼出最小的一份:
  256 字节 header + 512KB vector index(只有一项指向那段)+ 一条 segment + 数据区。
  """

  @header_size 256
  @vector_count 65_536

  @doc """
  写一份只覆盖 `起止地址` 这一段的 xdb。起止地址:v4 写成 4 个字节的元组
  (`{1, 2, 0, 0}`),v6 写成 8 个 16 位组的元组(`{0x2400, 0x3200, 0, ...}`)。

  `region` 是数据区的原样内容(`国家|地区|省|市|ISP`)。返回写好的路径。
  """
  @spec write(Path.t(), :v4 | :v6, {tuple(), tuple()}, String.t()) :: Path.t()
  def write(path, version, {start_address, end_address}, region) do
    start_bytes = pack(version, start_address)
    end_bytes = pack(version, end_address)
    segment_size = if(version == :v4, do: 14, else: 38)
    segment_at = @header_size + @vector_count * 8
    data_at = segment_at + segment_size
    <<first, second, _::binary>> = start_bytes

    File.write!(
      path,
      header(segment_at, segment_at + segment_size, version) <>
        vector(first * 256 + second, segment_at, segment_size) <>
        segment(version, start_bytes, end_bytes, byte_size(region), data_at) <>
        region
    )

    path
  end

  defp pack(:v4, {a, b, c, d}), do: <<a, b, c, d>>

  defp pack(:v6, {a, b, c, d, e, f, g, h}),
    do: <<a::16, b::16, c::16, d::16, e::16, f::16, g::16, h::16>>

  # vector index:65536 项各 8 字节的起止指针,只有 IP 头两个字节落在的那一项有值
  defp vector(index, segment_at, segment_size) do
    <<0::size(index * 64), segment_at::32-little, segment_at + segment_size::32-little,
      0::size((@vector_count - index - 1) * 64)>>
  end

  # version 3:带 ip_version 字段,4 = IPv4,6 = IPv6
  defp header(segment_at, end_ptr, version) do
    body =
      <<3::16-little, 1::16-little, 0::32-little, segment_at::32-little, end_ptr::32-little,
        if(version == :v4, do: 4, else: 6)::16-little, 4::16-little>>

    body <> :binary.copy(<<0>>, @header_size - byte_size(body))
  end

  defp segment(:v4, start_bytes, end_bytes, data_len, data_at) do
    <<:binary.decode_unsigned(start_bytes, :big)::32-little,
      :binary.decode_unsigned(end_bytes, :big)::32-little, data_len::16-little,
      data_at::32-little>>
  end

  defp segment(:v6, start_bytes, end_bytes, data_len, data_at) do
    <<start_bytes::binary, end_bytes::binary, data_len::16-little, data_at::32-little>>
  end
end

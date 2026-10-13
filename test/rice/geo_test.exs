defmodule Rice.GeoTest do
  # 每个用例都要把 Rice.Geo 指到自己造的 xdb(全局配置),不能并发
  use ExUnit.Case, async: false

  alias Rice.XdbFixture

  @cn {{{1, 2, 0, 0}, {1, 2, 255, 255}}, "中国|广东省|广州市|电信|CN"}

  setup do
    on_exit(fn -> Application.delete_env(:rice, Rice.Geo) end)
    :ok
  end

  # 造一份只覆盖一段的 xdb,让 Rice.Geo 查它
  defp db(version, {range, region}) do
    path =
      Path.join(
        System.tmp_dir!(),
        "ip2region-#{version}-#{System.unique_integer([:positive])}.xdb"
      )

    XdbFixture.write(path, version, range, region)
    Application.put_env(:rice, Rice.Geo, [{version, path}])
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "境内给到城市,直辖市不重复说两遍" do
    db(:v4, @cn)
    assert Rice.Geo.place("1.2.3.4") == "广东省·广州市"
    # IPv4 映射的 IPv6 按同一条 v4 段查
    assert Rice.Geo.place("::ffff:1.2.3.4") == "广东省·广州市"

    db(:v4, {{{1, 3, 0, 0}, {1, 3, 255, 255}}, "中国|北京市|北京市|0|CN"})
    assert Rice.Geo.place("1.3.4.5") == "北京市"
  end

  test "境外给国家,库里带省州就一起给" do
    db(:v4, {{{8, 8, 0, 0}, {8, 8, 255, 255}}, "美国|0|0|Google LLC|US"})
    assert Rice.Geo.place("8.8.8.8") == "美国"

    db(:v4, {{{9, 9, 0, 0}, {9, 9, 255, 255}}, "United States|California|Los Angeles|0|US"})
    assert Rice.Geo.place("9.9.9.9") == "California·Los Angeles"
  end

  test "IPv6 走 v6 那份库" do
    db(:v6, {
      {{0x2400, 0x3200, 0, 0, 0, 0, 0, 0},
       {0x2400, 0x3200, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF, 0xFFFF}},
      "日本|東京都|0|0|JP"
    })

    assert Rice.Geo.place("2400:3200::1") == "東京都"
  end

  test "查不到、解析不了、没库一律留空" do
    db(:v4, @cn)
    refute Rice.Geo.place("8.8.8.8")
    refute Rice.Geo.place("这不是 IP")
    refute Rice.Geo.place(nil)

    Application.put_env(:rice, Rice.Geo,
      v4: "/tmp/does-not-exist-#{:erlang.unique_integer([:positive])}.xdb"
    )

    refute Rice.Geo.place("1.2.3.4")

    # 没配也没 priv/geo(开发机不下载 xdb)
    Application.delete_env(:rice, Rice.Geo)
    refute Rice.Geo.place("1.2.3.4")
  end
end

defmodule Rice.TsidTest do
  # 这个模块测的是全局的生成器状态,还要测时间偏移 —— 必须独占运行
  use ExUnit.Case, async: false

  alias Rice.Tsid

  @alphabet ~c"234567abcdefghijklmnopqrstuvwxyz"

  describe "与 semi-backend 的 tsid.rb 兼容" do
    # 下列向量由真实的 /Users/jiang/dev/semi/semi-backend/lib/tsid.rb 生成:
    #
    #   g = Tsid::Generator.new(0)
    #   g.encode((timestamp_us << 10) | clock_id)
    #
    # 改动 Rice.Tsid 的编码时,这组断言必须原样通过 —— 两个系统的 ID 要能互认。
    @vectors [
      {0, 0, 0, "2222222222222"},
      {1, 0, 1024, "2222222222322"},
      {1, 1023, 2047, "22222222223zz"},
      {1_700_000_000_000_000, 42, 1_740_800_000_000_000_042, "3ke6kg3wk223e"},
      {9_007_199_254_740_991, 1023, 9_223_372_036_854_775_807, "bzzzzzzzzzzzz"}
    ]

    test "encode/1 与 Ruby 实现逐位一致" do
      for {_us, _clock, int, expected} <- @vectors do
        assert Tsid.encode(int) == expected
      end
    end

    test "decode/1 与 Ruby 实现逐位一致" do
      for {_us, _clock, int, encoded} <- @vectors do
        assert Tsid.decode(encoded) == int
      end
    end

    test "parse/1 还原出原始的时间戳与 clock_id" do
      for {us, clock, _int, encoded} <- @vectors do
        assert Tsid.parse(encoded) == {us, clock}
      end
    end
  end

  describe "generate/0" do
    test "总是 13 个字符" do
      for _ <- 1..1_000, do: assert(String.length(Tsid.generate()) == 13)
    end

    test "只用字母表内的字符" do
      chars = for _ <- 1..1_000, into: MapSet.new(), do: Tsid.generate()

      for tsid <- chars, char <- String.to_charlist(tsid) do
        assert char in @alphabet, "非法字符 #{inspect(<<char>>)} 出现在 #{tsid}"
      end
    end

    test "严格单调递增" do
      ids = for _ <- 1..10_000, do: Tsid.generate()

      assert ids == Enum.sort(ids), "生成序不等于字典序"
      assert ids == Enum.uniq(ids), "出现重复 ID"

      # 逐对严格大于,而不只是"排序后一样"
      for [a, b] <- Enum.chunk_every(ids, 2, 1, :discard) do
        assert a < b
      end
    end

    test "并发生成不产生碰撞" do
      ids =
        1..50
        |> Task.async_stream(fn _ -> for _ <- 1..200, do: Tsid.generate() end,
          max_concurrency: 50,
          timeout: 30_000
        )
        |> Enum.flat_map(fn {:ok, batch} -> batch end)

      assert length(ids) == 10_000
      assert length(Enum.uniq(ids)) == 10_000
    end

    test "时间戳不早于生成前的墙钟" do
      before = System.os_time(:microsecond)
      {us, _clock_id} = Tsid.parse(Tsid.generate())
      assert us >= before
    end

    # 单调性靠 `max(now, last + 1)` 保证,代价是:同一微秒内连发 N 个 ID,
    # 时间戳会被推到未来最多 N 微秒。Ruby 版 tsid.rb 行为相同。
    # 1 微秒/个 => 每秒 100 万个才会持续偏移;真实负载下偏移会自己收敛回 0。
    #
    # 注意偏移是**进程级累积**的:本模块前面的用例已经生成了两万多个 ID,
    # 起始偏移就不是 0。所以先 init/0 把计数器归零,否则上界断言会偶发失败
    # (实测 20 次里挂 2 次)。本模块 async: false,重置不会影响别的测试。
    test "突发生成会把时间戳推向未来,但幅度有上界" do
      Tsid.init()
      n = 20_000
      before = System.os_time(:microsecond)
      ids = for _ <- 1..n, do: Tsid.generate()
      {last_us, _} = Tsid.parse(List.last(ids))

      drift = last_us - System.os_time(:microsecond)
      assert drift < n, "偏移 #{drift}µs 超过了生成个数 #{n} 的上界"
      assert last_us >= before
    end

    test "低速生成时时间戳贴合墙钟" do
      # 归零,让前面用例积累的偏移不影响这里的判断
      Tsid.init()

      for _ <- 1..5 do
        now = System.os_time(:microsecond)
        {us, _} = Tsid.parse(Tsid.generate())
        assert abs(us - now) < 1_000, "偏离墙钟 #{abs(us - now)}µs"
        Process.sleep(10)
      end
    end

    test "同一节点内 clock_id 固定" do
      clock_ids = for _ <- 1..100, into: MapSet.new(), do: elem(Tsid.parse(Tsid.generate()), 1)
      assert MapSet.size(clock_ids) == 1
    end
  end

  describe "valid?/1" do
    test "接受自己生成的 ID" do
      for _ <- 1..100, do: assert(Tsid.valid?(Tsid.generate()))
    end

    test "拒绝长度不对的" do
      refute Tsid.valid?("")
      refute Tsid.valid?("222222222222")
      refute Tsid.valid?("22222222222222")
    end

    test "拒绝字母表外的字符" do
      # 0 1 8 9 和大写字母都不在 base32-sortable 字母表里(刻意排除易混字符)
      refute Tsid.valid?("2222222222220")
      refute Tsid.valid?("2222222222221")
      refute Tsid.valid?("2222222222228")
      refute Tsid.valid?("2222222222229")
      refute Tsid.valid?("222222222222A")
      refute Tsid.valid?("222222222222-")
    end

    test "拒绝非字符串" do
      refute Tsid.valid?(nil)
      refute Tsid.valid?(123)
      refute Tsid.valid?(:atom)
    end
  end

  describe "to_datetime/1" do
    test "还原出生成时刻" do
      before = DateTime.utc_now()
      tsid = Tsid.generate()
      dt = Tsid.to_datetime(tsid)

      assert DateTime.compare(dt, before) in [:gt, :eq]
      assert DateTime.diff(DateTime.utc_now(), dt, :millisecond) < 1_000
    end
  end

  describe "decode/1 的错误处理" do
    test "长度不对时抛 ArgumentError" do
      assert_raise ArgumentError, ~r/长度必须是 13/, fn -> Tsid.decode("abc") end
    end

    test "非法字符时抛 ArgumentError" do
      assert_raise ArgumentError, ~r/非法字符/, fn -> Tsid.decode("222222222222!") end
    end
  end
end

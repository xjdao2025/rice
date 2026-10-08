defmodule Rice.Tsid.TypeTest do
  use ExUnit.Case, async: true

  alias Rice.Tsid
  alias Rice.Tsid.Type

  test "cast/1 接受合法 TSID" do
    tsid = Tsid.generate()
    assert Type.cast(tsid) == {:ok, tsid}
  end

  test "dump/1 同样校验" do
    tsid = Tsid.generate()
    assert Type.dump(tsid) == {:ok, tsid}
    assert Type.dump("nope") == :error
    assert Type.dump(nil) == :error
  end

  test "load/1 原样返回(库里的值假定已经合法)" do
    assert Type.load("2222222222222") == {:ok, "2222222222222"}
    assert Type.load(42) == :error
  end

  test "cast → dump → load 往返不变" do
    tsid = Tsid.generate()
    assert {:ok, cast} = Type.cast(tsid)
    assert {:ok, dumped} = Type.dump(cast)
    assert {:ok, ^tsid} = Type.load(dumped)
  end
end

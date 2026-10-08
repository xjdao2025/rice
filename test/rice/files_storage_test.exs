defmodule Rice.Files.StorageLocalTest do
  @moduledoc "本机磁盘实现。这个模块真的读写磁盘,所以用临时目录并在结束时清掉。"
  use ExUnit.Case, async: false

  alias Rice.Files.Storage.Local

  setup do
    root = Path.join(System.tmp_dir!(), "rice_storage_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    previous = Application.get_env(:rice, :storage_root)
    Application.put_env(:rice, :storage_root, root)

    on_exit(fn ->
      File.rm_rf!(root)
      Application.put_env(:rice, :storage_root, previous)
    end)

    %{root: root}
  end

  defp key, do: Rice.Files.storage_key(Rice.Tsid.generate())

  test "put 之后 get 拿回同样的字节" do
    k = key()
    assert :ok = Local.put(k, "你好,世界")
    assert {:ok, "你好,世界"} = Local.get(k)
  end

  test "二进制内容不被改动" do
    k = key()
    content = :crypto.strong_rand_bytes(4096)
    assert :ok = Local.put(k, content)
    assert {:ok, ^content} = Local.get(k)
  end

  test "不存在的 key" do
    assert {:error, :enoent} = Local.get(key())
    refute Local.exists?(key())
  end

  test "delete 是幂等的" do
    k = key()
    :ok = Local.put(k, "x")
    assert :ok = Local.delete(k)
    assert :ok = Local.delete(k)
    refute Local.exists?(k)
  end

  test "落盘路径落在 root 之内,且只由 key 决定", %{root: root} do
    k = key()
    :ok = Local.put(k, "x")

    files = Path.wildcard(Path.join(root, "**/*")) |> Enum.filter(&File.regular?/1)
    assert [path] = files
    assert path == Path.join(root, k)
  end

  # key 是我们自己按 TSID 生成的,但这层校验是最后一道闸 —— 漏掉一次的代价是
  # 任意文件读写。这些用例确保它不会在重构中被悄悄拿掉。
  describe "拒绝非法 key" do
    test "路径穿越" do
      for bad <- ["../../etc/passwd", "ab/../../../etc/passwd", "ab/../cd", "/etc/passwd"] do
        assert_raise ArgumentError, fn -> Local.get(bad) end
        assert_raise ArgumentError, fn -> Local.put(bad, "x") end
      end
    end

    test "形状不对" do
      for bad <- ["", "abc", "a/b", "abc/def", "ab/ABCDEFGHIJKLM", "ab/abcdefghijkl"] do
        assert_raise ArgumentError, fn -> Local.get(bad) end
      end
    end
  end
end

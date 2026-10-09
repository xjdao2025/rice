defmodule RiceWeb.ThumbControllerTest do
  # 改的是全局的 Application env
  use RiceWeb.ConnCase, async: false

  alias Vix.Vips.{Image, Operation}

  @did "did:plc:3ch55vps4vmaow6akmt7ju7s"
  @jpeg "bafkreie2qpcqkbxelswcnnnoih7nhnlcmqgio3whfv5h6kfoiv7jxvmh2e"
  @gif "bafkreig4rgqljmjh5ekcpq3dn656oze4honytgjhqq7kophy75incg36o4"
  @video "bafkreibrf5wqu3qeklnwfrdqws6dfg57f33mnrtdr4ujcsffhkcpw2av6u"

  setup do
    root = Path.join(System.tmp_dir!(), "rice-thumbs-#{System.unique_integer([:positive])}")
    blobs = Path.join(root, "blobs/#{@did}")
    File.mkdir_p!(blobs)

    {:ok, image} = Operation.black(1200, 900)
    {:ok, jpeg} = Image.write_to_buffer(image, ".jpg")
    File.write!(Path.join(blobs, @jpeg), jpeg)
    File.write!(Path.join(blobs, @gif), "GIF89a" <> :binary.copy(<<0>>, 32))
    File.write!(Path.join(blobs, @video), "not an image")

    previous =
      {Application.get_env(:rice, :pds_blob_root), Application.get_env(:rice, :storage_root)}

    Application.put_env(:rice, :pds_blob_root, Path.join(root, "blobs"))
    Application.put_env(:rice, :storage_root, Path.join(root, "storage"))

    on_exit(fn ->
      Application.put_env(:rice, :pds_blob_root, elem(previous, 0))
      Application.put_env(:rice, :storage_root, elem(previous, 1))
      File.rm_rf!(root)
    end)

    %{blobs: blobs}
  end

  test "按档位缩成 WebP,长缓存", %{conn: conn} do
    conn = get(conn, "/img/feed/#{@did}/#{@jpeg}")

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=604800"]

    {:ok, thumb} = Image.new_from_buffer(conn.resp_body)
    assert {Image.width(thumb), Image.height(thumb)} == {800, 600}
  end

  test "头像裁成正方形", %{conn: conn} do
    {:ok, thumb} = Image.new_from_buffer(get(conn, "/img/avatar/#{@did}/#{@jpeg}").resp_body)
    assert {Image.width(thumb), Image.height(thumb)} == {256, 256}
  end

  test "GIF 动图原样返回", %{conn: conn} do
    conn = get(conn, "/img/feed/#{@did}/#{@gif}")
    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/gif"]
    assert "GIF89a" <> _ = conn.resp_body
  end

  test "原图被 PDS 移走后,缓存的缩略图也不再给", %{conn: conn, blobs: blobs} do
    assert get(conn, "/img/feed/#{@did}/#{@jpeg}").status == 200
    File.rm!(Path.join(blobs, @jpeg))
    assert get(build_conn(), "/img/feed/#{@did}/#{@jpeg}").status == 404
  end

  test "解不开的 blob、未知档位、非法 did/cid 都是 404", %{conn: conn} do
    for path <- [
          "/img/feed/#{@did}/#{@video}",
          "/img/huge/#{@did}/#{@jpeg}",
          "/img/feed/did:plc:..%2F..%2Fetc/#{@jpeg}",
          "/img/feed/#{@did}/..%2F..%2Fpasswd",
          "/img/feed/#{@did}/bafkreie2qpcqkbxelswcnnnoih7nhnlcmqgio3whfv5h6kfoiv7jxvmh2f"
        ] do
      assert get(conn, path).status == 404, path
    end
  end

  test "预热只缩能缩的" do
    assert Rice.Thumbs.warm() == %{ok: 2, skipped: 1}
  end
end

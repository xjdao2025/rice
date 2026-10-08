defmodule Rice.FilesTest do
  use Rice.DataCase, async: true

  import Mox

  alias Rice.Files
  alias Rice.Files.Attachment

  setup :verify_on_exit!

  describe "parse_legacy_id/1" do
    test "解析 core 的 fileId" do
      assert {:ok, %{kind: "image", filename: "banner.png"}} =
               Attachment.parse_legacy_id("1-2301a9c291aa4c86b7731a12e2f03744-banner.png")

      assert {:ok, %{kind: "file", filename: "乡建DAO-截至20250831 财务收支 （公示）.pdf"}} =
               Attachment.parse_legacy_id(
                 "2-408513feee1144a2aa3668ee61f2e117-乡建DAO-截至20250831 财务收支 （公示）.pdf"
               )
    end

    # 线上真实存在这种文件名 —— 只切前两段,后面的连字符全属于文件名
    test "原始文件名里的连字符不会被切断" do
      assert {:ok, %{filename: "GU logo 1-512.jpg"}} =
               Attachment.parse_legacy_id("1-b656bee82c934e70b4831a75a5abcfdc-GU logo 1-512.jpg")
    end

    test "拒绝无法解析的输入" do
      for bad <- ["", "1", "1-abc", "1-abc-", "9-abc-x.png", "x-abc-y.png", nil, 42] do
        assert Attachment.parse_legacy_id(bad) == :error, "不该接受 #{inspect(bad)}"
      end
    end
  end

  describe "storage_key/1" do
    test "分两级目录,只由 id 决定" do
      id = Rice.Tsid.generate()
      assert Files.storage_key(id) == String.slice(id, 0, 2) <> "/" <> id
    end
  end

  describe "fetch_attachment/1" do
    test "命中" do
      attachment = attachment_fixture()
      assert {:ok, found} = Files.fetch_attachment(attachment.id)
      assert found.id == attachment.id
    end

    test "不存在返回 :not_found" do
      assert Files.fetch_attachment(Rice.Tsid.generate()) == {:error, :not_found}
    end

    test "非法 id 直接 :not_found,不打数据库" do
      for bad <- ["abc", "222222222222", "../../etc/passwd"] do
        assert Files.fetch_attachment(bad) == {:error, :not_found}
      end
    end
  end

  describe "create_attachment/2" do
    test "算出大小和 sha256,落盘 key 由 id 决定" do
      content = "hello"
      expected = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

      expect(Rice.Files.StorageMock, :put, fn _key, ^content -> :ok end)

      assert {:ok, attachment} =
               Files.create_attachment(content, %{
                 kind: "image",
                 filename: "a.png",
                 content_type: "image/png"
               })

      assert attachment.byte_size == 5
      assert attachment.checksum == expected
      assert attachment.storage_key == Files.storage_key(attachment.id)
    end

    test "拒绝空文件" do
      assert {:error, changeset} =
               Files.create_attachment("", %{
                 kind: "image",
                 filename: "a.png",
                 content_type: "image/png"
               })

      assert errors_on(changeset)[:byte_size]
    end

    test "拒绝超过上限的文件" do
      big = :binary.copy("a", Files.max_byte_size() + 1)

      assert {:error, changeset} =
               Files.create_attachment(big, %{
                 kind: "image",
                 filename: "big.png",
                 content_type: "image/png"
               })

      assert "超过 20MB 上限" in errors_on(changeset).byte_size
    end

    test "拒绝白名单外的 content type" do
      for bad <- ["application/x-sh", "text/x-php", "application/octet-stream"] do
        assert {:error, changeset} =
                 Files.create_attachment("x", %{
                   kind: "image",
                   filename: "a.png",
                   content_type: bad
                 })

        assert "不支持的文件类型" in errors_on(changeset).content_type,
               "不该接受 #{bad}"
      end
    end

    # 后台批量发放的模板是 Excel。没有这两项,换一版模板根本传不上来。
    test "收 Excel —— 后台的批量操作模板要靠它上传" do
      for good <- [
            "application/vnd.ms-excel",
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
          ] do
        expect(Rice.Files.StorageMock, :put, fn _key, _content -> :ok end)

        assert {:ok, _} =
                 Files.create_attachment("x", %{
                   kind: "file",
                   filename: "稻米发放模板.xlsx",
                   content_type: good
                 }),
               "应该接受 #{good}"
      end
    end

    # 表格只算"文件",不算图片 —— kind 和 content_type 得对得上
    test "Excel 走 kind=file,当成图片传是不行的" do
      assert {:error, changeset} =
               Files.create_attachment("x", %{
                 kind: "image",
                 filename: "模板.xlsx",
                 content_type: "application/vnd.ms-excel"
               })

      assert "不支持的文件类型" in errors_on(changeset).content_type
    end

    # 顺序很重要:校验失败时绝不该碰存储。Mox 的 verify_on_exit! 会确认
    # put 一次都没被调用 —— 没有 expect 就意味着"不允许调用"。
    test "校验失败时不写存储" do
      assert {:error, _} =
               Files.create_attachment("x", %{
                 kind: "image",
                 filename: "a.png",
                 content_type: "application/x-sh"
               })
    end

    test "落盘失败时不写元数据" do
      expect(Rice.Files.StorageMock, :put, fn _key, _content -> {:error, :enospc} end)

      assert {:error, {:storage, :enospc}} =
               Files.create_attachment("x", %{
                 kind: "image",
                 filename: "a.png",
                 content_type: "image/png"
               })

      assert Rice.Repo.aggregate(Attachment, :count) == 0
    end
  end

  describe "read/1" do
    test "读出字节" do
      attachment = attachment_fixture(%{storage_key: "ab/abcdefghijklm"})
      expect(Rice.Files.StorageMock, :get, fn "ab/abcdefghijklm" -> {:ok, "内容"} end)

      assert {:ok, "内容"} = Files.read(attachment)
    end

    test "还没回填字节时返回 :not_stored" do
      attachment = attachment_fixture()
      assert Files.read(attachment) == {:error, :not_stored}
    end

    test "元数据在但文件丢了,也是 :not_stored" do
      attachment = attachment_fixture(%{storage_key: "ab/abcdefghijklm"})
      expect(Rice.Files.StorageMock, :get, fn _ -> {:error, :enoent} end)

      assert Files.read(attachment) == {:error, :not_stored}
    end
  end
end

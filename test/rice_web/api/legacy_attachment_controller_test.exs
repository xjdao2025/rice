defmodule RiceWeb.Api.LegacyAttachmentControllerTest do
  use RiceWeb.ConnCase, async: true

  import Mox

  setup :verify_on_exit!

  @guid "27110018f04343b4836d8f529bb4676f"

  test "legacy 图片 GUID 支持大小写并保留原读取响应", %{conn: conn} do
    attachment = stored_fixture("1-#{@guid}-乡建图片.png")

    expect(Rice.Files.StorageMock, :get, fn key ->
      assert key == attachment.storage_key
      {:ok, "PNGDATA"}
    end)

    conn = get(conn, ~p"/api/v1/file/download", %{fileId: String.upcase(@guid), fileType: "1"})

    assert response(conn, 200) == "PNGDATA"
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
    assert get_resp_header(conn, "etag") == [~s("#{attachment.id}")]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "inline;"
    assert disposition |> String.split("''") |> List.last() |> URI.decode() == "乡建图片.png"
  end

  test "fileType=2 的 HTML 文件仍被强制下载", %{conn: conn} do
    attachment =
      stored_fixture("2-#{@guid}-notice.html", %{kind: "file", content_type: "text/html"})

    expect(Rice.Files.StorageMock, :get, fn key ->
      assert key == attachment.storage_key
      {:ok, "<p>公告</p>"}
    end)

    conn = get(conn, ~p"/api/v1/file/download", %{fileId: @guid, fileType: "2"})

    assert response(conn, 200) == "<p>公告</p>"
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ "attachment;"
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
  end

  test "缺少、非法或不存在的查询都返回 404", %{conn: conn} do
    for params <- [
          %{},
          %{fileId: @guid},
          %{fileId: "../#{@guid}", fileType: "1"},
          %{fileId: @guid <> "\n", fileType: "1"},
          %{fileId: String.duplicate("%", 32), fileType: "1"},
          %{fileId: @guid, fileType: "3"},
          %{fileId: @guid, fileType: "1"}
        ] do
      assert conn |> get(~p"/api/v1/file/download", params) |> json_response(404)
    end
  end

  test "多个文件共享同一类型和 GUID 时拒绝选择任意文件", %{conn: conn} do
    stored_fixture("1-#{@guid}-first.png")
    stored_fixture("1-#{@guid}-second.png")

    assert conn
           |> get(~p"/api/v1/file/download", %{fileId: @guid, fileType: "1"})
           |> json_response(404)
  end

  defp stored_fixture(legacy_id, attrs \\ %{}) do
    {:ok, parsed} = Rice.Files.Attachment.parse_legacy_id(legacy_id)
    attachment = attachment_fixture(parsed |> Map.put(:legacy_id, legacy_id) |> Map.merge(attrs))

    Rice.Repo.update!(
      Ecto.Changeset.change(attachment, storage_key: Rice.Files.storage_key(attachment.id))
    )
  end
end

defmodule Rice.Import.EmbeddedFilesTest do
  @moduledoc "要真的读 core 的目录、真的落盘,所以和回填测试一样用临时目录 + 本机存储。"
  use Rice.DataCase, async: false

  alias Rice.Files
  alias Rice.Files.Attachment
  alias Rice.Import.EmbeddedFiles
  alias Rice.Repo

  @base "https://rice.example.test"
  @g1 "9368fed9e4074b06afb9b558690a8b7b"
  @g2 "586e300ea7b74a048476f79be35307c5"
  @video "3d2a35b7b4ec44c4a687e055d954ecda"

  setup do
    source = Path.join(System.tmp_dir!(), "core_data_#{System.unique_integer([:positive])}")
    dest = Path.join(System.tmp_dir!(), "rice_store_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(source, "Picture"))
    File.mkdir_p!(Path.join(source, "File"))
    File.mkdir_p!(dest)

    prev_storage = Application.get_env(:rice, :storage)
    prev_root = Application.get_env(:rice, :storage_root)
    Application.put_env(:rice, :storage, Rice.Files.Storage.Local)
    Application.put_env(:rice, :storage_root, dest)

    on_exit(fn ->
      File.rm_rf!(source)
      File.rm_rf!(dest)
      Application.put_env(:rice, :storage, prev_storage)
      Application.put_env(:rice, :storage_root, prev_root)
    end)

    %{source: source}
  end

  defp core_file(source, subdir, guid, filename, content) do
    File.write!(Path.join([source, subdir, "#{guid}-#{filename}"]), content)
  end

  defp img(host, guid, type \\ "1"),
    do: ~s(<img src="#{host}/api/v1/file/download?fileId=#{guid}&fileType=#{type}" alt="image" />)

  defp body_fixture(html, content_type \\ "text/plain; charset=utf-8") do
    {:ok, a} =
      Files.create_legacy_attachment(html, %{
        kind: "file",
        filename: "proposal_content.txt",
        content_type: content_type
      })

    a
  end

  defp proposal_with(body) do
    proposal_fixture(user_fixture(), %{attachment_id: body.id})
  end

  defp body_of(proposal) do
    proposal = Repo.reload!(proposal)
    {:ok, html} = Files.read(Repo.get!(Attachment, proposal.attachment_id))
    html
  end

  test "搬文件、改写地址、提案指向新正文", %{source: source} do
    core_file(source, "Picture", @g1, "image_1.jpg", "JPEG1")
    core_file(source, "Picture", @g2, "image_2.png", "PNG2")

    old =
      body_fixture(
        "<div>正文</div>" <> img("https://xjdao.xyz", @g1) <> img("http://xjdao.xyz", @g2)
      )

    proposal = proposal_with(old)

    result = EmbeddedFiles.run(source, @base, true)

    assert result.files_copied == 2
    assert result.missing == [] and result.failed == []

    html = body_of(proposal)
    refute html =~ "file/download"
    assert html =~ "<div>正文</div>"

    [id1, id2] =
      Regex.scan(~r{#{@base}/api/attachments/([0-9a-z]+)}, html, capture: :all_but_first)
      |> List.flatten()

    img1 = Repo.get!(Attachment, id1)
    assert img1.legacy_id == "1-#{@g1}-image_1.jpg"
    assert img1.kind == "image"
    assert img1.content_type == "image/jpeg"
    assert {:ok, "JPEG1"} = Files.read(img1)
    assert {:ok, "PNG2"} = Files.read(Repo.get!(Attachment, id2))
  end

  test "不原地覆盖:旧正文原样保留,新正文是新 id,元数据照搬", %{source: source} do
    core_file(source, "Picture", @g1, "a.jpg", "x")
    original = img("https://xjdao.xyz", @g1)
    old = body_fixture(original)
    proposal = proposal_with(old)

    EmbeddedFiles.run(source, @base, true)

    new_id = Repo.reload!(proposal).attachment_id
    refute new_id == old.id
    assert {:ok, ^original} = Files.read(Repo.reload!(old))

    new = Repo.get!(Attachment, new_id)
    assert new.filename == old.filename
    assert new.content_type == old.content_type
    assert new.kind == old.kind
    {:ok, html} = Files.read(new)
    assert new.byte_size == byte_size(html)
  end

  test "公告和站点文档也改指", %{source: source} do
    core_file(source, "File", @video, "video.mp4", "MP4")

    old =
      body_fixture(
        ~s(<video src="https://xjdao.xyz/api/v1/file/download?fileId=#{@video}&amp;fileType=2"></video>),
        "text/html; charset=utf-8"
      )

    announcement = announcement_fixture(%{attachment_id: old.id})
    site_document_fixture(site_settings_fixture(), old)

    result = EmbeddedFiles.run(source, @base, true)

    assert [%{refs: %{"announcements" => 1, "site_setting_documents" => 1, "proposals" => 0}}] =
             result.hosts

    new_id = Repo.reload!(announcement).attachment_id
    {:ok, html} = Files.read(Repo.get!(Attachment, new_id))
    assert html =~ ~s(<video src="#{@base}/api/attachments/)

    # mp4 不在上传白名单里,但历史文件照样要能搬
    [video] = Repo.all(from a in Attachment, where: like(a.legacy_id, ^"2-#{@video}-%"))
    assert video.kind == "file"
    assert video.content_type == "video/mp4"
  end

  test "相对路径的 core 地址也改写", %{source: source} do
    core_file(source, "Picture", @g1, "120.png", "PNG")

    old =
      body_fixture(
        ~s(<img src="/api/v1/file/download?fileId=#{@g1}&amp;fileType=1" />),
        "text/html; charset=utf-8"
      )

    announcement = announcement_fixture(%{attachment_id: old.id})

    assert %{files_copied: 1, missing: []} = EmbeddedFiles.run(source, @base, true)

    {:ok, html} = Files.read(Repo.get!(Attachment, Repo.reload!(announcement).attachment_id))
    assert html =~ ~s(<img src="#{@base}/api/attachments/)
    refute html =~ "file/download"
  end

  test "已经导入过的文件直接复用,不重复搬", %{source: source} do
    core_file(source, "Picture", @g1, "a.jpg", "x")

    {:ok, existing} =
      Files.create_legacy_attachment("x", %{
        kind: "image",
        filename: "a.jpg",
        legacy_id: "1-#{@g1}-a.jpg"
      })

    proposal = proposal_with(body_fixture(img("https://xjdao.xyz", @g1)))

    result = EmbeddedFiles.run(source, @base, true)

    assert result.files_reused == 1 and result.files_copied == 0
    assert body_of(proposal) =~ "/api/attachments/#{existing.id}"
  end

  test "源文件缺失的地址原样保留,其余照改", %{source: source} do
    core_file(source, "Picture", @g1, "a.jpg", "x")
    gone = img("https://xjdao.xyz", @g2)
    proposal = proposal_with(body_fixture(img("https://xjdao.xyz", @g1) <> gone))

    result = EmbeddedFiles.run(source, @base, true)

    assert [{_, @g2}] = result.missing
    html = body_of(proposal)
    assert html =~ gone
    assert html =~ "#{@base}/api/attachments/"
  end

  test "fileType 和实际目录对不上时去另一个目录找", %{source: source} do
    core_file(source, "File", @g1, "a.jpg", "x")
    proposal = proposal_with(body_fixture(img("https://xjdao.xyz", @g1, "1")))

    assert %{files_copied: 1, missing: []} = EmbeddedFiles.run(source, @base, true)
    refute body_of(proposal) =~ "file/download"
  end

  test "dry-run 不写任何东西", %{source: source} do
    core_file(source, "Picture", @g1, "a.jpg", "x")
    old = body_fixture(img("https://xjdao.xyz", @g1))
    proposal = proposal_with(old)
    before = Repo.aggregate(Attachment, :count)

    result = EmbeddedFiles.run(source, @base, false)

    assert [%{urls: 1, rewritten: 1}] = result.hosts
    assert Repo.aggregate(Attachment, :count) == before
    assert Repo.reload!(proposal).attachment_id == old.id
  end

  test "幂等:第二次跑什么都不做,也不给被替换下来的旧正文再生成新附件", %{source: source} do
    core_file(source, "Picture", @g1, "a.jpg", "x")
    proposal = proposal_with(body_fixture(img("https://xjdao.xyz", @g1)))

    EmbeddedFiles.run(source, @base, true)
    after_first = Repo.aggregate(Attachment, :count)
    id_after_first = Repo.reload!(proposal).attachment_id

    assert %{hosts: [], files_copied: 0} = EmbeddedFiles.run(source, @base, true)
    assert Repo.aggregate(Attachment, :count) == after_first
    assert Repo.reload!(proposal).attachment_id == id_after_first
  end

  test "不含 core 地址的正文和非文本附件不动", %{source: source} do
    plain = body_fixture("<div>没有图</div>")
    proposal = proposal_with(plain)

    assert %{hosts: []} = EmbeddedFiles.run(source, @base, true)
    assert Repo.reload!(proposal).attachment_id == plain.id
  end
end

defmodule Rice.SettingsTest do
  use Rice.DataCase, async: true

  describe "单例约束" do
    # core 的 t_global_config 是普通表,靠应用层"取第一行"来假装单例,
    # 插第二行不会有任何阻力。这里把约束交给数据库。
    test "第二行会被数据库挡下" do
      site_settings_fixture()

      assert {:error, changeset} =
               %Rice.Settings.Site{}
               |> Rice.Settings.Site.changeset(%{fund_scale: 1})
               |> Rice.Repo.insert()

      assert "全站配置只能有一行" in errors_on(changeset).id
    end
  end

  describe "get_site/0" do
    test "有配置时预加载文件及其附件" do
      site = site_settings_fixture()
      attachment = attachment_fixture(%{kind: "file", filename: "财务公示.pdf"})
      site_document_fixture(site, attachment)

      loaded = Rice.Settings.get_site()

      assert [%{attachment: %{filename: "财务公示.pdf"}}] = loaded.documents
    end

    test "同一份文件不能挂两次" do
      site = site_settings_fixture()
      attachment = attachment_fixture(%{kind: "file"})
      site_document_fixture(site, attachment)

      assert {:error, changeset} =
               %Rice.Settings.Document{}
               |> Rice.Settings.Document.changeset(%{
                 site_setting_id: site.id,
                 attachment_id: attachment.id
               })
               |> Rice.Repo.insert()

      assert errors_on(changeset)[:site_setting_id] || errors_on(changeset)[:attachment_id]
    end
  end
end

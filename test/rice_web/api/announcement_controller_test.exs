defmodule RiceWeb.Api.AnnouncementControllerTest do
  use RiceWeb.ConnCase, async: true

  describe "GET /api/announcements" do
    test "空库返回空数组和 null 游标", %{conn: conn} do
      assert %{"data" => [], "meta" => %{"next_cursor" => nil}} =
               conn |> get(~p"/api/announcements") |> json_response(200)
    end

    test "position 相同时新的在前", %{conn: conn} do
      a = announcement_fixture(%{title: "第一条"})
      b = announcement_fixture(%{title: "第二条"})
      c = announcement_fixture(%{title: "第三条"})

      assert %{"data" => data} = conn |> get(~p"/api/announcements") |> json_response(200)
      assert Enum.map(data, & &1["id"]) == [c.id, b.id, a.id]
    end

    # 公告栏的顺序是后台拖出来的。只按 id 倒序的话,大厅首页那三条的顺序
    # 和生产对不上 —— 生产是 `Sort ASC, CreatedAt DESC`。
    test "按 position 升序,压过时间序", %{conn: conn} do
      last = announcement_fixture(%{title: "排最后的", position: 2})
      first = announcement_fixture(%{title: "排最前的", position: 0})
      middle = announcement_fixture(%{title: "排中间的", position: 1})

      assert %{"data" => data} = conn |> get(~p"/api/announcements") |> json_response(200)
      assert Enum.map(data, & &1["title"]) == ["排最前的", "排中间的", "排最后的"]
      assert Enum.map(data, & &1["id"]) == [first.id, middle.id, last.id]
    end

    test "同一 position 内部仍按时间倒序", %{conn: conn} do
      old = announcement_fixture(%{title: "同位置的旧公告", position: 1})
      new = announcement_fixture(%{title: "同位置的新公告", position: 1})
      top = announcement_fixture(%{title: "置顶", position: 0})

      assert %{"data" => data} = conn |> get(~p"/api/announcements") |> json_response(200)
      assert Enum.map(data, & &1["id"]) == [top.id, new.id, old.id]
    end

    test "响应字段齐全", %{conn: conn} do
      attachment = attachment_fixture(%{kind: "file", filename: "公约.html"})
      announcement_fixture(%{title: "社区公约", position: 2, attachment_id: attachment.id})

      assert %{"data" => [item]} = conn |> get(~p"/api/announcements") |> json_response(200)

      assert %{
               "title" => "社区公约",
               "position" => 2,
               "attachment" => %{"filename" => "公约.html", "kind" => "file"},
               "inserted_at" => inserted_at
             } = item

      assert {:ok, _, _} = DateTime.from_iso8601(inserted_at)
    end
  end

  describe "GET /api/announcements 的分页" do
    setup do
      %{items: for(n <- 1..25, do: announcement_fixture(%{title: "公告#{n}"}))}
    end

    test "默认一页 20 条", %{conn: conn} do
      assert %{"data" => data, "meta" => %{"next_cursor" => cursor}} =
               conn |> get(~p"/api/announcements") |> json_response(200)

      assert length(data) == 20
      assert Rice.Tsid.valid?(cursor)
    end

    test "游标翻到下一页,不重不漏", %{conn: conn, items: items} do
      page1 = conn |> get(~p"/api/announcements") |> json_response(200)
      cursor = page1["meta"]["next_cursor"]

      page2 =
        build_conn() |> get(~p"/api/announcements?before=#{cursor}") |> json_response(200)

      assert length(page2["data"]) == 5
      assert page2["meta"]["next_cursor"] == nil

      seen = Enum.map(page1["data"] ++ page2["data"], & &1["id"])
      assert length(Enum.uniq(seen)) == 25
      assert MapSet.new(seen) == MapSet.new(Enum.map(items, & &1.id))
    end

    test "limit 可以指定", %{conn: conn} do
      assert %{"data" => data} =
               conn |> get(~p"/api/announcements?limit=5") |> json_response(200)

      assert length(data) == 5
    end

    test "limit 超上限时封顶,不会被要求返回全表", %{conn: conn} do
      for n <- 26..120, do: announcement_fixture(%{title: "多#{n}"})

      assert %{"data" => data} =
               conn |> get(~p"/api/announcements?limit=99999") |> json_response(200)

      assert length(data) == Rice.Pagination.max_limit()
    end

    test "limit 是垃圾值时退回默认,不是 500", %{conn: conn} do
      for bad <- ["abc", "-1", "0", "", "1.5"] do
        assert %{"data" => data} =
                 conn |> get(~p"/api/announcements?limit=#{bad}") |> json_response(200)

        assert length(data) == Rice.Pagination.default_limit(),
               "limit=#{inspect(bad)} 没有退回默认值"
      end
    end

    test "游标是垃圾值时退回第一页,不是 500", %{conn: conn} do
      for bad <- ["abc", "../../etc", "222222222222"] do
        assert %{"data" => data} =
                 conn |> get(~p"/api/announcements?before=#{bad}") |> json_response(200)

        assert length(data) == 20
      end
    end
  end

  describe "GET /api/announcements/:id" do
    test "命中时返回详情", %{conn: conn} do
      announcement = announcement_fixture(%{title: "社区指南"})

      assert %{"data" => %{"id" => id, "title" => "社区指南"}} =
               conn |> get(~p"/api/announcements/#{announcement.id}") |> json_response(200)

      assert id == announcement.id
    end

    test "不存在的 id 返回 404", %{conn: conn} do
      ghost = Rice.Tsid.generate()

      assert %{"errors" => %{"detail" => _}} =
               conn |> get(~p"/api/announcements/#{ghost}") |> json_response(404)
    end

    test "格式非法的 id 返回 404 而不是 500", %{conn: conn} do
      for bad <- ["abc", "222222222222", "../../etc/passwd", "222222222222!"] do
        assert conn |> get(~p"/api/announcements/#{bad}") |> json_response(404)
      end
    end
  end
end

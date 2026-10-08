defmodule RiceWeb.Api.AppControllerTest do
  use RiceWeb.ConnCase, async: true

  describe "GET /api/apps" do
    test "空库返回空数组,不是 null", %{conn: conn} do
      assert %{"data" => []} = conn |> get(~p"/api/apps") |> json_response(200)
    end

    test "按 position 升序", %{conn: conn} do
      app_fixture(%{name: "第三", position: 3})
      app_fixture(%{name: "第一", position: 1})
      app_fixture(%{name: "第二", position: 2})

      assert %{"data" => data} = conn |> get(~p"/api/apps") |> json_response(200)
      assert Enum.map(data, & &1["name"]) == ["第一", "第二", "第三"]
    end

    test "position 相同时按 id 排,顺序稳定", %{conn: conn} do
      for n <- 1..5, do: app_fixture(%{name: "app#{n}", position: 0})

      first = conn |> get(~p"/api/apps") |> json_response(200)
      second = build_conn() |> get(~p"/api/apps") |> json_response(200)

      assert first == second
      assert Enum.map(first["data"], & &1["name"]) == ~w(app1 app2 app3 app4 app5)
    end

    test "响应字段齐全", %{conn: conn} do
      logo = attachment_fixture(%{filename: "logo.png"})
      app_fixture(%{name: "甲", description: "描述", url: "https://a.test", logo_id: logo.id})

      assert %{"data" => [item]} = conn |> get(~p"/api/apps") |> json_response(200)

      assert %{
               "id" => id,
               "name" => "甲",
               "description" => "描述",
               "url" => "https://a.test",
               "position" => 0,
               "logo" => %{"id" => logo_id, "filename" => "logo.png", "kind" => "image"}
             } = item

      assert Rice.Tsid.valid?(id)
      assert logo_id == logo.id
    end

    test "没有 logo 时是 null,不是空对象", %{conn: conn} do
      app_fixture(%{name: "无图"})
      assert %{"data" => [%{"logo" => nil}]} = conn |> get(~p"/api/apps") |> json_response(200)
    end
  end
end

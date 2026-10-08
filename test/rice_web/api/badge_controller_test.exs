defmodule RiceWeb.Api.BadgeControllerTest do
  use RiceWeb.ConnCase, async: true

  import Rice.DataCase, only: [errors_on: 1]

  describe "GET /api/users/:user_id/badges" do
    test "按 handle 看别人的勋章墙 —— 返回全集,他没获得的是 null", %{conn: conn} do
      owner = user_fixture(%{handle: "TaDe.web5.xjdao.test"})
      image = attachment_fixture(%{filename: "medal.png"})
      got = badge_fixture(%{name: "早期贡献者", image_id: image.id})
      _missing = badge_fixture(%{name: "他没有的"})
      {:ok, _} = Rice.Community.award_badge(got, owner)

      assert %{"data" => data} =
               conn |> get(~p"/api/users/tade.web5.xjdao.test/badges") |> json_response(200)

      by_name = Map.new(data, &{&1["name"], &1})
      assert by_name["早期贡献者"]["awarded_at"]
      assert by_name["早期贡献者"]["image"]["filename"] == "medal.png"
      assert by_name["他没有的"]["awarded_at"] == nil
    end

    # 这是 core 迁移时真丢过的一条语义:勋章墙曾经变成"永远显示当前登录用户的勋章"
    test "看别人的墙不会串成自己的", %{conn: conn} do
      {me, token} = user_with_token()
      other = user_fixture()
      mine = badge_fixture(%{name: "我的"})
      theirs = badge_fixture(%{name: "他的"})
      {:ok, _} = Rice.Community.award_badge(mine, me)
      {:ok, _} = Rice.Community.award_badge(theirs, other)

      assert %{"data" => data} =
               conn
               |> authed(token)
               |> get(~p"/api/users/#{other.did}/badges")
               |> json_response(200)

      by_name = Map.new(data, &{&1["name"], &1["awarded_at"]})
      assert by_name["他的"]
      assert by_name["我的"] == nil
    end

    test "user_id 用 rice id 也行", %{conn: conn} do
      owner = user_fixture()
      badge = badge_fixture(%{name: "按 id 查"})
      {:ok, _} = Rice.Community.award_badge(badge, owner)

      assert %{"data" => [one]} =
               conn |> get(~p"/api/users/#{owner.id}/badges") |> json_response(200)

      assert one["awarded_at"]
    end

    test "me 是当前登录用户", %{conn: conn} do
      {me, token} = user_with_token()
      badge = badge_fixture(%{name: "我的"})
      {:ok, _} = Rice.Community.award_badge(badge, me)

      assert %{"data" => [one]} =
               conn |> authed(token) |> get(~p"/api/users/me/badges") |> json_response(200)

      assert one["awarded_at"]
    end

    test "未登录访问 me 是 401", %{conn: conn} do
      assert conn |> get(~p"/api/users/me/badges") |> json_response(401)
    end

    test "查不到的人 404", %{conn: conn} do
      assert conn |> get(~p"/api/users/nobody.test/badges") |> json_response(404)
    end

    # 认了邮箱/手机号就等于送一个"这个邮箱注册过没有"的探测器
    test "不能用邮箱或手机号查", %{conn: conn} do
      user_fixture(%{email: "secret@example.com", phone: "13800009999", phone_region: "86"})

      assert conn |> get(~p"/api/users/secret@example.com/badges") |> json_response(404)
      assert build_conn() |> get(~p"/api/users/13800009999/badges") |> json_response(404)
    end

    test "同一枚勋章不能重复发给同一个人" do
      user = user_fixture()
      badge = badge_fixture()

      assert {:ok, _} = Rice.Community.award_badge(badge, user)
      assert {:error, changeset} = Rice.Community.award_badge(badge, user)
      assert "该用户已获得这枚勋章" in errors_on(changeset).badge_id
    end
  end
end

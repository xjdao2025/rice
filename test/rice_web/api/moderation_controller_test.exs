defmodule RiceWeb.Api.ModerationControllerTest do
  # 改的是全局配置(:moderation_http / Rice.Moderation),不能并发
  use RiceWeb.ConnCase, async: false

  setup do
    previous = Application.get_env(:rice, Rice.Moderation)
    Application.put_env(:rice, :moderation_http, Rice.FakeGreen)

    Application.put_env(:rice, Rice.Moderation,
      access_key_id: "id",
      access_key_secret: "secret",
      endpoint: "https://green.test"
    )

    on_exit(fn ->
      Application.delete_env(:rice, :moderation_http)
      Application.put_env(:rice, Rice.Moderation, previous || [])
    end)

    {user, token} = user_with_token()
    %{user: user, token: token}
  end

  defp check(token, body),
    do: build_conn() |> authed(token) |> post(~p"/api/moderation/check", body)

  test "正常内容和带链接的帖子放行,涉政拦下且不说命中了什么", %{token: token} do
    assert check(token, %{text: "今天去插秧"}) |> json_response(200) == %{
             "data" => %{"allowed" => true, "place" => nil}
           }

    assert check(token, %{text: "村里新修了水渠 https://www.gov.cn/"}) |> json_response(200)

    blocked = check(token, %{text: "转发领导人讲话"}) |> json_response(422)
    assert blocked["errors"]["detail"] =~ "违规"
    refute inspect(blocked) =~ "政治"

    assert_received {:green, "https://green.test",
                     %{
                       "Action" => "TextModerationPlus",
                       "Service" => "comment_detection_pro",
                       "Signature" => _
                     }}
  end

  test "图片按 PDS 公开地址交给阿里云取,有一张违规就拦", %{user: user, token: token} do
    assert check(token, %{text: "", images: ["bafygood"]}) |> json_response(200)
    assert_received {:green, _, %{"Action" => "ImageModeration", "ServiceParameters" => params}}
    url = Jason.decode!(params)["imageUrl"]
    assert url =~ "/xrpc/com.atproto.sync.getBlob?"
    assert url =~ "cid=bafygood" and url =~ URI.encode_www_form(user.did)

    assert check(token, %{text: "插秧", images: ["bafygood", "bafybad"]}) |> json_response(422)
    assert check(token, %{images: List.duplicate("bafygood", 10)}) |> json_response(422)
  end

  test "通过的内容记下指纹,没通过的不记", %{user: user, token: token} do
    assert check(token, %{text: " 去插秧 ", images: ["bafygood"]}) |> json_response(200)
    assert check(token, %{text: "转发领导人讲话"}) |> json_response(422)

    # 指纹只认作者、去掉首尾空白的正文和图片 CID
    assert Rice.Moderation.passed?(user.did, "去插秧", ["bafygood"])
    refute Rice.Moderation.passed?(user.did, "去插秧", [])
    refute Rice.Moderation.passed?("did:plc:other", "去插秧", ["bafygood"])
    refute Rice.Moderation.passed?(user.did, "转发领导人讲话", [])
  end

  test "阿里云出错时拒绝发布;没登录不能用", %{token: token} do
    assert check(token, %{text: "宕机"}) |> json_response(503)
    assert build_conn() |> post(~p"/api/moderation/check", %{text: "x"}) |> json_response(401)
  end

  # 发布地点写在帖子记录里,而 rice 只有这一次请求能拿到客户端 IP
  test "带上发布者 IP 就回一个地点", %{token: token} do
    path =
      Path.join(System.tmp_dir!(), "moderation-xdb-#{System.unique_integer([:positive])}.xdb")

    Rice.XdbFixture.write(path, :v4, {{1, 2, 0, 0}, {1, 2, 255, 255}}, "中国|广东省|广州市|电信|CN")
    Application.put_env(:rice, Rice.Geo, v4: path)

    on_exit(fn ->
      Application.delete_env(:rice, Rice.Geo)
      File.rm(path)
    end)

    assert check(token, %{text: "今天去插秧", ip: "1.2.3.4"}) |> json_response(200) == %{
             "data" => %{"allowed" => true, "place" => "广东省·广州市"}
           }

    # 查不到的 IP 还是给 null,发布不受影响
    assert %{"data" => %{"place" => nil}} =
             check(token, %{text: "今天去插秧", ip: "8.8.8.8"}) |> json_response(200)
  end

  test "没配密钥时不审" do
    Application.put_env(:rice, Rice.Moderation, [])
    assert Rice.Moderation.check("转发领导人讲话") == :ok
    refute_received {:green, _, _}
  end
end

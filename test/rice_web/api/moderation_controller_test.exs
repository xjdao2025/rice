defmodule RiceWeb.Api.ModerationControllerTest do
  # 改的是全局配置(:moderation_http / Rice.Moderation),不能并发
  use RiceWeb.ConnCase, async: false

  defmodule FakeGreen do
    @moduledoc false
    # 阿里云内容安全的返回体,按真实接口录的形状;请求逐条记下来给断言用
    def post(url, form) do
      send(self(), {:green, url, form})
      params = Jason.decode!(form["ServiceParameters"])

      case {form["Action"], params} do
        {_, %{"content" => "宕机"}} ->
          {:error, :timeout}

        {"TextModerationPlus", %{"content" => content}} ->
          {:ok, %{"Code" => 200, "Data" => text_result(content)}}

        {"ImageModeration", %{"imageUrl" => url}} ->
          {:ok,
           %{
             "Code" => 200,
             "Data" =>
               if(url =~ "bad",
                 do: %{
                   "RiskLevel" => "high",
                   "Result" => [%{"Label" => "pornographic_adult", "Description" => "疑似色情"}]
                 },
                 else: %{"RiskLevel" => "none", "Result" => [%{"Label" => "nonLabel"}]}
               )
           }}
      end
    end

    defp text_result(content) do
      cond do
        content =~ "领导人" ->
          %{
            "RiskLevel" => "high",
            "Result" => [%{"Label" => "political_figure", "Description" => "疑似政治人物"}]
          }

        # 带链接的正常帖子:这个服务一律标成引流,要放行
        content =~ "https://" ->
          %{
            "RiskLevel" => "high",
            "Result" => [%{"Label" => "pt_to_contact", "Description" => "疑似引流广告号"}]
          }

        true ->
          %{"RiskLevel" => "none", "Result" => [%{"Label" => "nonLabel"}]}
      end
    end
  end

  setup do
    previous = Application.get_env(:rice, Rice.Moderation)
    Application.put_env(:rice, :moderation_http, FakeGreen)

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
             "data" => %{"allowed" => true}
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

  test "阿里云出错时拒绝发布;没登录不能用", %{token: token} do
    assert check(token, %{text: "宕机"}) |> json_response(503)
    assert build_conn() |> post(~p"/api/moderation/check", %{text: "x"}) |> json_response(401)
  end

  test "没配密钥时不审" do
    Application.put_env(:rice, Rice.Moderation, [])
    assert Rice.Moderation.check("转发领导人讲话") == :ok
    refute_received {:green, _, _}
  end
end

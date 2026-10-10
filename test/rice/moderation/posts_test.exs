defmodule Rice.Moderation.PostsTest do
  # 改的是全局配置(:moderation_http / Rice.Moderation / :post_client),不能并发
  use Rice.DataCase, async: false
  import Mox

  alias Rice.Moderation.{PostCheck, Posts}

  setup :verify_on_exit!

  setup do
    previous = Application.get_env(:rice, Rice.Moderation)
    Application.put_env(:rice, :moderation_http, Rice.FakeGreen)
    Application.put_env(:rice, :post_client, Rice.PostClientMock)

    Application.put_env(:rice, Rice.Moderation,
      access_key_id: "id",
      access_key_secret: "secret",
      endpoint: "https://green.test"
    )

    on_exit(fn ->
      Application.delete_env(:rice, :moderation_http)
      Application.delete_env(:rice, :post_client)
      Application.put_env(:rice, Rice.Moderation, previous || [])
    end)
  end

  defp post(rkey, text, embed \\ nil) do
    record = %{"text" => text}

    %{
      "uri" => "at://did:plc:alice/app.bsky.feed.post/#{rkey}",
      "cid" => "cid-#{rkey}",
      "author" => %{"did" => "did:plc:alice"},
      "record" => if(embed, do: Map.put(record, "embed", embed), else: record)
    }
  end

  defp page(posts, cursor \\ nil),
    do: {:ok, %{"posts" => Enum.map(posts, &%{"post" => &1}), "cursor" => cursor}}

  test "没审过的新帖交给阿里云,违规的打 !hide,每个版本只审一次" do
    gallery = %{
      "$type" => "app.bsky.embed.gallery",
      "items" => [%{"image" => %{"ref" => %{"$link" => "bad"}}}]
    }

    posts = [post("1", "去插秧"), post("2", "转发领导人讲话"), post("3", "", gallery)]

    expect(Rice.PostClientMock, :query, 2, fn query ->
      assert query[:takenDown] == "false" and query[:since]
      page(posts)
    end)

    expect(Rice.PostClientMock, :label, 2, fn %{"uri" => uri, "cid" => cid}, "!hide", comment ->
      send(self(), {:hidden, uri, cid, comment})
      :ok
    end)

    assert Posts.scan() == :ok
    assert_received {:hidden, "at://did:plc:alice/app.bsky.feed.post/2", "cid-2", comment}
    assert comment =~ "疑似政治人物"
    assert_received {:hidden, "at://did:plc:alice/app.bsky.feed.post/3", "cid-3", _}
    assert_received {:green, _, %{"Action" => "ImageModeration", "ServiceParameters" => image}}
    assert image =~ "getBlob" and image =~ "did%3Aplc%3Aalice"

    assert Repo.all(from c in PostCheck, order_by: c.uri, select: {c.cid, c.verdict}) ==
             [{"cid-1", "ok"}, {"cid-2", "hidden"}, {"cid-3", "hidden"}]

    # 第二轮全是审过的:不再找阿里云,也不翻下一页
    flush_green()
    assert Posts.scan() == :ok
    refute_received {:green, _, _}
  end

  test "一页里还有没审的就翻下一页;阿里云出错就停,下一轮接着审" do
    expect(Rice.PostClientMock, :query, fn query ->
      refute query[:cursor]
      page([post("1", "去插秧")], "next")
    end)

    expect(Rice.PostClientMock, :query, fn query ->
      assert query[:cursor] == "next"
      page([post("2", "宕机"), post("3", "去插秧")])
    end)

    assert Posts.scan() == {:error, :unavailable}
    assert Repo.all(from c in PostCheck, select: c.cid) == ["cid-1"]
  end

  test "没配密钥时不审,也不记" do
    Application.put_env(:rice, Rice.Moderation, [])
    assert Posts.scan() == :ok
    assert Repo.all(PostCheck) == []
  end

  defp flush_green do
    receive do
      {:green, _, _} -> flush_green()
    after
      0 -> :ok
    end
  end
end

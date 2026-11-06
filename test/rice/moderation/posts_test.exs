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

    political = %{
      "$type" => "app.bsky.embed.gallery",
      "items" => [%{"image" => %{"ref" => %{"$link" => "political"}}}]
    }

    posts = [
      post("1", "去插秧"),
      post("2", "转发领导人讲话"),
      post("3", "", gallery),
      post("4", "", political)
    ]

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
    assert_received {:hidden, "at://did:plc:alice/app.bsky.feed.post/4", "cid-4", image_comment}
    assert image_comment =~ "疑似政治人物"
    refute_received {:hidden, "at://did:plc:alice/app.bsky.feed.post/3", _, _}
    assert_received {:green, _, %{"Action" => "ImageModeration", "ServiceParameters" => image}}
    assert image =~ "getBlob" and image =~ "did%3Aplc%3Aalice"

    assert Repo.all(from c in PostCheck, order_by: c.uri, select: {c.cid, c.verdict}) ==
             [{"cid-1", "ok"}, {"cid-2", "hidden"}, {"cid-3", "ok"}, {"cid-4", "hidden"}]

    # 第二轮全是审过的:不再找阿里云；有游标时仍应继续翻页。
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
    state = Repo.get!(Rice.Moderation.ScanState, "posts")
    assert state.cursor == "next"

    expect(Rice.PostClientMock, :query, fn query ->
      assert query[:cursor] == "next"
      assert query[:until] == DateTime.to_iso8601(state.until)
      page([post("2", "恢复后可审核"), post("3", "去插秧")])
    end)

    assert Posts.scan(DateTime.add(DateTime.utc_now(), 3, :day)) == :ok
    assert Repo.aggregate(PostCheck, :count) == 3
    assert Repo.get!(Rice.Moderation.ScanState, "posts").watermark == state.until
  end

  test "发布前审过的内容不再找阿里云,改了内容的照审;过期指纹清掉" do
    Rice.Moderation.remember_pass("did:plc:alice", "原来的话", [])

    Repo.update_all(Rice.Moderation.Pass,
      set: [inserted_at: DateTime.add(DateTime.utc_now(), -3, :day)]
    )

    Rice.Moderation.remember_pass("did:plc:alice", "去插秧", [])

    expect(Rice.PostClientMock, :query, fn _ -> page([post("1", "去插秧"), post("2", "原来的话")]) end)

    assert Posts.scan() == :ok
    assert_received {:green, _, %{"ServiceParameters" => params}}
    assert params =~ "原来的话"
    refute_received {:green, _, _}
    assert Repo.aggregate(PostCheck, :count) == 2
    assert Repo.aggregate(Rice.Moderation.Pass, :count) == 1
  end

  test "整页都审过也继续游标，不能跳过后面的失败积压" do
    seen = post("seen", "已审核")
    Repo.insert!(%PostCheck{uri: seen["uri"], cid: seen["cid"], verdict: "ok", reasons: []})

    expect(Rice.PostClientMock, :query, fn query ->
      assert query[:include_replies]
      page([seen], "backlog")
    end)

    expect(Rice.PostClientMock, :query, fn query ->
      assert query[:cursor] == "backlog"
      page([post("missed", "积压内容")])
    end)

    assert Posts.scan() == :ok
    assert Repo.aggregate(PostCheck, :count) == 2
  end

  test "十页预算后保存游标，停机数天仍接续原窗口" do
    expect(Rice.PostClientMock, :query, 10, fn query ->
      n =
        if query[:cursor],
          do: query[:cursor] |> String.replace_prefix("page-", "") |> String.to_integer(),
          else: 0

      page([post("budget-#{n}", "普通内容")], "page-#{n + 1}")
    end)

    assert Posts.scan() == :ok
    state = Repo.get!(Rice.Moderation.ScanState, "posts")
    assert state.cursor == "page-10"

    expect(Rice.PostClientMock, :query, fn query ->
      assert query[:cursor] == "page-10"
      assert query[:since] == DateTime.to_iso8601(state.since)
      assert query[:until] == DateTime.to_iso8601(state.until)
      page([post("budget-10", "最后一页")])
    end)

    assert Posts.scan(DateTime.add(DateTime.utc_now(), 3, :day)) == :ok
    completed = Repo.get!(Rice.Moderation.ScanState, "posts")
    assert completed.watermark == state.until
    assert is_nil(completed.cursor) and is_nil(completed.until)
    assert Repo.aggregate(PostCheck, :count) == 11
  end

  test "评论包含在补审中，违规回复同样打隐藏标签" do
    reply =
      post("reply", "转发领导人讲话")
      |> put_in(["record", "reply"], %{"parent" => %{"uri" => "at://parent"}})

    expect(Rice.PostClientMock, :query, fn query ->
      assert query[:include_replies]
      page([reply])
    end)

    expect(Rice.PostClientMock, :label, fn %{"uri" => uri}, "!hide", _ ->
      assert uri == reply["uri"]
      :ok
    end)

    assert Posts.scan() == :ok
    assert Repo.get_by!(PostCheck, uri: reply["uri"]).verdict == "hidden"
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

defmodule Rice.Moderation.Posts do
  @moduledoc """
  事后补审。发帖前的审核在 rice-front 里调 `/api/moderation/check`,但帖子是直接写进
  用户自己的 PDS 的,绕过前端也能发。这里每 5 分钟从审核服务(aerox labeler 的 `queryPosts`)
  取最近一天的新帖,没审过的交给 `Rice.Moderation`;不通过就让审核服务打 `!hide` 标签,
  rice-front 见到这个标签就不显示,后台可以撤掉标签恢复。

  从前端正常发的帖子,发布前已经审过、留了指纹(`Rice.Moderation.remember_pass/3`),
  内容一模一样就直接记为通过,不再花一次阿里云的钱。

  `queryPosts` 只给顶层帖,评论只有发布前那一道。
  """
  import Ecto.Query

  alias Rice.Moderation.{Pass, PostCheck}
  alias Rice.Repo

  @pages 10

  @doc "审一轮。阿里云不可用时停下,下一轮从没审过的接着来。"
  @spec scan(DateTime.t()) :: :ok | {:error, term()}
  def scan(now \\ DateTime.utc_now()) do
    if Rice.Moderation.enabled?() do
      # 指纹只用来对上一天之内的新帖,留两天足够
      Repo.delete_all(from p in Pass, where: p.inserted_at < ^DateTime.add(now, -2, :day))
      since = now |> DateTime.add(-1, :day) |> DateTime.to_iso8601()
      scan_page([since: since, takenDown: "false", limit: 100], @pages)
    else
      :ok
    end
  end

  defp scan_page(_query, 0), do: :ok

  defp scan_page(query, pages) do
    with {:ok, body} <- Rice.Admin.Posts.impl().query(query) do
      posts = for %{"post" => post} <- body["posts"] || [], do: post
      fresh = unchecked(posts)

      with :ok <- Enum.reduce_while(fresh, :ok, &review/2) do
        # 一页全是审过的,再往后(更早)的也都审过了
        if fresh != [] and body["cursor"],
          do: scan_page(Keyword.put(query, :cursor, body["cursor"]), pages - 1),
          else: :ok
      end
    end
  end

  defp unchecked(posts) do
    uris = Enum.map(posts, & &1["uri"])
    seen = Repo.all(from c in PostCheck, where: c.uri in ^uris, select: {c.uri, c.cid})
    Enum.reject(posts, &({&1["uri"], &1["cid"]} in seen))
  end

  defp review(%{"uri" => uri, "cid" => cid} = post, :ok) do
    did = post["author"]["did"]
    text = post["record"]["text"]
    cids = image_cids(post["record"])

    verdict =
      if Rice.Moderation.passed?(did, text, cids),
        do: :ok,
        else: Rice.Moderation.check(text, Enum.map(cids, &Rice.Moderation.blob_url(did, &1)))

    case verdict do
      :ok ->
        {:cont, record(uri, cid, "ok", [])}

      {:blocked, reasons} ->
        case Rice.Admin.Posts.hide(uri, cid, "内容审核未通过：" <> Enum.join(reasons, "、")) do
          :ok -> {:cont, record(uri, cid, "hidden", reasons)}
          error -> {:halt, error}
        end

      {:error, _} = error ->
        {:halt, error}
    end
  end

  defp record(uri, cid, verdict, reasons) do
    Repo.insert!(%PostCheck{uri: uri, cid: cid, verdict: verdict, reasons: reasons},
      on_conflict: :nothing,
      conflict_target: [:uri, :cid]
    )

    :ok
  end

  # 图片在 embed 里:images / gallery,或者 recordWithMedia 里套着的那一层
  defp image_cids(%{"embed" => embed}), do: embed_cids(embed)
  defp image_cids(_record), do: []

  defp embed_cids(%{"media" => media}), do: embed_cids(media)

  defp embed_cids(embed) when is_map(embed) do
    for item <- embed["images"] || embed["items"] || [],
        cid = get_in(item, ["image", "ref", "$link"]),
        is_binary(cid),
        do: cid
  end

  defp embed_cids(_embed), do: []
end

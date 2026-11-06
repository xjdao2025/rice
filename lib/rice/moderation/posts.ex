defmodule Rice.Moderation.Posts do
  @moduledoc """
  事后补审。发帖前的审核在 rice-front 里调 `/api/moderation/check`,但帖子是直接写进
  用户自己的 PDS 的,绕过前端也能发。这里每 5 分钟读取 AppView 的公开帖子和回复,
  用持久化窗口/游标接续积压,没审过的版本交给 `Rice.Moderation`;不通过就打 `!hide` 标签,
  rice-front 见到这个标签就不显示,后台可以撤掉标签恢复。

  从前端正常发的帖子,发布前已经审过、留了指纹(`Rice.Moderation.remember_pass/3`),
  内容一模一样就直接记为通过,不再花一次阿里云的钱。

  管理端的 `queryPosts` 仍只给顶层帖；补审走包含回复的 searchPosts。
  首次从最近一天起步,此后停机/失败不会让未完成窗口随时间过期。
  """
  import Ecto.Query

  alias Rice.Moderation.{Pass, PostCheck, ScanState}
  alias Rice.Repo

  @pages 10

  @doc "审一轮。阿里云不可用时停下,下一轮从没审过的接着来。"
  @spec scan(DateTime.t()) :: :ok | {:error, term()}
  def scan(now \\ DateTime.utc_now()) do
    if Rice.Moderation.enabled?() do
      # 指纹只用来对上一天之内的新帖,留两天足够
      Repo.delete_all(from p in Pass, where: p.inserted_at < ^DateTime.add(now, -2, :day))

      {:ok, result} =
        Repo.transaction(fn ->
          # Multiple schedulers must not advance the same checkpoint concurrently.
          %{rows: [[locked?]]} =
            Repo.query!("SELECT pg_try_advisory_xact_lock(hashtextextended('rice:post-scan', 0))")

          if locked? do
            state = Repo.get(ScanState, "posts") || Repo.insert!(%ScanState{id: "posts"})

            state =
              if state.until do
                state
              else
                since = DateTime.add(state.watermark || now, -1, :day)
                Repo.update!(Ecto.Changeset.change(state, since: since, until: now, cursor: nil))
              end

            scan_page(state, @pages)
          else
            :ok
          end
        end)

      result
    else
      :ok
    end
  end

  defp scan_page(_state, 0), do: :ok

  defp scan_page(state, pages) do
    query = [
      since: DateTime.to_iso8601(state.since),
      until: DateTime.to_iso8601(state.until),
      takenDown: "false",
      include_replies: true,
      limit: 100
    ]

    query = if state.cursor, do: Keyword.put(query, :cursor, state.cursor), else: query

    with {:ok, body} <- Rice.Admin.Posts.impl().query(query),
         :ok <-
           Enum.reduce_while(
             unchecked(for %{"post" => post} <- body["posts"] || [], do: post),
             :ok,
             &review/2
           ) do
      cursor = body["cursor"]

      cond do
        cursor in [nil, ""] ->
          Repo.update!(
            Ecto.Changeset.change(state,
              watermark: state.until,
              since: nil,
              until: nil,
              cursor: nil
            )
          )

          :ok

        not is_binary(cursor) or cursor == state.cursor ->
          {:error, :invalid_cursor}

        true ->
          state = Repo.update!(Ecto.Changeset.change(state, cursor: cursor))
          scan_page(state, pages - 1)
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

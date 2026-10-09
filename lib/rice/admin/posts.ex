defmodule Rice.Admin.Posts do
  @moduledoc """
  贴文管理。贴文不在 rice 的库里 —— 它们在 AT Protocol 上,由 aerox 的审核服务
  (labeler)管:下架 / 恢复是 `aerox.moderation.emitEvent`,后台列表是
  `aerox.moderation.queryPosts`(带每条的下架状态)。

  rice 只做一层薄代理,存在的意义是**把管理凭据留在服务端**:
  否则前端就得自己持有审核服务的 admin 密码。
  """

  @callback emit(action :: String.t(), subject :: map()) :: :ok | {:error, term()}
  @callback query(params :: keyword()) :: {:ok, map()} | {:error, term()}

  @doc "下架一条贴文。cid 和 uri 一起定位到具体版本(`com.atproto.repo.strongRef`)。"
  @spec take_down(term(), term()) :: :ok | {:error, :invalid_uri | term()}
  def take_down(uri, cid), do: emit("takedown", uri, cid)

  @spec restore(term(), term()) :: :ok | {:error, :invalid_uri | term()}
  def restore(uri, cid), do: emit("restore", uri, cid)

  defp emit(action, "at://" <> _ = uri, cid) when is_binary(cid) and cid != "",
    do:
      impl().emit(action, %{"$type" => "com.atproto.repo.strongRef", "uri" => uri, "cid" => cid})

  defp emit(_, _, _), do: {:error, :invalid_uri}

  @doc """
  后台贴文列表,页码式:`q`(正文)、`author`(handle 或 DID)、`tag`、`since` / `until`、
  `taken_down`、`page`、`per_page`。每条是 AppView 的 postView 加 `is_banned`。
  """
  @spec list(map()) :: {:ok, %{posts: [map()], total: non_neg_integer()}} | {:error, term()}
  def list(params) do
    per_page = params |> Map.get("per_page", "10") |> to_int(10) |> min(100) |> max(1)
    page = params |> Map.get("page", "1") |> to_int(1) |> max(1)

    query =
      [
        q: params["q"],
        author: params["author"],
        tag: params["tag"] && String.trim_leading(params["tag"], "#"),
        since: params["since"],
        until: params["until"],
        takenDown: params["taken_down"],
        limit: per_page,
        cursor: Integer.to_string((page - 1) * per_page)
      ]
      |> Enum.reject(fn {_, v} -> v in [nil, ""] end)

    with {:ok, body} <- impl().query(query) do
      posts = for p <- body["posts"], do: Map.put(p["post"], "is_banned", p["takenDown"])
      {:ok, %{posts: posts, total: body["hitsTotal"] || 0}}
    end
  end

  defp to_int(value, _default) when is_integer(value), do: value

  defp to_int(value, default) do
    case Integer.parse(to_string(value)) do
      {n, ""} -> n
      _ -> default
    end
  end

  @spec impl() :: module()
  def impl, do: Application.get_env(:rice, :post_client, __MODULE__.Http)

  defmodule Http do
    @moduledoc false
    @behaviour Rice.Admin.Posts

    require Logger

    @impl true
    def emit(action, subject) do
      with {:ok, _} <-
             request(:post, "aerox.moderation.emitEvent",
               json: %{"action" => action, "subject" => subject, "createdBy" => "rice"}
             ),
           do: :ok
    end

    @impl true
    def query(params), do: request(:get, "aerox.moderation.queryPosts", params: params)

    defp request(method, nsid, opts) do
      cfg = Application.get_env(:rice, :labeler, [])

      if cfg[:url] in [nil, ""] or cfg[:admin_password] in [nil, ""] do
        {:error, :labeler_not_configured}
      else
        Req.request(
          [
            method: method,
            url: cfg[:url] <> "/xrpc/" <> nsid,
            auth: {:basic, "admin:" <> cfg[:admin_password]},
            receive_timeout: 15_000,
            retry: false
          ] ++ opts
        )
        |> case do
          {:ok, %{status: status, body: body}} when status in 200..299 ->
            {:ok, body}

          {:ok, %{status: status, body: body}} ->
            Logger.error("[审核服务] #{nsid} #{status}: #{inspect(body)}")
            {:error, {:labeler, status}}

          {:error, reason} ->
            {:error, {:transport, reason}}
        end
      end
    end
  end
end

defmodule Rice.Admin.Posts do
  @moduledoc """
  贴文下架。贴文本身不在 rice 的库里 —— 它属于 post 服务(`/api/posts/*`),
  下架的做法是给它打一个 `blacklist` 标签。

  rice 只做一层薄代理,存在的意义是**把管理凭据留在服务端**:
  否则前端就得自己持有 post 服务的 admin token。
  """
  require Logger

  @callback label(uri :: String.t(), labels :: [String.t()]) :: :ok | {:error, term()}

  @spec take_down(term()) :: :ok | {:error, :invalid_uri | term()}
  def take_down(uri) when is_binary(uri) and uri != "", do: impl().label(uri, ["blacklist"])
  def take_down(_), do: {:error, :invalid_uri}

  @spec restore(term()) :: :ok | {:error, :invalid_uri | term()}
  def restore(uri) when is_binary(uri) and uri != "", do: impl().label(uri, [])
  def restore(_), do: {:error, :invalid_uri}

  @spec impl() :: module()
  def impl, do: Application.get_env(:rice, :post_client, __MODULE__.Http)

  defmodule Http do
    @moduledoc false
    @behaviour Rice.Admin.Posts

    require Logger

    @impl true
    def label(uri, labels) do
      cfg = Application.get_env(:rice, :post_service, [])

      cond do
        cfg[:base_url] in [nil, ""] ->
          {:error, :post_service_not_configured}

        cfg[:admin_token] in [nil, ""] ->
          {:error, :post_service_not_configured}

        true ->
          post(cfg, uri, labels)
      end
    end

    defp post(cfg, uri, labels) do
      url = cfg[:base_url] <> "/api/posts/label"

      case Req.post(url,
             json: %{"uri" => uri, "labels" => labels},
             headers: [{"authorization", cfg[:admin_token]}],
             receive_timeout: 15_000
           ) do
        {:ok, %{status: status}} when status in 200..299 ->
          :ok

        {:ok, %{status: status, body: body}} ->
          Logger.error("[贴文下架] #{status}: #{inspect(body)}")
          {:error, {:post_service, status}}

        {:error, reason} ->
          {:error, {:transport, reason}}
      end
    end
  end
end

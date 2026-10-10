defmodule Rice.Moderation do
  @moduledoc """
  内容审核:阿里云内容安全(Green 2022-03-02),和 core 当年用的是同一套接口。

    * 文本:`TextModerationPlus` + `comment_detection_pro`
    * 图片:`ImageModeration` + `baselineCheck`,阿里云自己从 PDS 公开地址取图

  中风险及以上都拦,唯一放行的是「站外引流 / 联系方式」两类 —— 这个服务把带任何链接的
  帖子(连 gov.cn)都标成引流,拦它等于不让发链接。链接本身有问题(比如反动网站)会落到
  涉政等标签上,照样拦下。

  没配密钥时不审(开发、测试);配了但阿里云出错时返回 `:unavailable`,由调用方拒绝发布
  —— 和 core 一样,宁可发不出去也不放过。
  """
  import Ecto.Query, only: [from: 2]
  require Logger

  @version "2022-03-02"
  @allowed_labels ~w(nonLabel pt_to_sites pt_to_contact)
  # TextModerationPlus 单次最多 2000 字
  @chunk 2000

  @type verdict :: :ok | {:blocked, [String.t()]} | {:error, :unavailable}

  @doc "审一段文字和若干张图片(公开可取的地址)。`{:blocked, 说明}` 里是阿里云给的风险描述。"
  @spec check(String.t() | nil, [String.t()]) :: verdict()
  def check(text, image_urls \\ []) do
    if enabled?() do
      chunks = for chunk <- chunk(text || ""), do: {:text, chunk}
      Enum.reduce_while(chunks ++ Enum.map(image_urls, &{:image, &1}), :ok, &check_one/2)
    else
      :ok
    end
  end

  @doc "图片给阿里云的地址:PDS 公开的 getBlob,阿里云自己来取。"
  @spec blob_url(String.t(), String.t()) :: String.t()
  def blob_url(did, cid) do
    pds = Application.fetch_env!(:rice, :pds)[:public_url]
    "#{pds}/xrpc/com.atproto.sync.getBlob?" <> URI.encode_query(%{did: did, cid: cid})
  end

  @doc """
  记下发布前审核通过的内容(作者、正文、图片 CID)。帖子写进 PDS 后,事后补审见到
  一模一样的内容就不再交给阿里云 —— 正常发的帖子只审一次。
  """
  @spec remember_pass(String.t(), String.t() | nil, [String.t()]) :: :ok
  def remember_pass(did, text, cids) do
    Rice.Repo.insert!(%Rice.Moderation.Pass{fingerprint: fingerprint(did, text, cids)},
      on_conflict: :nothing,
      conflict_target: :fingerprint
    )

    :ok
  end

  @spec passed?(String.t(), String.t() | nil, [String.t()]) :: boolean()
  def passed?(did, text, cids),
    do:
      Rice.Repo.exists?(
        from p in Rice.Moderation.Pass, where: p.fingerprint == ^fingerprint(did, text, cids)
      )

  defp fingerprint(did, text, cids) do
    :crypto.hash(:sha256, Enum.join([did, String.trim(text || "") | cids], "\n"))
    |> Base.encode16(case: :lower)
  end

  @spec enabled?() :: boolean()
  def enabled?, do: config()[:access_key_id] not in [nil, ""]

  defp check_one(item, :ok) do
    case request(item) do
      {:ok, []} -> {:cont, :ok}
      {:ok, reasons} -> {:halt, {:blocked, reasons}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp chunk(text) do
    text
    |> String.trim()
    |> String.graphemes()
    |> Enum.chunk_every(@chunk)
    |> Enum.map(&Enum.join/1)
  end

  defp request({:text, content}),
    do:
      call(
        "TextModerationPlus",
        "comment_detection_pro",
        %{"content" => content},
        &risks(&1, @allowed_labels)
      )

  defp request({:image, url}),
    do: call("ImageModeration", "baselineCheck", %{"imageUrl" => url}, &risks(&1, ["nonLabel"]))

  # 中风险及以上,除放行的标签外命中了什么
  defp risks(%{"RiskLevel" => level} = data, allowed) when level in ~w(medium high),
    do:
      for(
        %{"Label" => label} = r <- data["Result"] || [],
        label not in allowed,
        do: r["Description"] || label
      )

  defp risks(_data, _allowed), do: []

  defp call(action, service, parameters, reasons) do
    cfg = config()

    params = %{
      "Action" => action,
      "Service" => service,
      "ServiceParameters" => Jason.encode!(parameters)
    }

    case http().post(cfg[:endpoint], Rice.Aliyun.signed("POST", params, cfg, @version)) do
      {:ok, %{"Code" => 200, "Data" => data}} when is_map(data) ->
        {:ok, reasons.(data) |> Enum.uniq()}

      other ->
        Logger.error("[阿里云内容安全] #{action}/#{service}: #{inspect(other)}")
        {:error, :unavailable}
    end
  end

  defp config, do: Application.get_env(:rice, __MODULE__, [])
  defp http, do: Application.get_env(:rice, :moderation_http, __MODULE__.Http)

  defmodule Http do
    @moduledoc false
    @callback post(url :: String.t(), form :: map()) :: {:ok, map()} | {:error, term()}
    @behaviour __MODULE__

    @impl true
    def post(url, form) do
      case Req.post(url, form: form, receive_timeout: 10_000, retry: false) do
        {:ok, %{body: body}} when is_map(body) -> {:ok, body}
        {:ok, %{body: body}} -> {:error, {:unparsable, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end

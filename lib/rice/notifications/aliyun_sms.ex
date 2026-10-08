defmodule Rice.Notifications.AliyunSms do
  @moduledoc """
  阿里云短信(Dysmsapi 2017-05-25)。

  没有引入阿里云 SDK —— 这里只用到一个 Action,签名算法是公开且固定的
  (RPC 风格 v1.0,HMAC-SHA1),自己签比拖进一整个 SDK 划算。

  只发验证码模板。模板参数是 `{"code": "123456"}`,和 core 的
  `AliyunSmsCodeDto` 一致 —— 生产上的模板已经按这个字段名审过了,换名字要重新报备。

  配置(见 `config/runtime.exs`):

      config :rice, Rice.Notifications.AliyunSms,
        access_key_id: ..., access_key_secret: ...,
        sign_name: ..., template_code: ...,
        endpoint: "https://dysmsapi.aliyuncs.com"
  """
  @behaviour Rice.Notifications

  require Logger

  @api_version "2017-05-25"

  @impl true
  def send_sms(region, phone, text) do
    case extract_code(text) do
      nil ->
        # 这个通道只有验证码模板。发不出去比发一条内容不对的短信好。
        {:error, {:unsupported_message, text}}

      code ->
        do_send(target(region, phone), code)
    end
  end

  @impl true
  def send_email(_address, _subject, _body),
    do: {:error, :sms_channel_only}

  # 国内号码直接发,国际号码要带 00 + 区号(阿里云的约定)
  defp target("86", phone), do: phone
  defp target(region, phone), do: "00" <> to_string(region) <> phone

  @doc "从短信正文里取出 6 位验证码。正文由 `Rice.Accounts` 拼,格式受控。"
  # Regex.run 的 spec 含 `capture: :index` 的 `{pos, len}`;不带选项时只会是字符串。
  @dialyzer {:no_missing_return, extract_code: 1}
  @spec extract_code(term()) :: String.t() | nil
  def extract_code(text) when is_binary(text) do
    case Regex.run(~r/\d{4,8}/, text) do
      [code] -> code
      _ -> nil
    end
  end

  def extract_code(_), do: nil

  defp do_send(phone, code) do
    cfg = config()

    params = %{
      "Action" => "SendSms",
      "PhoneNumbers" => phone,
      "SignName" => cfg[:sign_name],
      "TemplateCode" => cfg[:template_code],
      "TemplateParam" => Jason.encode!(%{"code" => code})
    }

    case http().post(cfg[:endpoint] || "https://dysmsapi.aliyuncs.com", signed(params, cfg)) do
      {:ok, %{"Code" => "OK"}} ->
        :ok

      {:ok, %{"Code" => code, "Message" => message}} ->
        Logger.error("[阿里云短信] #{code}: #{message}")
        {:error, {:aliyun, code, message}}

      {:ok, body} ->
        {:error, {:aliyun, :unexpected_response, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  @doc """
  给参数加上公共参数和签名,返回完整的 query map。

  单独导出是为了能测签名本身 —— 签名算错的表现是线上 400,
  本地不测就只能到生产才发现。
  """
  @spec signed(map(), keyword(), String.t() | nil, String.t() | nil) :: map()
  def signed(params, cfg, nonce \\ nil, timestamp \\ nil) do
    params =
      Map.merge(params, %{
        "Format" => "JSON",
        "Version" => @api_version,
        "AccessKeyId" => cfg[:access_key_id],
        "SignatureMethod" => "HMAC-SHA1",
        "SignatureVersion" => "1.0",
        "SignatureNonce" => nonce || nonce(),
        "Timestamp" => timestamp || timestamp()
      })

    Map.put(params, "Signature", signature(params, cfg[:access_key_secret]))
  end

  defp signature(params, secret) do
    canonical =
      params
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join("&", fn {k, v} -> encode(k) <> "=" <> encode(to_string(v)) end)

    string_to_sign = "GET&" <> encode("/") <> "&" <> encode(canonical)

    :crypto.mac(:hmac, :sha, secret <> "&", string_to_sign) |> Base.encode64()
  end

  # 阿里云要的是 RFC3986,而 URI.encode_www_form 是 form 编码:
  # 空格变 `+`、`~` 被转义、`*` 不转义。三处都得掰回来。
  defp encode(value) do
    value
    |> URI.encode_www_form()
    |> String.replace("+", "%20")
    |> String.replace("*", "%2A")
    |> String.replace("%7E", "~")
  end

  defp nonce, do: :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

  defp timestamp,
    do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp config, do: Application.get_env(:rice, __MODULE__, [])
  defp http, do: Application.get_env(:rice, :aliyun_http, __MODULE__.Http)

  defmodule Http do
    @moduledoc false
    @callback post(url :: String.t(), query :: map()) :: {:ok, map()} | {:error, term()}
    @behaviour __MODULE__

    @impl true
    def post(url, query) do
      case Req.get(url, params: query, receive_timeout: 15_000) do
        {:ok, %{body: body}} when is_map(body) -> {:ok, body}
        {:ok, %{body: body}} -> {:error, {:unparsable, body}}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end

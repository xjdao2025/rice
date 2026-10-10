defmodule Rice.Aliyun do
  @moduledoc """
  阿里云 RPC 风格 API 的签名(v1.0,HMAC-SHA1)。短信和内容安全共用。

  没有引入阿里云 SDK —— 签名算法是公开且固定的,自己签比拖进一整个 SDK 划算。
  """

  @doc """
  给参数加上公共参数和签名,返回完整的参数 map。`method` 要和真正发请求的方法一致
  (短信用 GET,内容安全只收 POST),它是签名原文的一部分。
  """
  @spec signed(String.t(), map(), keyword(), String.t(), String.t() | nil, String.t() | nil) ::
          map()
  def signed(method, params, cfg, version, nonce \\ nil, timestamp \\ nil) do
    params =
      Map.merge(params, %{
        "Format" => "JSON",
        "Version" => version,
        "AccessKeyId" => cfg[:access_key_id],
        "SignatureMethod" => "HMAC-SHA1",
        "SignatureVersion" => "1.0",
        "SignatureNonce" => nonce || nonce(),
        "Timestamp" => timestamp || timestamp()
      })

    Map.put(params, "Signature", signature(method, params, cfg[:access_key_secret]))
  end

  defp signature(method, params, secret) do
    canonical =
      params
      |> Enum.sort_by(fn {k, _} -> k end)
      |> Enum.map_join("&", fn {k, v} -> encode(k) <> "=" <> encode(to_string(v)) end)

    string_to_sign = method <> "&" <> encode("/") <> "&" <> encode(canonical)

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
end

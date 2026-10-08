defmodule Rice.Dao do
  @moduledoc """
  core 时代 daoJwt 的**读侧兜底**:认这张老票,换成 rice 用户。

  签发那一半(给 core 的 MySQL `t_user` 建档 + 签 RS256 票)已于 2026-10-09
  删除 —— core 停机后它没有任何消费者,rice 也就不再连 MySQL。这里只剩校验,
  钥匙从 `DAO_JWKS_B64`(Nomad Variable `secret/xjdao`)读。

  > ⚠️ **为什么是 base64 而不是直接放 JSON。** Nomad 的 env 模板用
  > go-envparse 解析 `KEY=VALUE`，它会把值里的**双引号吃掉**。本地给环境变量
  > 不会复现，只在 Nomad 里炸。

  ⚠️ 过渡代码,**2026-12-31** 连同 `RiceWeb.Api.Auth` 里的兜底一起删。
  """

  # ── daoJwt 校验（老会话兜底，2026-08-22 加）────────────────────────────

  @doc """
  校验一枚 core 时代的 daoJwt,返回 `{:ok, uid}`(即 `t_user.id`,在 rice 这边
  就是 `users.legacy_id`)。

  为什么需要它:2026-08-21 切到 rice 之后,浏览器里存的还是 core 签的 daoJwt,
  而 rice 只认自己签发的不透明令牌 —— 于是 2000 多个已登录用户的每一个
  `/api/users/me` 都是 401。页面还能浏览(PDS 会话没坏),但余额、发稻米、
  提案全哑掉,而且**前端把余额缺失当成 0**,报出来的是"请输入正确格式"。

  新登录拿到的都是可撤销的 `api_tokens`;这里只认还没过期的老票。

  校验的东西和 core 的 .NET 侧一致:签名 + 生命期 + `type=client`。
  issuer/audience 那边就没校验,这里也不校验 —— 校验了反而会把 core 签的票
  挡在外面。
  """
  def verify_jwt("Bearer " <> rest), do: verify_jwt(String.trim(rest))

  def verify_jwt(token) when is_binary(token) do
    with [h, p, sig] <- String.split(token, ".", parts: 3),
         {:ok, header} <- decode_part(h),
         {:ok, claims} <- decode_part(p),
         {:ok, signature} <- Base.url_decode64(sig, padding: false),
         :ok <- check_alg(header),
         {:ok, jwk} <- jwk_for(header["kid"]),
         {:ok, public_key} <- public_key_from(jwk),
         true <- :public_key.verify(h <> "." <> p, :sha256, signature, public_key),
         :ok <- check_lifetime(claims),
         :ok <- check_type(claims),
         uid when is_binary(uid) and uid != "" <- claims["uid"] do
      {:ok, uid}
    else
      false -> {:error, :bad_signature}
      :error -> {:error, :malformed}
      {:error, _} = err -> err
      _ -> {:error, :malformed}
    end
  end

  def verify_jwt(_), do: {:error, :malformed}

  defp decode_part(part) do
    with {:ok, json} <- Base.url_decode64(part, padding: false),
         {:ok, map} when is_map(map) <- Jason.decode(json) do
      {:ok, map}
    else
      _ -> {:error, :malformed}
    end
  end

  defp check_alg(%{"alg" => "RS256"}), do: :ok
  defp check_alg(_), do: {:error, :unsupported_alg}

  # 没有 kid 或对不上就退回"数组最后一个" —— 和签名侧的选法一致。
  defp jwk_for(kid) do
    with {:ok, json} <- jwks_json(),
         {:ok, keys} when is_list(keys) <- Jason.decode(json) do
      case Enum.find(keys, &(is_map(&1) and &1["Kid"] == kid)) do
        nil -> if keys == [], do: {:error, :jwks_empty}, else: {:ok, List.last(keys)}
        key -> {:ok, key}
      end
    else
      {:ok, _} -> {:error, :jwks_unexpected}
      {:error, _} = err -> err
      _ -> {:error, :jwks_not_configured}
    end
  end

  defp jwks_json do
    case config()[:jwks] do
      json when is_binary(json) and json != "" -> {:ok, json}
      _ -> {:error, :jwks_not_configured}
    end
  end

  # 从**私钥**推公钥,而不是读 JWK 的 `N`/`E`。
  # ⚠️ NetCorePal 写进去的 `N` 是标准 base64(含 `+` `/`),不是 base64url ——
  # 按 base64url 解会得到不同的字节,校验必然失败且看着像"钥匙对不上"。
  # 私钥 DER 我们本来就要解,直接取里面的模数和指数,绕开这个坑。
  defp public_key_from(%{"PrivateKey" => pk_b64}) do
    case decode_private_key(pk_b64) do
      {:ok, {:RSAPrivateKey, _v, n, e, _d, _p, _q, _e1, _e2, _c, _other}} ->
        {:ok, {:RSAPublicKey, n, e}}

      {:ok, other} ->
        {:error, {:unsupported_key, other}}

      {:error, _} = err ->
        err
    end
  end

  defp public_key_from(_), do: {:error, :jwk_without_private_key}

  # 允许 60 秒时钟偏差 —— 两台机器的 NTP 不一定一致。
  @leeway 60

  defp check_lifetime(claims) do
    now = System.os_time(:second)
    exp = as_int(claims["exp"])
    nbf = as_int(claims["nbf"])

    cond do
      is_nil(exp) -> {:error, :no_exp}
      now > exp + @leeway -> {:error, :expired}
      is_integer(nbf) and now < nbf - @leeway -> {:error, :not_yet_valid}
      true -> :ok
    end
  end

  defp as_int(v) when is_integer(v), do: v

  defp as_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, _} -> i
      :error -> nil
    end
  end

  defp as_int(_), do: nil

  defp check_type(%{"type" => "client"}), do: :ok
  defp check_type(_), do: {:error, :not_client_token}

  # PrivateKey is standard-base64 DER: PKCS#1 (`RSAPrivateKey`) from
  # RSA.ExportRSAPrivateKey, with a PKCS#8 fallback just in case.
  defp decode_private_key(b64) do
    case Base.decode64(b64) do
      {:ok, der} -> parse_rsa_der(der)
      :error -> {:error, :bad_private_key_base64}
    end
  end

  defp parse_rsa_der(der) do
    {:ok, :public_key.der_decode(:RSAPrivateKey, der)}
  rescue
    _ ->
      try do
        case :public_key.der_decode(:PrivateKeyInfo, der) do
          {:PrivateKeyInfo, _, _, wrapped, _} ->
            {:ok, :public_key.der_decode(:RSAPrivateKey, wrapped)}

          other ->
            {:error, {:unsupported_key, other}}
        end
      rescue
        e -> {:error, {:bad_private_key, e}}
      end
  end

  defp config, do: Application.fetch_env!(:rice, :dao)
end

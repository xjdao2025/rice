defmodule Rice.DaoJwtVerifyTest do
  @moduledoc """
  `Rice.Dao.verify_jwt/1` —— 老 daoJwt 的读侧兜底。

  为什么有这段代码：2026-08-21 切到 rice 之后，浏览器里存的还是 core 签的
  daoJwt，rice 只认自己的不透明令牌 —— 于是 2000 多个已登录用户的每个需要
  登录的接口都是 401，而页面照常能浏览（PDS 会话没坏），等于**全员静默登出**。

  这里守的是三件事：

  1. 该认的认（core 签的票，claims 形状与 `mint_jwt/2` 一致）；
  2. **不该认的一律不认** —— 改过的签名、换掉的算法、过期的票、
     `type != client` 的票。这是一条绕过正常令牌的认证路径，宽一点就是洞。
  3. 公钥从**私钥 DER** 推，不读 JWK 的 `N` —— 那个是标准 base64，
     按 base64url 解会静默得到错的字节（见 `Rice.DaoJwksTest`）。
  """
  use ExUnit.Case, async: true

  defp fixture_key, do: :public_key.generate_key({:rsa, 2048, 65537})

  defp jwk(key, kid) do
    {:RSAPrivateKey, _v, n, e, _d, _p, _q, _e1, _e2, _c, _o} = key

    %{
      "Kid" => kid,
      "Kty" => "RSA",
      "Alg" => "RS256",
      "Use" => "sig",
      "PrivateKey" => Base.encode64(:public_key.der_encode(:RSAPrivateKey, key)),
      "N" => n |> :binary.encode_unsigned() |> Base.encode64(),
      "E" => e |> :binary.encode_unsigned() |> Base.encode64()
    }
  end

  defp put_jwks(value) do
    cfg = Application.get_env(:rice, :dao, [])
    Application.put_env(:rice, :dao, Keyword.put(cfg, :jwks, value))
    on_exit(fn -> Application.put_env(:rice, :dao, cfg) end)
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  # 照抄 core 的 JwtGenerator.Generate 的形状
  defp sign(key, kid, claims) do
    now = System.os_time(:second)

    claims =
      Map.merge(
        %{
          "uid" => "core-user-id",
          "type" => "client",
          "phone" => "",
          "email" => "someone@web5.xjdao.xyz",
          "phone-region" => "",
          "domain-name" => "someone.web5.xjdao.xyz",
          "nbf" => now,
          "iat" => now,
          "exp" => now + 3600
        },
        claims
      )

    input =
      b64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT", "kid" => kid})) <>
        "." <> b64(Jason.encode!(claims))

    input <> "." <> b64(:public_key.sign(input, :sha256, key))
  end

  describe "认" do
    setup do
      key = fixture_key()
      put_jwks(Jason.encode!([jwk(key, "k1")]))
      %{key: key}
    end

    test "core 签的票 → {:ok, uid}", %{key: key} do
      assert {:ok, "core-user-id"} = Rice.Dao.verify_jwt(sign(key, "k1", %{}))
    end

    test "带 Bearer 前缀也认 —— 存在浏览器里的就是这个形状", %{key: key} do
      assert {:ok, "core-user-id"} = Rice.Dao.verify_jwt("Bearer " <> sign(key, "k1", %{}))
    end

    test "kid 对不上时退回数组最后一个 —— 与签名侧的选法一致", %{key: key} do
      assert {:ok, "core-user-id"} = Rice.Dao.verify_jwt(sign(key, "不存在的kid", %{}))
    end

    test "允许 60 秒时钟偏差", %{key: key} do
      just_expired = System.os_time(:second) - 30
      assert {:ok, _} = Rice.Dao.verify_jwt(sign(key, "k1", %{"exp" => just_expired}))
    end
  end

  describe "不认" do
    setup do
      key = fixture_key()
      put_jwks(Jason.encode!([jwk(key, "k1")]))
      %{key: key}
    end

    test "签名被改过", %{key: key} do
      [h, p, _sig] = String.split(sign(key, "k1", %{}), ".")
      other = sign(fixture_key(), "k1", %{})
      [_, _, other_sig] = String.split(other, ".")

      assert {:error, :bad_signature} = Rice.Dao.verify_jwt("#{h}.#{p}.#{other_sig}")
    end

    test "别的钥匙签的", %{key: _key} do
      assert {:error, :bad_signature} = Rice.Dao.verify_jwt(sign(fixture_key(), "k1", %{}))
    end

    test "claims 被改过（换个 uid 就想变成别人）", %{key: key} do
      [h, _p, sig] = String.split(sign(key, "k1", %{}), ".")
      forged = b64(Jason.encode!(%{"uid" => "别人", "type" => "client"}))

      assert {:error, :bad_signature} = Rice.Dao.verify_jwt("#{h}.#{forged}.#{sig}")
    end

    test "alg=none 这种老把戏", %{key: key} do
      [_h, p, sig] = String.split(sign(key, "k1", %{}), ".")
      header = b64(Jason.encode!(%{"alg" => "none", "typ" => "JWT"}))

      assert {:error, :unsupported_alg} = Rice.Dao.verify_jwt("#{header}.#{p}.#{sig}")
    end

    test "过期（超出 60 秒容差）", %{key: key} do
      assert {:error, :expired} =
               Rice.Dao.verify_jwt(sign(key, "k1", %{"exp" => System.os_time(:second) - 120}))
    end

    test "没有 exp —— 永不过期的票不能认", %{key: key} do
      [header, payload, _sig] = String.split(sign(key, "k1", %{}), ".")
      {:ok, json} = Base.url_decode64(payload, padding: false)
      claims = json |> Jason.decode!() |> Map.delete("exp")

      # 要重新签一遍，否则会先被签名检查挡下来 —— 这里验的是 exp 缺失本身
      input = header <> "." <> b64(Jason.encode!(claims))

      assert {:error, :no_exp} =
               Rice.Dao.verify_jwt(input <> "." <> b64(:public_key.sign(input, :sha256, key)))
    end

    test "type 不是 client（后台票不能当前台用）", %{key: key} do
      assert {:error, :not_client_token} =
               Rice.Dao.verify_jwt(sign(key, "k1", %{"type" => "admin"}))
    end

    test "根本不是 JWT" do
      assert {:error, :malformed} = Rice.Dao.verify_jwt("随便一串东西")
      assert {:error, :malformed} = Rice.Dao.verify_jwt("")
      assert {:error, :malformed} = Rice.Dao.verify_jwt(nil)
    end

    test "JWKS 没配时不认也不崩", %{key: key} do
      token = sign(key, "k1", %{})
      put_jwks(nil)
      assert {:error, :jwks_not_configured} = Rice.Dao.verify_jwt(token)
    end
  end
end

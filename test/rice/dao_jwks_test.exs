defmodule Rice.DaoJwksTest do
  @moduledoc """
  签 daoJwt 用的 JWKS 现在从配置读（`DAO_JWKS`），不再从共享 Redis 读。

  这几个测试守的是两件事：

  1. **配置缺失/损坏时给出的是能定位的错误**，不是 `MatchError` 或
     `FunctionClauseError`。这条链路是 best-effort 的 —— 失败只会在日志里
     留一行，所以那一行必须说清楚是什么坏了。

  2. **`N` 是标准 base64，不是 base64url。** 导出这把钥匙时按 base64url 解过
     一次，得到的字节不同，自检报「模数与私钥不一致」—— 差点误判成钥匙坏了。
     测试里的 fixture 保留这个特征。
  """
  use ExUnit.Case, async: true

  # 测试专用的 2048 位密钥，与生产那把无关。
  # 结构照抄 NetCorePal 写进 Redis 的形状：PrivateKey 是 PKCS#1 DER 的
  # 标准 base64，N/E 也是标准 base64。
  defp fixture_jwk do
    key = :public_key.generate_key({:rsa, 2048, 65537})
    {:RSAPrivateKey, _v, n, e, _d, _p, _q, _e1, _e2, _c, _o} = key

    %{
      "Kid" => "test-kid-0001",
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

  describe "current_jwk/0" do
    test "取数组里的最后一个 —— 与 core 的选法一致" do
      old = fixture_jwk() |> Map.put("Kid", "old")
      new = fixture_jwk() |> Map.put("Kid", "new")
      put_jwks(Jason.encode!([old, new]))

      assert {:ok, %{"Kid" => "new"}} = Rice.Dao.current_jwk()
    end

    test "没配时说的是「没配」，不是崩" do
      put_jwks(nil)
      assert {:error, :jwks_not_configured} = Rice.Dao.current_jwk()
    end

    test "空串等同没配 —— Nomad 模板渲染出空值是常见情形" do
      put_jwks("")
      assert {:error, :jwks_not_configured} = Rice.Dao.current_jwk()
    end

    test "不是 JSON 时报得出来" do
      put_jwks("这显然不是 JSON")
      assert {:error, {:jwks_not_json, _}} = Rice.Dao.current_jwk()
    end

    test "空数组和「不是数组」是两种不同的错" do
      put_jwks("[]")
      assert {:error, :jwks_empty} = Rice.Dao.current_jwk()

      put_jwks(~s({"Kid":"x"}))
      assert {:error, {:jwks_unexpected, _}} = Rice.Dao.current_jwk()
    end
  end

  describe "fixture 自身的完整性（同时是导出生产密钥时用的那套校验）" do
  end
end

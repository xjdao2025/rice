defmodule RiceWeb.Api.LegacyJwtAuthTest do
  @moduledoc """
  老 daoJwt 走完整请求链路的兜底认证。

  `async: false` —— JWKS 是应用级配置，改它会影响并发跑的别的测试。

  背景见 `RiceWeb.Api.Auth.user_for/1`：切到 rice 当天，所有人浏览器里只有
  core 签的 daoJwt，结果是全员静默登出（切换后一整天 2028 个用户里只有 5 个
  拿到过 rice 令牌）。
  """
  use RiceWeb.ConnCase, async: false

  setup do
    key = :public_key.generate_key({:rsa, 2048, 65537})

    jwk = %{
      "Kid" => "k1",
      "Kty" => "RSA",
      "Alg" => "RS256",
      "PrivateKey" => Base.encode64(:public_key.der_encode(:RSAPrivateKey, key))
    }

    cfg = Application.get_env(:rice, :dao, [])
    Application.put_env(:rice, :dao, Keyword.put(cfg, :jwks, Jason.encode!([jwk])))
    on_exit(fn -> Application.put_env(:rice, :dao, cfg) end)

    %{key: key}
  end

  defp dao_jwt(key, claims) do
    now = System.os_time(:second)

    claims =
      Map.merge(%{"type" => "client", "nbf" => now, "iat" => now, "exp" => now + 3600}, claims)

    input =
      Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT", "kid" => "k1"}),
        padding: false
      ) <>
        "." <> Base.url_encode64(Jason.encode!(claims), padding: false)

    input <>
      "." <> Base.url_encode64(:public_key.sign(input, :sha256, key), padding: false)
  end

  test "带老 daoJwt 也能拿到 /api/users/me", %{conn: conn, key: key} do
    user = user_fixture(%{legacy_id: "core-uid-1", nickname: "南新"})

    assert %{"data" => data} =
             conn
             |> authed(dao_jwt(key, %{"uid" => "core-uid-1"}))
             |> get(~p"/api/users/me")
             |> json_response(200)

    assert data["id"] == user.id
    assert data["nickname"] == "南新"
  end

  test "旧票迁移指标只包含计数和结果，不含身份或令牌", %{key: key} do
    parent = self()
    handler = "legacy-auth-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:rice, :auth, :legacy],
      fn _, measurements, metadata, _ ->
        send(parent, {:legacy_metric, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    user_fixture(%{legacy_id: "legacy-metric"})
    token = dao_jwt(key, %{"uid" => "legacy-metric"})
    build_conn() |> authed(token) |> get(~p"/api/users/me") |> json_response(200)
    assert_received {:legacy_metric, %{count: 1}, %{result: :accepted}}
    assert :ok = Rice.Accounts.revoke_session_token(token)
    build_conn() |> authed(token) |> get(~p"/api/users/me") |> json_response(401)
    assert_received {:legacy_metric, %{count: 1}, %{result: :rejected}}
  end

  test "uid 在 rice 这边没有对应的人 → 401", %{conn: conn, key: key} do
    conn
    |> authed(dao_jwt(key, %{"uid" => "查无此人"}))
    |> get(~p"/api/users/me")
    |> json_response(401)
  end

  test "被禁用的人即使拿着有效老票也进不来", %{conn: conn, key: key} do
    user = user_fixture(%{legacy_id: "core-uid-2"})

    user
    |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
    |> Rice.Repo.update!()

    conn
    |> authed(dao_jwt(key, %{"uid" => "core-uid-2"}))
    |> get(~p"/api/users/me")
    |> json_response(401)
  end

  test "退出当前旧票会撤销它，增加 Bearer 前缀不能绕过，其他旧票不受影响", %{key: key} do
    user_fixture(%{legacy_id: "logout-legacy"})
    first = dao_jwt(key, %{"uid" => "logout-legacy", "jti" => "first"})
    second = dao_jwt(key, %{"uid" => "logout-legacy", "jti" => "second"})
    padded = first <> "=="
    assert {:ok, "logout-legacy"} = Rice.Dao.verify_jwt(padded)
    build_conn() |> authed(first) |> delete(~p"/api/session") |> response(204)

    for token <- [first, padded, "Bearer " <> first, "Bearer Bearer " <> first] do
      build_conn() |> authed(token) |> get(~p"/api/users/me") |> json_response(401)
    end

    build_conn() |> authed(second) |> get(~p"/api/users/me") |> json_response(200)
    assert Rice.Repo.aggregate(Rice.Accounts.RevokedLegacyToken, :count) == 1
  end

  test "撤销全部令牌会关闭旧票兜底；禁用后再启用也不会复活旧票", %{key: key} do
    user = user_fixture(%{legacy_id: "revoke-all-legacy"})
    token = dao_jwt(key, %{"uid" => user.legacy_id})
    assert {:ok, _} = Rice.Accounts.revoke_all_tokens(user)
    build_conn() |> authed(token) |> get(~p"/api/users/me") |> json_response(401)
    assert {:ok, user} = Rice.Admin.Users.update_user(user, %{"disabled" => true})
    assert {:ok, _} = Rice.Admin.Users.update_user(user, %{"disabled" => false})
    build_conn() |> authed(token) |> get(~p"/api/users/me") |> json_response(401)
  end

  test "过期的老票不认", %{conn: conn, key: key} do
    user_fixture(%{legacy_id: "core-uid-3"})

    conn
    |> authed(dao_jwt(key, %{"uid" => "core-uid-3", "exp" => System.os_time(:second) - 3600}))
    |> get(~p"/api/users/me")
    |> json_response(401)
  end
end

defmodule RiceWeb.Api.SessionControllerTest do
  use RiceWeb.ConnCase, async: true

  import Mox
  setup :verify_on_exit!

  defp pds_ok(user) do
    %{"did" => user.did, "handle" => user.handle, "accessJwt" => "acc", "refreshJwt" => "ref"}
  end

  describe "POST /api/session" do
    setup do
      %{user: user_fixture(%{handle: "alice.web5.xjdao.test", email: "alice@example.com"})}
    end

    test "登录成功返回 rice 令牌和 PDS 会话", %{conn: conn, user: user} do
      expect(Rice.PDSMock, :create_session, fn _, _ -> {:ok, pds_ok(user)} end)

      assert %{"data" => data} =
               conn
               |> post(~p"/api/session", %{identifier: user.handle, password: "pw"})
               |> json_response(200)

      assert is_binary(data["token"])
      assert data["user"]["id"] == user.id
      assert data["pds"]["access_jwt"] == "acc"
      assert data["pds"]["refresh_jwt"] == "ref"
      assert data["pds"]["did"] == user.did
    end

    test "拿到的令牌可以直接用", %{conn: conn, user: user} do
      expect(Rice.PDSMock, :create_session, fn _, _ -> {:ok, pds_ok(user)} end)

      token =
        conn
        |> post(~p"/api/session", %{identifier: user.handle, password: "pw"})
        |> json_response(200)
        |> get_in(["data", "token"])

      assert %{"data" => %{"id" => id}} =
               build_conn() |> authed(token) |> get(~p"/api/users/me") |> json_response(200)

      assert id == user.id
    end

    test "响应里不会漏出密码", %{conn: conn, user: user} do
      expect(Rice.PDSMock, :create_session, fn _, _ -> {:ok, pds_ok(user)} end)

      body =
        conn
        |> post(~p"/api/session", %{identifier: user.handle, password: "s3cr3t-pw"})
        |> response(200)

      refute body =~ "s3cr3t-pw"
    end

    test "密码错误返回 401", %{conn: conn, user: user} do
      expect(Rice.PDSMock, :create_session, fn _, _ -> {:error, {:pds, "x", 401, "bad"}} end)

      assert %{"error" => "InvalidCredentials", "errors" => %{"detail" => detail}} =
               conn
               |> post(~p"/api/session", %{identifier: user.handle, password: "wrong"})
               |> json_response(401)

      assert detail == "账号或密码错误"
    end

    # 两条路径的响应必须一模一样,否则就是个账号枚举接口
    test "账号不存在时的响应与密码错误完全一致", %{conn: conn, user: user} do
      expect(Rice.PDSMock, :create_session, 2, fn _, _ ->
        {:error, {:pds, "createSession", 401, "AuthenticationRequired"}}
      end)

      wrong_pw =
        conn
        |> post(~p"/api/session", %{identifier: user.handle, password: "x"})
        |> json_response(401)

      no_user =
        build_conn()
        |> post(~p"/api/session", %{identifier: "nobody.test", password: "x"})
        |> json_response(401)

      assert wrong_pw == no_user
    end

    test "PDS 不可用返回 503 和明确错误码，且不暴露账号是否存在", %{conn: conn, user: user} do
      expect(Rice.PDSMock, :create_session, 2, fn _, _ -> {:error, {:transport, :timeout}} end)

      for identifier <- [user.handle, "nobody.test"] do
        assert %{
                 "error" => "LoginUnavailable",
                 "errors" => %{"detail" => "登录服务暂时不可用，请稍后重试。"}
               } =
                 conn
                 |> post(~p"/api/session", %{identifier: identifier, password: "pw"})
                 |> json_response(503)
      end
    end

    test "被禁用的账号返回 403", %{conn: conn, user: user} do
      Rice.Repo.update!(Ecto.Changeset.change(user, disabled_at: DateTime.utc_now()))

      assert conn
             |> post(~p"/api/session", %{identifier: user.handle, password: "pw"})
             |> json_response(403)
    end

    test "缺参数返回 422", %{conn: conn} do
      for params <- [%{}, %{identifier: "a"}, %{password: "b"}, %{identifier: 1, password: 2}] do
        assert conn |> post(~p"/api/session", params) |> json_response(422)
      end
    end
  end

  describe "DELETE /api/session" do
    test "登出后令牌立即失效", %{conn: conn} do
      {_user, token} = user_with_token()

      assert conn |> authed(token) |> delete(~p"/api/session") |> response(204)
      assert build_conn() |> authed(token) |> get(~p"/api/users/me") |> json_response(401)
    end

    test "未认证时 401", %{conn: conn} do
      assert conn |> delete(~p"/api/session") |> json_response(401)
    end
  end
end

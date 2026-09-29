defmodule RiceWeb.Api.RegistrationControllerTest do
  use RiceWeb.ConnCase, async: true

  import Mox
  setup :verify_on_exit!

  setup do
    stub(Rice.PDSMock, :handle_domain, fn -> "web5.xjdao.test" end)
    :ok
  end

  alias Rice.Accounts.VerificationCode

  defp seed_code(channel, target) do
    code = VerificationCode.generate_code()
    Rice.Repo.insert!(VerificationCode.build(channel, target, "register", code))
    code
  end

  defp ticket_for(conn, phone) do
    code = seed_code("sms", Rice.Accounts.phone_target("86", phone))

    conn
    |> post(~p"/api/registrations/verification", %{channel: "sms", phone: phone, code: code})
    |> json_response(200)
    |> get_in(["data", "ticket"])
  end

  describe "POST /api/verification_codes" do
    test "发短信验证码返回 204", %{conn: conn} do
      expect(Rice.NotificationsMock, :send_sms, fn "86", "13800000000", _ -> :ok end)

      assert conn
             |> post(~p"/api/verification_codes", %{
               channel: "sms",
               phone: "13800000000",
               purpose: "register"
             })
             |> response(204)
    end

    test "未配置通道明确失败,不留下可校验的验证码或限流记录", %{conn: conn} do
      expect(Rice.NotificationsMock, :send_sms, 2, fn _, _, _ ->
        {:error, :channel_not_configured}
      end)

      params = %{channel: "sms", phone: "13900000001", purpose: "register"}

      for _ <- 1..2 do
        assert conn |> post(~p"/api/verification_codes", params) |> json_response(503)
      end

      refute Rice.Repo.get_by(VerificationCode, target: "86-13900000001")
    end

    test "发邮件验证码返回 204", %{conn: conn} do
      expect(Rice.NotificationsMock, :send_email, fn "a@example.com", _, _ -> :ok end)

      assert conn
             |> post(~p"/api/verification_codes", %{
               channel: "email",
               email: "a@example.com",
               purpose: "register"
             })
             |> response(204)
    end

    # core 完全没有这层,同一个号码可以被无限轰炸
    test "60 秒内重复请求返回 429", %{conn: conn} do
      expect(Rice.NotificationsMock, :send_sms, fn _, _, _ -> :ok end)
      params = %{channel: "sms", phone: "13800000000", purpose: "register"}

      conn = post(conn, ~p"/api/verification_codes", params)
      assert response(conn, 204) == ""
      assert get_resp_header(conn, "retry-after") == ["60"]

      record = Rice.Repo.get_by!(VerificationCode, target: "86-13800000000")

      record
      |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(), -15, :second))
      |> Rice.Repo.update!()

      conn =
        post(build_conn(), ~p"/api/verification_codes", %{params | purpose: "reset_password"})

      assert json_response(conn, 429)
      assert [seconds] = get_resp_header(conn, "retry-after")
      assert String.to_integer(seconds) in 44..45
    end

    test "非法通道或用途返回 422", %{conn: conn} do
      for params <- [
            %{channel: "carrier", phone: "1", purpose: "register"},
            %{channel: "sms", phone: "1", purpose: "hack"},
            %{channel: "sms", purpose: "register"},
            %{}
          ] do
        assert conn |> post(~p"/api/verification_codes", params) |> json_response(422)
      end
    end

    test "响应体里绝不包含验证码", %{conn: conn} do
      sent = :atomics.new(1, signed: false)

      expect(Rice.NotificationsMock, :send_sms, fn _, _, text ->
        [code] = Regex.run(~r/\d{6}/, text)
        :atomics.put(sent, 1, String.to_integer(code))
        :ok
      end)

      body =
        conn
        |> post(~p"/api/verification_codes", %{
          channel: "sms",
          phone: "13800000000",
          purpose: "register"
        })
        |> response(204)

      code = :atomics.get(sent, 1) |> Integer.to_string() |> String.pad_leading(6, "0")
      assert body == ""
      refute body =~ code
    end
  end

  describe "POST /api/registrations/verification" do
    test "验证码正确时换到一张票", %{conn: conn} do
      code = seed_code("sms", Rice.Accounts.phone_target("86", "13800000000"))

      assert %{"data" => %{"ticket" => ticket, "expires_in" => 1800}} =
               conn
               |> post(~p"/api/registrations/verification", %{
                 channel: "sms",
                 phone: "13800000000",
                 code: code
               })
               |> json_response(200)

      assert is_binary(ticket)
    end

    test "验证码错误返回 422", %{conn: conn} do
      seed_code("sms", Rice.Accounts.phone_target("86", "13800000000"))

      assert conn
             |> post(~p"/api/registrations/verification", %{
               channel: "sms",
               phone: "13800000000",
               code: "000000"
             })
             |> json_response(422)
    end

    test "猜太多次后返回 429", %{conn: conn} do
      seed_code("sms", Rice.Accounts.phone_target("86", "13800000000"))
      params = %{channel: "sms", phone: "13800000000", code: "000000"}

      for _ <- 1..VerificationCode.max_attempts() do
        build_conn() |> post(~p"/api/registrations/verification", params) |> json_response(422)
      end

      assert conn |> post(~p"/api/registrations/verification", params) |> json_response(429)
    end
  end

  describe "POST /api/registrations" do
    test "凭票和用户名前缀完成注册,域名由服务端控制", %{conn: conn} do
      ticket = ticket_for(conn, "13800000000")

      expect(Rice.PDSMock, :email_domain, fn -> "web5.xjdao.test" end)

      expect(Rice.PDSMock, :create_account, fn %{handle: "alice-42.web5.xjdao.test"} ->
        {:ok,
         %{
           "did" => "did:plc:alice",
           "handle" => "alice-42.web5.xjdao.test",
           "accessJwt" => "acc",
           "refreshJwt" => "ref"
         }}
      end)

      expect(Rice.PDSMock, :put_profile, fn "acc",
                                            "did:plc:alice",
                                            %{"displayName" => "alice-42"} ->
        {:ok, %{}}
      end)

      assert %{"data" => data} =
               build_conn()
               |> post(~p"/api/registrations", %{
                 ticket: ticket,
                 username: " Alice-42 ",
                 handle: "attacker.other.test",
                 handle_domain: "other.test",
                 nickname: "小禾",
                 password: "hunter2hunter2"
               })
               |> json_response(201)

      assert data["user"]["did"] == "did:plc:alice"
      assert data["user"]["handle"] == "alice-42.web5.xjdao.test"
      assert data["user"]["nickname"] == "alice-42"
      assert data["user"]["phone"] == "13800000000"
      assert is_binary(data["token"])
    end

    test "允许 3 位和 18 位用户名前缀", %{conn: conn} do
      for {username, phone} <- [
            {"a-1", "13800000001"},
            {String.duplicate("a", 18), "13800000002"}
          ] do
        ticket = ticket_for(conn, phone)
        handle = "#{username}.web5.xjdao.test"
        did = "did:plc:#{username}"

        expect(Rice.PDSMock, :email_domain, fn -> "web5.xjdao.test" end)

        expect(Rice.PDSMock, :create_account, fn %{handle: ^handle} ->
          {:ok, %{"did" => did, "handle" => handle, "accessJwt" => "acc"}}
        end)

        expect(Rice.PDSMock, :put_profile, fn "acc", ^did, %{"displayName" => ^username} ->
          {:ok, %{}}
        end)

        assert %{"data" => %{"user" => %{"handle" => ^handle, "nickname" => ^username}}} =
                 build_conn()
                 |> post(~p"/api/registrations", %{
                   ticket: ticket,
                   username: username,
                   password: "hunter2hunter2"
                 })
                 |> json_response(201)
      end
    end

    test "票据里的手机号不可被请求参数覆盖", %{conn: conn} do
      ticket = ticket_for(conn, "13800000000")

      expect(Rice.PDSMock, :email_domain, fn -> "web5.xjdao.test" end)

      expect(Rice.PDSMock, :create_account, fn %{handle: "alice.web5.xjdao.test"} ->
        {:ok, %{"did" => "did:plc:a", "handle" => "alice.web5.xjdao.test", "accessJwt" => "acc"}}
      end)

      expect(Rice.PDSMock, :put_profile, fn "acc", "did:plc:a", %{"displayName" => "alice"} ->
        {:ok, %{}}
      end)

      assert %{"data" => data} =
               build_conn()
               |> post(~p"/api/registrations", %{
                 ticket: ticket,
                 username: "alice",
                 password: "hunter2hunter2",
                 phone: "13900000000",
                 email: "attacker@example.com"
               })
               |> json_response(201)

      assert data["user"]["phone"] == "13800000000"
      assert is_nil(data["user"]["email"])
    end

    test "没有票 / 票伪造 / 票过期都是 422", %{conn: conn} do
      for ticket <- [nil, "", "forged", Phoenix.Token.sign(RiceWeb.Endpoint, "别的 salt", %{})] do
        assert conn
               |> post(~p"/api/registrations", %{
                 ticket: ticket,
                 username: "alice",
                 password: "hunter2hunter2"
               })
               |> json_response(422)
      end
    end

    test "密码短于 8 位被拒", %{conn: conn} do
      ticket = ticket_for(conn, "13800000000")

      assert %{"errors" => %{"detail" => "密码至少 8 位"}} =
               build_conn()
               |> post(~p"/api/registrations", %{
                 ticket: ticket,
                 username: "alice",
                 password: "short"
               })
               |> json_response(422)
    end

    test "缺失或不符合 PDS 子域规则的用户名不创建账号", %{conn: conn} do
      ticket = ticket_for(conn, "13800000000")

      for username <- [
            nil,
            "  ",
            "ab",
            String.duplicate("a", 19),
            "小禾用户",
            "ali_ce",
            "alice.example.test",
            "-alice",
            "alice-",
            "a b",
            "alice\nother",
            %{}
          ] do
        assert %{
                 "errors" => %{
                   "detail" => "用户名须为 3–18 位字母、数字或连字符，首尾须为字母或数字"
                 }
               } =
                 build_conn()
                 |> post(~p"/api/registrations", %{
                   ticket: ticket,
                   username: username,
                   nickname: "小禾",
                   handle: "alice.web5.xjdao.test",
                   password: "hunter2hunter2"
                 })
                 |> json_response(422)
      end
    end

    test "PDS 用户名占用返回明确错误,同票更换用户名可继续注册", %{conn: conn} do
      ticket = ticket_for(conn, "13800000000")
      expect(Rice.PDSMock, :email_domain, 4, fn -> "web5.xjdao.test" end)

      for error <- [
            "HandleNotAvailable",
            "HandleNotAvailable: Handle already taken",
            "InvalidRequest: Handle already taken: alice.web5.xjdao.test"
          ] do
        expect(Rice.PDSMock, :create_account, fn %{handle: "alice.web5.xjdao.test"} ->
          {:error, {:pds, "com.atproto.server.createAccount", 400, error}}
        end)

        assert %{"errors" => %{"detail" => "用户名已被使用，请换一个用户名"}} =
                 build_conn()
                 |> post(~p"/api/registrations", %{
                   ticket: ticket,
                   username: "alice",
                   password: "hunter2hunter2"
                 })
                 |> json_response(422)
      end

      expect(Rice.PDSMock, :create_account, fn %{handle: "other-user.web5.xjdao.test"} ->
        {:ok,
         %{
           "did" => "did:plc:other",
           "handle" => "other-user.web5.xjdao.test",
           "accessJwt" => "acc"
         }}
      end)

      expect(Rice.PDSMock, :put_profile, fn "acc",
                                            "did:plc:other",
                                            %{"displayName" => "other-user"} ->
        {:ok, %{}}
      end)

      assert %{"data" => %{"user" => %{"handle" => "other-user.web5.xjdao.test"}}} =
               build_conn()
               |> post(~p"/api/registrations", %{
                 ticket: ticket,
                 username: "other-user",
                 password: "hunter2hunter2"
               })
               |> json_response(201)
    end

    test "其他上游失败可同票同用户名重试,不透出内部错误", %{conn: conn} do
      ticket = ticket_for(conn, "13800000000")
      expect(Rice.PDSMock, :email_domain, 2, fn -> "web5.xjdao.test" end)

      for reason <- [
            {:pds, "com.atproto.server.createAccount", 400, "InvalidRequest: internal detail"},
            {:transport, :econnrefused}
          ] do
        expect(Rice.PDSMock, :create_account, fn %{handle: "alice.web5.xjdao.test"} ->
          {:error, reason}
        end)

        assert %{"errors" => %{"detail" => "创建账号失败"}} =
                 build_conn()
                 |> post(~p"/api/registrations", %{
                   ticket: ticket,
                   username: "alice",
                   password: "hunter2hunter2"
                 })
                 |> json_response(502)
      end
    end

    test "手机号已被占用时返回 422,且不去建 PDS 账号", %{conn: conn} do
      user_fixture(%{phone: "13800000000", phone_region: "86"})
      ticket = ticket_for(conn, "13800000000")

      assert build_conn()
             |> post(~p"/api/registrations", %{
               ticket: ticket,
               username: "alice",
               password: "hunter2hunter2"
             })
             |> json_response(422)
    end
  end
end

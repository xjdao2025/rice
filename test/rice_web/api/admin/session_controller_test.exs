defmodule RiceWeb.Api.Admin.SessionControllerTest do
  use RiceWeb.ConnCase, async: true

  import Ecto.Query
  import Mox
  setup :verify_on_exit!

  alias Rice.Accounts.VerificationCode

  defp seed_code(target, purpose) do
    code = VerificationCode.generate_code()
    Rice.Repo.insert!(VerificationCode.build("sms", target, purpose, code))
    code
  end

  describe "两步登录" do
    setup do
      %{admin: admin_fixture(%{phone: "13900000001", phone_region: "86"})}
    end

    test "密码对了才发验证码", %{conn: conn} do
      expect(Rice.NotificationsMock, :send_sms, fn "86", "13900000001", _text -> :ok end)

      assert conn
             |> post(~p"/api/admin/session/challenge", %{
               phone: "13900000001",
               phone_region: "86",
               password: "admin-password"
             })
             |> response(202)

      assert Rice.Repo.get_by(VerificationCode, target: "86-13900000001", purpose: "admin_login")
    end

    # core 的发码接口是公开的:不知道密码也能让管理员的手机响
    test "密码不对不会发出验证码", %{conn: conn} do
      assert conn
             |> post(~p"/api/admin/session/challenge", %{
               phone: "13900000001",
               phone_region: "86",
               password: "猜的"
             })
             |> json_response(401)

      refute Rice.Repo.get_by(VerificationCode, target: "86-13900000001")
    end

    test "密码 + 验证码换令牌", %{conn: conn, admin: admin} do
      code = seed_code("86-13900000001", "admin_login")

      assert %{"data" => %{"token" => token, "admin" => data}} =
               conn
               |> post(~p"/api/admin/session", %{
                 phone: "13900000001",
                 phone_region: "86",
                 password: "admin-password",
                 code: code
               })
               |> json_response(201)

      assert data["id"] == admin.id
      assert data["role"] == "admin"
      # 摘要和盐一个字节都不该出现在响应里
      refute Map.has_key?(data, "password_hash")
      refute Map.has_key?(data, "password_salt")

      assert %{"data" => me} =
               build_conn() |> authed(token) |> get(~p"/api/admin/me") |> json_response(200)

      assert me["id"] == admin.id
    end

    # 只有验证码不够 —— 手机被别人拿到也不该等于拿到后台
    test "只有验证码、密码错的,换不到令牌", %{conn: conn} do
      code = seed_code("86-13900000001", "admin_login")

      assert conn
             |> post(~p"/api/admin/session", %{
               phone: "13900000001",
               phone_region: "86",
               password: "猜的",
               code: code
             })
             |> json_response(401)
    end

    test "换个用途的验证码不认", %{conn: conn} do
      code = seed_code("86-13900000001", "admin_reset_password")

      assert conn
             |> post(~p"/api/admin/session", %{
               phone: "13900000001",
               phone_region: "86",
               password: "admin-password",
               code: code
             })
             |> json_response(401)
    end

    test "被停用的管理员登不进来", %{conn: conn, admin: admin} do
      Rice.Repo.update!(Ecto.Changeset.change(admin, disabled_at: DateTime.utc_now()))
      code = seed_code("86-13900000001", "admin_login")

      assert conn
             |> post(~p"/api/admin/session", %{
               phone: "13900000001",
               phone_region: "86",
               password: "admin-password",
               code: code
             })
             |> json_response(401)
    end

    # 账号不存在和密码错必须长得一样,否则就是个"谁是管理员"的探测器
    test "账号不存在与密码错的响应完全相同", %{conn: _conn} do
      a =
        build_conn()
        |> post(~p"/api/admin/session/challenge", %{
          phone: "13900000001",
          phone_region: "86",
          password: "错的"
        })

      b =
        build_conn()
        |> post(~p"/api/admin/session/challenge", %{
          phone: "13900009999",
          phone_region: "86",
          password: "错的"
        })

      assert a.status == b.status
      assert a.resp_body == b.resp_body
    end
  end

  # 公开发码接口要是肯发 admin_login,不知道密码也能让管理员的手机响
  test "公开的发码接口不代发管理端验证码" do
    admin_fixture(%{phone: "13900000001", phone_region: "86"})

    for purpose <- Rice.Admin.code_purposes() do
      assert build_conn()
             |> post(~p"/api/verification_codes", %{
               channel: "sms",
               purpose: purpose,
               phone: "13900000001"
             })
             |> json_response(422)
    end

    refute Rice.Repo.get_by(VerificationCode, target: "86-13900000001")
  end

  # `challenge` 密码对了 202、错了 401 —— 这是一个可以无限次问的"密码对不对"。
  # 验证码那边一直有 5 次上限,密码这边原先一次都没数。
  describe "密码试错有上限" do
    @max Rice.Admin.LoginAttempt.max_attempts()

    defp fail_login(phone, times) do
      for _ <- 1..times do
        build_conn()
        |> post(~p"/api/admin/session/challenge", %{phone: phone, password: "猜错的"})
        |> json_response(401)
      end
    end

    test "连错到上限之后锁住,正确的密码也换不到验证码", %{conn: conn} do
      admin_fixture(%{phone: "13900000001", phone_region: "86", password: "admin-password"})
      fail_login("13900000001", @max)

      assert conn
             |> post(~p"/api/admin/session/challenge", %{
               phone: "13900000001",
               password: "admin-password"
             })
             |> json_response(429)
    end

    # 第二步要是不数,带着错验证码反复试密码就能绕开锁定:
    # 密码对时验证码会被试满报 429,密码错时一直是 401
    test "第二步试错也计数,锁住后正确的密码加验证码也换不到令牌", %{conn: conn} do
      admin_fixture(%{phone: "13900000001", phone_region: "86", password: "admin-password"})
      code = seed_code("86-13900000001", "admin_login")

      for _ <- 1..@max do
        build_conn()
        |> post(~p"/api/admin/session", %{phone: "13900000001", password: "猜错的", code: code})
        |> json_response(401)
      end

      assert conn
             |> post(~p"/api/admin/session", %{
               phone: "13900000001",
               password: "admin-password",
               code: code
             })
             |> json_response(429)
    end

    # 只给存在的管理员计数的话,第六次还返回 401 就等于告诉对方"这个号不是管理员" ——
    # 正好把"密码错和账号不存在返回同一个响应"这条设计抵消掉
    test "不存在的手机号一样会被锁", %{conn: conn} do
      fail_login("13900009999", @max)

      assert conn
             |> post(~p"/api/admin/session/challenge", %{
               phone: "13900009999",
               password: "再猜"
             })
             |> json_response(429)
    end

    test "密码对了就清零 —— 手滑几次不该攒着", %{conn: conn} do
      admin_fixture(%{phone: "13900000001", phone_region: "86", password: "admin-password"})
      expect(Rice.NotificationsMock, :send_sms, fn "86", "13900000001", _ -> :ok end)

      fail_login("13900000001", @max - 1)

      assert conn
             |> post(~p"/api/admin/session/challenge", %{
               phone: "13900000001",
               password: "admin-password"
             })
             |> response(202)

      refute Rice.Repo.get_by(Rice.Admin.LoginAttempt,
               phone_region: "86",
               phone: "13900000001"
             )
    end

    test "锁定到期之后能再试", %{conn: conn} do
      admin_fixture(%{phone: "13900000001", phone_region: "86", password: "admin-password"})
      expect(Rice.NotificationsMock, :send_sms, fn "86", "13900000001", _ -> :ok end)

      fail_login("13900000001", @max)

      # 这张表没有主键(键是手机号),所以用 update_all 而不是 update!
      Rice.Repo.update_all(
        from(a in Rice.Admin.LoginAttempt,
          where: a.phone_region == "86" and a.phone == "13900000001"
        ),
        set: [locked_until: DateTime.add(DateTime.utc_now(), -60)]
      )

      assert conn
             |> post(~p"/api/admin/session/challenge", %{
               phone: "13900000001",
               password: "admin-password"
             })
             |> response(202)
    end

    # 一个号被锁不该连累别人
    test "锁的是这个手机号,不是所有管理员", %{conn: conn} do
      admin_fixture(%{phone: "13900000001", phone_region: "86", password: "admin-password"})
      admin_fixture(%{phone: "13900003333", phone_region: "86", password: "another-password"})
      expect(Rice.NotificationsMock, :send_sms, fn "86", "13900003333", _ -> :ok end)

      fail_login("13900000001", @max)

      assert conn
             |> post(~p"/api/admin/session/challenge", %{
               phone: "13900003333",
               password: "another-password"
             })
             |> response(202)
    end
  end

  describe "会话" do
    test "登出后令牌立即失效", %{conn: conn} do
      {_admin, token} = admin_with_token()

      assert conn |> authed(token) |> delete(~p"/api/admin/session") |> response(204)
      assert build_conn() |> authed(token) |> get(~p"/api/admin/me") |> json_response(401)
    end

    test "未认证 401", %{conn: conn} do
      assert conn |> get(~p"/api/admin/me") |> json_response(401)
    end

    # 两套令牌互相换不过去
    test "C 端令牌不能当管理端令牌用", %{conn: conn} do
      {_user, user_token} = user_with_token()

      assert conn |> authed(user_token) |> get(~p"/api/admin/me") |> json_response(401)
    end

    test "管理端令牌不能当 C 端令牌用", %{conn: conn} do
      {_admin, admin_token} = admin_with_token()

      assert conn |> authed(admin_token) |> get(~p"/api/users/me") |> json_response(401)
    end
  end
end

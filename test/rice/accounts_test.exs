defmodule Rice.AccountsTest do
  use Rice.DataCase, async: true

  import Mox

  alias Rice.Accounts
  alias Rice.Accounts.{ApiToken, VerificationCode}

  setup :verify_on_exit!

  describe "唯一性约束 —— core 上没有的那些" do
    # core 的 t_user 上 email/phone 是 NOT NULL DEFAULT '' 且无唯一索引,
    # 并发注册同一手机号会双双通过。这几条锁住新行为。
    test "手机号不能重复" do
      user_fixture(%{phone: "13800000000", phone_region: "86"})

      assert {:error, changeset} =
               %Rice.Accounts.User{}
               |> Rice.Accounts.User.registration_changeset(%{
                 did: "did:plc:other",
                 handle: "other.test",
                 phone: "13800000000",
                 phone_region: "86"
               })
               |> Rice.Repo.insert()

      assert "该手机号已被使用" in errors_on(changeset).phone
    end

    test "邮箱不能重复,且大小写不敏感" do
      user_fixture(%{email: "a@example.com"})

      assert {:error, changeset} =
               %Rice.Accounts.User{}
               |> Rice.Accounts.User.registration_changeset(%{
                 did: "did:plc:other",
                 handle: "other.test",
                 email: "A@EXAMPLE.COM"
               })
               |> Rice.Repo.insert()

      assert "该邮箱已被使用" in errors_on(changeset).email
    end

    test "handle 不能重复,且大小写不敏感" do
      user_fixture(%{handle: "alice.web5.xjdao.test"})

      assert {:error, changeset} =
               %Rice.Accounts.User{}
               |> Rice.Accounts.User.registration_changeset(%{
                 did: "did:plc:other",
                 handle: "ALICE.web5.xjdao.test"
               })
               |> Rice.Repo.insert()

      assert errors_on(changeset).handle != []
    end

    # 生产数据里软删用户与存活用户之间有 handle / 手机号冲突,
    # 所以唯一索引必须带 `where deleted_at is null`。
    test "软删用户不占用 handle 和手机号" do
      user = user_fixture(%{handle: "taken.test", phone: "13900000000"})
      {:ok, _} = Accounts.delete_user(user)

      assert {:ok, _} =
               %Rice.Accounts.User{}
               |> Rice.Accounts.User.registration_changeset(%{
                 did: "did:plc:new",
                 handle: "taken.test",
                 phone: "13900000000"
               })
               |> Rice.Repo.insert()
    end

    test "空串的联系方式存成 NULL,可以有多行" do
      a = user_fixture(%{email: "", phone: ""})
      b = user_fixture(%{email: "  ", phone: nil})

      assert is_nil(a.email) and is_nil(a.phone)
      assert is_nil(b.email) and is_nil(b.phone)
    end

    test "余额不能为负 —— 数据库层约束" do
      user = user_fixture()

      assert_raise Ecto.ConstraintError, fn ->
        Rice.Repo.update!(Ecto.Changeset.change(user, grain_balance: -1))
      end
    end
  end

  describe "验证码" do
    test "发码走通道,库里只有哈希" do
      expect(Rice.NotificationsMock, :send_sms, fn "86", "13800000000", text ->
        assert text =~ ~r/验证码 \d{6}/
        :ok
      end)

      target = Accounts.phone_target("86", "13800000000")
      assert {:ok, record} = Accounts.send_verification_code("sms", target, "register")
      assert byte_size(record.code_hash) == 32
    end

    # core 完全没有发码频率限制,同一个号码可以被无限轰炸
    test "60 秒内跨用途、已消费仍不能重复发,期满可重发" do
      expect(Rice.NotificationsMock, :send_sms, 2, fn _, _, _ -> :ok end)
      target = Accounts.phone_target("86", "13800000000")

      assert {:ok, record} = Accounts.send_verification_code("sms", target, "register")
      assert Accounts.verification_retry_after("sms", target) in 59..60

      assert {:error, :too_many_requests} =
               Accounts.send_verification_code("sms", target, "register")

      record = Repo.update!(change(record, consumed_at: DateTime.utc_now()))

      assert {:error, :too_many_requests} =
               Accounts.send_verification_code("sms", target, "reset_password")

      Repo.update!(change(record, inserted_at: DateTime.add(DateTime.utc_now(), -61, :second)))
      assert Accounts.verification_retry_after("sms", target) == 0
      assert {:ok, _} = Accounts.send_verification_code("sms", target, "reset_password")
    end

    test "独立连接并发请求同一号码只发送一次" do
      supervisor = start_supervised!(Task.Supervisor)

      target =
        "86-#{System.unique_integer([:positive]) |> Integer.to_string() |> String.pad_leading(12, "0")}"

      parent = self()
      expect(Rice.NotificationsMock, :send_sms, fn _, _, _ -> :ok end)

      try do
        workers =
          for purpose <- ["register", "reset_password"] do
            task =
              Task.Supervisor.async_nolink(supervisor, fn ->
                Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
                  send(parent, {:ready, self()})

                  receive do
                    :run -> Accounts.send_verification_code("sms", target, purpose)
                  after
                    5_000 -> raise "concurrency test barrier timed out"
                  end
                end)
              end)

            allow(Rice.NotificationsMock, parent, task.pid)
            task
          end

        for _ <- workers, do: assert_receive({:ready, _}, 5_000)
        Enum.each(workers, &send(&1.pid, :run))
        results = Enum.map(workers, &Task.await(&1, 10_000))
        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        assert Enum.count(results, &(&1 == {:error, :too_many_requests})) == 1
      after
        Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
          Repo.delete_all(from c in VerificationCode, where: c.target == ^target)
        end)
      end
    end

    test "不同号码互不影响" do
      expect(Rice.NotificationsMock, :send_sms, 2, fn _, _, _ -> :ok end)

      assert {:ok, _} =
               Accounts.send_verification_code(
                 "sms",
                 Accounts.phone_target("86", "13800000001"),
                 "register"
               )

      assert {:ok, _} =
               Accounts.send_verification_code(
                 "sms",
                 Accounts.phone_target("86", "13800000002"),
                 "register"
               )
    end

    test "区号不同视为不同目标" do
      expect(Rice.NotificationsMock, :send_sms, 2, fn _, _, _ -> :ok end)

      assert {:ok, _} =
               Accounts.send_verification_code(
                 "sms",
                 Accounts.phone_target("86", "13800000000"),
                 "register"
               )

      assert {:ok, _} =
               Accounts.send_verification_code(
                 "sms",
                 Accounts.phone_target("1", "13800000000"),
                 "register"
               )
    end

    # phone_target("86", "") 会得到 "86-" —— 非空,但根本不是手机号。
    # 只判"非空"的话这里会一路走到真的去发短信。
    test "target 形状不对时不发送" do
      for bad <- [
            Accounts.phone_target("86", ""),
            "86-",
            "-13800000000",
            "abc",
            "86-abc",
            "",
            "13800000000"
          ] do
        assert {:error, :invalid_target} =
                 Accounts.send_verification_code("sms", bad, "register"),
               "不该接受 sms target #{inspect(bad)}"
      end

      for bad <- ["", "nope", "a@b", "@example.com", "a@example"] do
        assert {:error, :invalid_target} =
                 Accounts.send_verification_code("email", bad, "register"),
               "不该接受 email target #{inspect(bad)}"
      end
    end

    test "拒绝非法通道和用途" do
      assert {:error, :invalid_channel} =
               Accounts.send_verification_code("carrier", "x", "register")

      assert {:error, :invalid_purpose} = Accounts.send_verification_code("sms", "x", "hack")
      assert {:error, :invalid_target} = Accounts.send_verification_code("sms", "  ", "register")
    end

    test "校验成功后被消费,不能再用第二次" do
      code = seed_code("sms", "86-13800000000", "register")

      assert :ok = Accounts.verify_code("sms", "86-13800000000", "register", code)

      assert {:error, :invalid_code} =
               Accounts.verify_code("sms", "86-13800000000", "register", code)
    end

    # `verify_code/4` 是"先查出来、再写回去"。两个并发请求会同时读到**同一条**
    # 未消费的记录,都比对成功 —— 一个短信码触发两次发放。
    #
    # 顺序调用测不出这个:第二次查的时候 consumed_at 已经写上了。要重现,
    # 得让两个调用方各拿着一份**消费之前**的记录副本 —— 这正是并发时的样子。
    test "两个并发请求拿着同一条记录,只有一个能消费掉" do
      code = seed_code("sms", "86-13800000000", "register")

      # 两份"陈旧"的副本,都还是 consumed_at = nil
      a = Repo.one!(from c in VerificationCode, where: c.target == "86-13800000000")
      b = Repo.one!(from c in VerificationCode, where: c.target == "86-13800000000")

      assert is_nil(a.consumed_at) and is_nil(b.consumed_at)

      results = [Accounts.consume_code(a), Accounts.consume_code(b)]

      assert Enum.count(results, &(&1 == :ok)) == 1,
             "同一个码被消费了两次: #{inspect(results)}"

      assert {:error, :invalid_code} =
               Accounts.verify_code("sms", "86-13800000000", "register", code)
    end

    # 读-改-写的话,两次并发的错误尝试会双双把 4 写成 5,上限就形同虚设
    test "尝试次数是原子自增的" do
      seed_code("sms", "86-13800000000", "register")

      for _ <- 1..3 do
        assert {:error, :invalid_code} =
                 Accounts.verify_code("sms", "86-13800000000", "register", "000000")
      end

      record = Repo.one!(from c in VerificationCode, where: c.target == "86-13800000000")
      assert record.attempts == 3
    end

    # core 那边 6 位码可以无限次猜 —— 这里 5 次之后锁死
    test "尝试次数超过上限后锁死,即使之后给出正确的码" do
      code = seed_code("sms", "86-13800000000", "register")

      for _ <- 1..VerificationCode.max_attempts() do
        assert {:error, :invalid_code} =
                 Accounts.verify_code("sms", "86-13800000000", "register", "000000")
      end

      assert {:error, :too_many_attempts} =
               Accounts.verify_code("sms", "86-13800000000", "register", code)
    end

    test "过期的码不能用" do
      code = seed_code("sms", "86-13800000000", "register")

      Rice.Repo.update_all(Rice.Accounts.VerificationCode,
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert {:error, :code_expired} =
               Accounts.verify_code("sms", "86-13800000000", "register", code)
    end

    test "用途不匹配时无效 —— 注册码不能拿去重置密码" do
      code = seed_code("sms", "86-13800000000", "register")

      assert {:error, :invalid_code} =
               Accounts.verify_code("sms", "86-13800000000", "reset_password", code)
    end

    test "目标不匹配时无效" do
      code = seed_code("sms", "86-13800000000", "register")

      assert {:error, :invalid_code} =
               Accounts.verify_code("sms", "86-13900000000", "register", code)
    end

    test "生成的码是 6 位数字" do
      codes = for _ <- 1..200, do: VerificationCode.generate_code()
      assert Enum.all?(codes, &Regex.match?(~r/^\d{6}$/, &1))
      # 200 次里出现大量重复就说明随机性有问题
      assert length(Enum.uniq(codes)) > 150
    end
  end

  describe "令牌" do
    test "签发后可以换回用户" do
      {user, token} = user_with_token()
      assert Accounts.user_by_token(token).id == user.id
    end

    test "库里只有哈希,存不下明文" do
      {_user, token} = user_with_token()
      [record] = Rice.Repo.all(ApiToken)

      assert record.token_hash == ApiToken.hash(token)
      refute to_string(record.token_hash) =~ token
    end

    test "伪造的令牌换不到人" do
      for bad <- ["", "abc", String.duplicate("a", 43), nil, 42] do
        assert Accounts.user_by_token(bad) == nil
      end
    end

    test "过期的令牌无效" do
      {_user, token} = user_with_token()

      Rice.Repo.update_all(ApiToken,
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert Accounts.user_by_token(token) == nil
    end

    # 这正是换掉 daoJwt 的理由:JWT 签出去就收不回来,只能等 30 天过期
    test "撤销后立即失效" do
      {_user, token} = user_with_token()
      assert :ok = Accounts.revoke_token(token)
      assert Accounts.user_by_token(token) == nil
    end

    test "禁用用户后他手上的令牌立刻失效" do
      {user, token} = user_with_token()
      Rice.Repo.update!(Ecto.Changeset.change(user, disabled_at: DateTime.utc_now()))

      assert Accounts.user_by_token(token) == nil
    end

    test "软删用户后令牌失效" do
      {user, token} = user_with_token()
      {:ok, _} = Accounts.delete_user(user)

      assert Accounts.user_by_token(token) == nil
    end

    test "revoke_all_tokens 一次清干净" do
      user = user_fixture()
      {:ok, t1} = Accounts.issue_token(user)
      {:ok, t2} = Accounts.issue_token(user)

      assert {:ok, 2} = Accounts.revoke_all_tokens(user)
      assert Accounts.user_by_token(t1) == nil
      assert Accounts.user_by_token(t2) == nil
    end

    test "两次签发得到不同的令牌" do
      user = user_fixture()
      {:ok, a} = Accounts.issue_token(user)
      {:ok, b} = Accounts.issue_token(user)
      refute a == b
    end

    test "prune_expired 只删过期的" do
      {_u1, live} = user_with_token()
      {u2, _} = user_with_token()
      {:ok, _} = Accounts.issue_token(u2)

      Rice.Repo.update_all(
        Ecto.Query.from(t in ApiToken, where: t.user_id == ^u2.id),
        set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
      )

      assert %{tokens: 2} = Accounts.prune_expired()
      assert Accounts.user_by_token(live)
    end
  end

  describe "register/1" do
    test "在 PDS 建账号后建本地档案并发令牌" do
      expect(Rice.PDSMock, :email_domain, fn -> "web5.xjdao.test" end)

      expect(Rice.PDSMock, :create_account, fn %{handle: "alice.web5.xjdao.test"} = attrs ->
        assert attrs.email == "alice@web5.xjdao.test"
        assert attrs.password == "hunter2hunter2"

        {:ok,
         %{
           "did" => "did:plc:alice",
           "handle" => "alice.web5.xjdao.test",
           "accessJwt" => "acc",
           "refreshJwt" => "ref"
         }}
      end)

      expect(Rice.PDSMock, :put_profile, fn "acc", "did:plc:alice", %{"displayName" => "小禾"} ->
        {:ok, %{}}
      end)

      assert {:ok, %{user: user, token: token, pds_session: session}} =
               Accounts.register(%{
                 handle: "alice.web5.xjdao.test",
                 nickname: "小禾",
                 password: "hunter2hunter2",
                 phone: "13800000000",
                 phone_region: "86"
               })

      assert user.did == "did:plc:alice"
      assert user.phone == "13800000000"
      assert user.nickname == "小禾"
      assert session["accessJwt"] == "acc"
      assert Accounts.user_by_token(token).id == user.id
    end

    # 先查本地占用,免得 PDS 上留下一个用不上的孤儿账号
    test "手机号已被占用时根本不去建 PDS 账号" do
      user_fixture(%{phone: "13800000000", phone_region: "86"})

      assert {:error, :contact_taken} =
               Accounts.register(%{
                 handle: "bob.web5.xjdao.test",
                 password: "hunter2hunter2",
                 phone: "13800000000",
                 phone_region: "86"
               })
    end

    test "PDS 拒绝时如实返回错误" do
      expect(Rice.PDSMock, :email_domain, fn -> "web5.xjdao.test" end)

      expect(Rice.PDSMock, :create_account, fn _ ->
        {:error, {:pds, "createAccount", 400, "HandleNotAvailable"}}
      end)

      assert {:error, {:pds, _, 400, "HandleNotAvailable"}} =
               Accounts.register(%{handle: "taken.test", password: "hunter2hunter2"})

      assert Rice.Repo.aggregate(Rice.Accounts.User, :count) == 0
    end
  end

  describe "login/2" do
    setup do
      user =
        user_fixture(%{
          handle: "alice.web5.xjdao.test",
          email: "alice@example.com",
          phone: "13800000000"
        })

      %{user: user}
    end

    test "handle 登录", %{user: user} do
      expect(Rice.PDSMock, :create_session, fn "alice.web5.xjdao.test", "pw" ->
        {:ok,
         %{"did" => user.did, "handle" => user.handle, "accessJwt" => "a", "refreshJwt" => "r"}}
      end)

      assert {:ok, %{user: found, token: token}} = Accounts.login("alice.web5.xjdao.test", "pw")
      assert found.id == user.id
      assert Accounts.user_by_token(token)
    end

    test "邮箱和手机号也能登录,且大小写不敏感", %{user: user} do
      expect(Rice.PDSMock, :create_session, 3, fn handle, _ ->
        assert handle == user.handle
        {:ok, %{"did" => user.did, "handle" => user.handle, "accessJwt" => "a"}}
      end)

      for identifier <- ["alice@example.com", "ALICE@EXAMPLE.COM", "13800000000"] do
        assert {:ok, _} = Accounts.login(identifier, "pw")
      end
    end

    test "密码错误时 401 语义" do
      expect(Rice.PDSMock, :create_session, fn _, _ -> {:error, {:pds, "x", 401, "bad"}} end)
      assert {:error, :invalid_credentials} = Accounts.login("alice.web5.xjdao.test", "wrong")
    end

    # 账号不存在和密码错误必须不可区分,否则就是一个账号枚举接口。
    # 用户不存在时也走一次 PDS,让两条路径的耗时特征接近。
    test "账号不存在时同样是 invalid_credentials,并且也打了一次 PDS" do
      expect(Rice.PDSMock, :create_session, fn "nobody", "pw" ->
        {:error, {:pds, "createSession", 401, "AuthenticationRequired"}}
      end)

      assert {:error, :invalid_credentials} = Accounts.login("nobody", "pw")
    end

    test "PDS 网络或服务故障不会误报凭据错误", %{user: user} do
      for failure <- [
            {:error, {:transport, :timeout}},
            {:error, {:pds, "createSession", 503, "Unavailable"}}
          ],
          identifier <- [user.handle, "nobody"] do
        expect(Rice.PDSMock, :create_session, fn ^identifier, "pw" -> failure end)
        assert {:error, :login_unavailable} = Accounts.login(identifier, "pw")
      end
    end

    test "PDS 有账号但本地已不存在也不能签发令牌" do
      expect(Rice.PDSMock, :create_session, fn "nobody", "pw" -> {:ok, %{}} end)
      assert {:error, :invalid_credentials} = Accounts.login("nobody", "pw")
    end

    test "被禁用的账号登录被拒,且不去打 PDS", %{user: user} do
      Rice.Repo.update!(Ecto.Changeset.change(user, disabled_at: DateTime.utc_now()))
      assert {:error, :account_disabled} = Accounts.login("alice.web5.xjdao.test", "pw")
    end

    test "软删的账号视为不存在", %{user: user} do
      {:ok, _} = Accounts.delete_user(user)

      expect(Rice.PDSMock, :create_session, fn _, _ ->
        {:error, {:pds, "createSession", 401, "AuthenticationRequired"}}
      end)

      assert {:error, :invalid_credentials} = Accounts.login("alice.web5.xjdao.test", "pw")
    end
  end

  defp seed_code(channel, target, purpose) do
    code = VerificationCode.generate_code()
    Rice.Repo.insert!(VerificationCode.build(channel, target, purpose, code))
    code
  end
end

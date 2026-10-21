defmodule Rice.BridgeTest do
  @moduledoc """
  Semi 登录桥接。重点在**两件长期缺失的事**:

    * Semi 用户在 rice 里要有档案和令牌 —— C 端搬到 rice 之后,没有它
      `/api/*` 全是 401,用户能登录但一进业务页面就空白;
    * 钱包地址要落库 —— Semi 的 userinfo 一直在返回,以前只塞进 session cookie
      给调试首页看,从不持久化。
  """
  use Rice.DataCase, async: true

  import Mox

  alias Rice.{Accounts, Bridge}

  setup :verify_on_exit!

  # Semi 的 userinfo。`wallet_address` 只在 `wallet` scope 下出现。
  defp userinfo(attrs \\ %{}) do
    Enum.into(attrs, %{
      "sub" => "semi-sub-#{System.unique_integer([:positive])}",
      "handle" => "alice",
      "wallet_address" => "0x1111111111111111111111111111111111111111"
    })
  end

  defp session(did, handle) do
    %{
      "did" => did,
      "handle" => handle,
      "accessJwt" => "access-#{did}",
      "refreshJwt" => "refresh-#{did}"
    }
  end

  # 首次登录:建 PDS 账号 + 写档案(账号是新的,所以 profile 是 :missing)
  defp expect_provision(did, handle) do
    expect(Rice.PDSMock, :handle_domain, fn -> "web5.xjdao.test" end)
    expect(Rice.PDSMock, :email_domain, fn -> "web5.xjdao.test" end)
    expect(Rice.PDSMock, :create_account, fn _ -> {:ok, session(did, handle)} end)
    expect(Rice.PDSMock, :get_profile, fn _, _ -> :missing end)
    expect(Rice.PDSMock, :put_profile, fn _, _, _ -> {:ok, %{}} end)
  end

  describe "首次 Semi 登录" do
    test "建 semi_link,并把钱包地址一起存下来" do
      expect_provision("did:plc:alice", "alice.web5.xjdao.test")
      info = userinfo()

      assert {:ok, identity} = Bridge.session_for(info)
      assert identity.did == "did:plc:alice"

      link = Accounts.get_link_by_sub(info["sub"])
      assert link.did == "did:plc:alice"
      assert link.wallet_address == "0x1111111111111111111111111111111111111111"
    end

    test "在 rice 里建档并签发 rice 令牌" do
      expect_provision("did:plc:bob", "bob.web5.xjdao.test")

      assert {:ok, identity} = Bridge.session_for(userinfo(%{"handle" => "bob"}))

      # 这一条是整件事的关键:没有它,C 端所有 /api/* 都是 401。
      assert is_binary(identity.rice_token)

      user = Accounts.get_user_by_did("did:plc:bob")
      assert user.handle == "bob.web5.xjdao.test"
      assert user.nickname == "bob"

      # 令牌真的能换回这个用户
      assert %Accounts.User{id: id} = Accounts.user_by_token(identity.rice_token)
      assert id == user.id
    end

    test "取回来的当前用户带着钱包地址" do
      expect_provision("did:plc:carol", "carol.web5.xjdao.test")

      assert {:ok, identity} = Bridge.session_for(userinfo(%{"handle" => "carol"}))

      assert %{wallet_address: "0x1111111111111111111111111111111111111111"} =
               Accounts.user_by_token(identity.rice_token)
    end

    test "没授权 wallet scope 时钱包是 nil,不是空串" do
      expect_provision("did:plc:dan", "dan.web5.xjdao.test")
      info = userinfo(%{"handle" => "dan"}) |> Map.delete("wallet_address")

      assert {:ok, _} = Bridge.session_for(info)
      assert Accounts.get_link_by_sub(info["sub"]).wallet_address == nil
    end
  end

  describe "再次 Semi 登录" do
    setup do
      expect_provision("did:plc:erin", "erin.web5.xjdao.test")
      info = userinfo(%{"handle" => "erin"}) |> Map.delete("wallet_address")
      {:ok, _} = Bridge.session_for(info)

      # 回访走 createSession,不再建账号;profile 已经有了
      stub(Rice.PDSMock, :create_session, fn _, _ ->
        {:ok, session("did:plc:erin", "erin.web5.xjdao.test")}
      end)

      stub(Rice.PDSMock, :get_profile, fn _, _ -> {:ok, %{}} end)

      %{sub: info["sub"]}
    end

    # 用户可能是先用 Semi 注册、之后才在 Semi 那边绑的钱包 ——
    # 只在建链接时写一次的话,那批人永远看不到地址。
    test "补绑的钱包地址会在下次登录时补上", %{sub: sub} do
      assert Accounts.get_link_by_sub(sub).wallet_address == nil

      assert {:ok, _} =
               Bridge.session_for(%{
                 "sub" => sub,
                 "handle" => "erin",
                 "wallet_address" => "0x2222222222222222222222222222222222222222"
               })

      assert Accounts.get_link_by_sub(sub).wallet_address ==
               "0x2222222222222222222222222222222222222222"
    end

    test "不会重复建档,令牌每次新发", %{sub: sub} do
      before = Accounts.get_user_by_did("did:plc:erin")

      assert {:ok, identity} = Bridge.session_for(%{"sub" => sub, "handle" => "erin"})

      assert Accounts.get_user_by_did("did:plc:erin").id == before.id
      assert %Accounts.User{id: id} = Accounts.user_by_token(identity.rice_token)
      assert id == before.id
    end

    test "已经在 app 里改过的昵称不会被登录覆盖回 Semi handle", %{sub: sub} do
      user = Accounts.get_user_by_did("did:plc:erin")
      {:ok, _} = Accounts.update_profile(user, %{"nickname" => "我自己改的"})

      assert {:ok, _} = Bridge.session_for(%{"sub" => sub, "handle" => "erin"})
      assert Accounts.get_user_by_did("did:plc:erin").nickname == "我自己改的"
    end
  end

  describe "按已验证联系方式认领已有账号" do
    test "已验证邮箱对上已有用户时绑定该 DID,不新建 PDS 账号" do
      user = Rice.Fixtures.user_fixture(%{email: "same@example.com", nickname: "原来的名字"})

      expect(Rice.PDSMock, :email_domain, fn -> "web5.xjdao.test" end)
      expect(Rice.PDSMock, :update_account_password, fn did, password ->
        assert did == user.did
        assert is_binary(password) and password != ""
        :ok
      end)
      expect(Rice.PDSMock, :create_session, fn did, _ ->
        assert did == user.did
        {:ok, session(user.did, user.handle)}
      end)
      expect(Rice.PDSMock, :get_profile, fn _, _ -> {:ok, %{}} end)

      info =
        userinfo(%{
          "email" => "Same@example.com",
          "email_verified" => true,
          "handle" => "someone-else"
        })

      assert {:ok, identity} = Bridge.session_for(info)
      assert identity.did == user.did
      assert Accounts.get_link_by_sub(info["sub"]).did == user.did
      assert Accounts.get_user_by_did(user.did).nickname == "原来的名字"
      assert Accounts.get_user_by_did(user.did).id == user.id
    end

    test "已验证手机号同样认领" do
      user = Rice.Fixtures.user_fixture(%{phone: "13800138000", phone_region: "86"})

      did = user.did

      expect(Rice.PDSMock, :update_account_password, fn ^did, _ -> :ok end)
      expect(Rice.PDSMock, :create_session, fn ^did, _ ->
        {:ok, session(user.did, user.handle)}
      end)
      expect(Rice.PDSMock, :get_profile, fn _, _ -> {:ok, %{}} end)

      info = userinfo(%{"phone" => "+86 138-0013-8000", "phone_verified" => true})

      assert {:ok, identity} = Bridge.session_for(info)
      assert identity.did == user.did
    end

    test "邮箱未验证、或只是 PDS 自己的邮箱时仍然新建账号" do
      Rice.Fixtures.user_fixture(%{email: "same@example.com"})
      Rice.Fixtures.user_fixture(%{email: "local@web5.xjdao.test"})

      expect_provision("did:plc:fresh", "fresh.web5.xjdao.test")

      info =
        userinfo(%{
          "handle" => "fresh",
          "email" => "same@example.com",
          "email_verified" => false
        })

      assert {:ok, %{did: "did:plc:fresh"}} = Bridge.session_for(info)

      expect_provision("did:plc:mbox", "mbox.web5.xjdao.test")
      expect(Rice.PDSMock, :email_domain, fn -> "web5.xjdao.test" end)

      assert {:ok, %{did: "did:plc:mbox"}} =
               Bridge.session_for(
                 userinfo(%{
                   "handle" => "mbox",
                   "email" => "local@web5.xjdao.test",
                   "email_verified" => true
                 })
               )
    end

    test "邮箱和手机号指向不同的人时不认领" do
      Rice.Fixtures.user_fixture(%{email: "a@example.com"})
      Rice.Fixtures.user_fixture(%{phone: "13800138000", phone_region: "86"})
      expect_provision("did:plc:split", "split.web5.xjdao.test")
      expect(Rice.PDSMock, :email_domain, fn -> "web5.xjdao.test" end)

      assert {:ok, %{did: "did:plc:split"}} =
               Bridge.session_for(
                 userinfo(%{
                   "handle" => "split",
                   "email" => "a@example.com",
                   "email_verified" => true,
                   "phone" => "13800138000",
                   "phone_verified" => true
                 })
               )
    end

    test "目标账号已经绑了别的 Semi 时不抢走" do
      user = Rice.Fixtures.user_fixture(%{email: "taken@example.com"})
      assert {:ok, _} =
               Accounts.create_link(%{
                 semi_sub: "other-sub",
                 did: user.did,
                 handle: user.handle,
                 account_password_ciphertext: Rice.Vault.encrypt("secret")
               })

      expect_provision("did:plc:other", "other.web5.xjdao.test")
      expect(Rice.PDSMock, :email_domain, fn -> "web5.xjdao.test" end)

      assert {:ok, %{did: "did:plc:other"}} =
               Bridge.session_for(
                 userinfo(%{
                   "handle" => "other",
                   "email" => "taken@example.com",
                   "email_verified" => true
                 })
               )

      assert Accounts.get_link_by_did(user.did).semi_sub == "other-sub"
    end
  end
end

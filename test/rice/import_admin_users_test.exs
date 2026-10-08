defmodule Rice.Import.AdminUsersTest do
  @moduledoc """
  `t_admin_user` → `admin_users` 的映射。

  测的是 `build/1` 这一层加上真正的 `Repo.insert` —— 不打 MySQL 的桩,直接喂
  一行和 core 形状一致的 map 进去。要盯住的是三件在对账数字上完全看不出来的事:
  搬过来的密码还验不验得过、脏行有没有被拦下、跳过的有没有留下痕迹。
  """
  use Rice.DataCase, async: true

  alias Rice.Admin.AdminUser
  alias Rice.Import.AdminUsers

  # core 的 PasswordHashGenerator:PBKDF2-HMAC-SHA256、27500 轮、64 字节、Base64。
  # 这里按同样的方式造一份摘要,模拟"库里已经有的那一行"。
  defp core_secret(password) do
    salt = :crypto.strong_rand_bytes(16) |> Base.encode64()

    value =
      :crypto.pbkdf2_hmac(:sha256, password, Base.decode64!(salt), 27_500, 64) |> Base.encode64()

    %{"Value" => value, "Salt" => salt}
  end

  defp row(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    Enum.into(attrs, %{
      "id" => "00000000-0000-0000-0000-#{String.pad_leading(to_string(n), 12, "0")}",
      "email" => "admin#{n}@example.com",
      "phone" => "138#{String.pad_leading(to_string(rem(n, 100_000_000)), 8, "0")}",
      "phone_region" => "86",
      "avatar" => "",
      "role" => 1,
      "special" => 0,
      "secret_data" => Jason.encode!(core_secret("core-password")),
      "created_at" => ~N[2024-03-04 05:06:07],
      "updated_at" => ~N[2025-01-02 03:04:05]
    })
  end

  defp import!(attrs \\ %{}) do
    assert {:ok, changeset} = AdminUsers.build(row(attrs))
    Repo.insert!(changeset)
  end

  describe "密码" do
    # 这是这张表非导不可的原因:重建账号等于所有管理员一起换密码,
    # 而管理端没有自助改密的入口
    test "core 的摘要搬过来之后,原密码还能验得过" do
      admin = import!()

      assert AdminUser.valid_password?(admin, "core-password")
      refute AdminUser.valid_password?(admin, "core-passwore")
    end

    test "驱动把 json 列解成 map 时也认" do
      admin = import!(%{"secret_data" => core_secret("core-password")})
      assert AdminUser.valid_password?(admin, "core-password")
    end

    # EF 序列化这一列的键名大小写取决于运行时的 JSON 策略。认错了的表现是
    # 所有人都登不进去,而导入这边行数对得上、一条警告都没有
    test "键名是小写时也认" do
      %{"Value" => v, "Salt" => s} = core_secret("core-password")
      admin = import!(%{"secret_data" => Jason.encode!(%{"value" => v, "salt" => s})})

      assert AdminUser.valid_password?(admin, "core-password")
    end

    test "迭代次数记在行上,和 core 一致" do
      assert import!().password_iterations == 27_500
    end
  end

  describe "跳过而不是写进去" do
    # 没有手机号在 rice 里就登不进来也找不回密码,库上还有 CHECK 拦着
    test "没有手机号" do
      assert {:skip, message} = AdminUsers.build(row(%{"phone" => ""}))
      assert message =~ "手机号"

      assert {:skip, _} = AdminUsers.build(row(%{"phone" => "   "}))
    end

    # core 的 RoleType.Unknown = 0,没初始化的脏值。
    # 默认成 operator 等于凭空发一份后台权限出去
    test "role=0(core 的 Unknown)" do
      assert {:skip, message} = AdminUsers.build(row(%{"role" => 0}))
      assert message =~ "Unknown"

      assert {:skip, _} = AdminUsers.build(row(%{"role" => 7}))
    end

    test "摘要缺一半、是空串、或者根本不是 json" do
      for secret <- [
            Jason.encode!(%{"Value" => "abc"}),
            Jason.encode!(%{"Value" => "", "Salt" => ""}),
            "not json at all",
            nil
          ] do
        assert {:skip, message} = AdminUsers.build(row(%{"secret_data" => secret}))
        assert message =~ "secret_data"
      end
    end

    # 盐不是合法 Base64 时 :crypto 会抛 ArgumentError,而 valid_password?/2
    # 把它 rescue 成"密码不对" —— 这种行写进去只会在当事人登录时才暴露
    test "盐不是合法 Base64" do
      secret = Jason.encode!(%{"Value" => "irrelevant", "Salt" => "not base64!!"})
      assert {:skip, message} = AdminUsers.build(row(%{"secret_data" => secret}))
      assert message =~ "secret_data"
    end
  end

  describe "逐列映射" do
    test "role 1/2 对上 admin/operator,special 对上 superuser" do
      assert import!(%{"role" => 1, "special" => 1}).role == "admin"
      assert import!(%{"role" => 2}).role == "operator"
      assert import!(%{"special" => 1}).superuser
      refute import!(%{"special" => 0}).superuser
    end

    # core 的这几列 NOT NULL DEFAULT ''。空串原样搬进来会占住部分唯一索引,
    # 第二个没填邮箱的管理员就插不进去了
    test "空字符串变 null,不是空串" do
      admin = import!(%{"email" => ""})
      assert admin.email == nil

      # 两个都没邮箱的管理员能共存
      assert import!(%{"email" => ""})
    end

    test "区号空着时退回 86" do
      assert import!(%{"phone_region" => ""}).phone_region == "86"
      assert import!(%{"phone_region" => "1"}).phone_region == "1"
    end

    # 后台列表显示创建时间,重置成导入那天等于把这列信息抹掉
    test "创建/更新时间照搬,不是导入时刻" do
      admin = import!()

      assert DateTime.to_date(admin.inserted_at) == ~D[2024-03-04]
      assert DateTime.to_date(admin.updated_at) == ~D[2025-01-02]
    end

    test "legacy_id 记的是 core 的 guid" do
      row = row()
      assert {:ok, changeset} = AdminUsers.build(row)
      assert Repo.insert!(changeset).legacy_id == row["id"]
    end

    test "core 没有昵称这一列,留空" do
      assert import!().nickname == ""
    end
  end

  describe "幂等" do
    # "提前预导 → 切换日只跑增量" 靠的就是这个
  end

  describe "格式不对的行进警告,不进库" do
    # 生产里真有一行的 phone 是 `AliyunDMSLoginConsoleAccess`(从阿里云 DMS
    # 控制台写进去的)。交给 changeset 去拦也拦得住,但报出来是一个光秃秃的
    # `[phone: {"手机号格式不正确", …}]`,看不出是哪个管理员 —— 所以提前拦,
    # 把值和原因都写进警告里
    test "手机号根本不是号码时,跳过并点名" do
      for bad <- ["+8613800000000", "AliyunDMSLoginConsoleAccess", "138-0000-0000"] do
        assert {:skip, message} = AdminUsers.build(row(%{"phone" => bad}))
        assert message =~ bad
        assert message =~ "收不到验证码"
      end
    end

    test "邮箱不是邮箱" do
      assert {:ok, changeset} = AdminUsers.build(row(%{"email" => "不是邮箱"}))
      refute changeset.valid?
      assert %{email: ["邮箱格式不正确"]} = errors_on(changeset)
    end
  end
end

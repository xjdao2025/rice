defmodule Rice.Admin.AdminUser do
  @moduledoc """
  管理员。和 C 端的 `Rice.Accounts.User` 完全分开 —— 管理员没有 DID,
  不在 PDS 上,密码由 rice 自己保管。

  ## 密码摘要

  PBKDF2-HMAC-SHA256,和 core 的 `PasswordHashGenerator` **逐字节兼容**
  (27500 轮、64 字节输出、Base64),这样迁数据时不必强制所有人改密码。

  只有一处刻意不照抄:core 用 `Random.Shared` 生成盐,那不是密码学安全的
  随机源。这里用 `:crypto.strong_rand_bytes/1`。老密码照样验得过 ——
  验证不关心盐当初是怎么生成的。

  ## 手机号是必填的

  登录和找回密码都只认手机号(`Rice.Admin.start_login/3`、`reset_password/4`)。
  邮箱只是联系方式,没有对应的登录入口。所以这里不能只填邮箱 ——
  那样建出来的账号能存进库,却既登不进去也找不回密码。
  """
  use Rice.Schema

  @roles ~w(admin operator)
  @iterations 27_500
  @key_bytes 64
  @salt_bytes 16

  schema "admin_users" do
    field :legacy_id, :string
    field :email, :string
    field :phone, :string
    field :phone_region, :string, default: "86"
    field :nickname, :string, default: ""
    field :role, :string, default: "operator"
    field :superuser, :boolean, default: false
    field :password_hash, :string
    field :password_salt, :string
    field :password_iterations, :integer, default: @iterations
    field :deleted_at, :utc_datetime_usec
    field :disabled_at, :utc_datetime_usec
    field :last_login_at, :utc_datetime_usec

    field :password, :string, virtual: true, redact: true

    belongs_to :avatar, Rice.Files.Attachment

    timestamps()
  end

  def changeset(admin, attrs) do
    admin
    |> cast(attrs, [:email, :phone, :phone_region, :nickname, :role, :avatar_id, :password])
    |> validate_inclusion(:role, @roles, message: "只能是 admin 或 operator")
    |> validate_length(:nickname, max: 64)
    |> validate_format(:email, ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, message: "邮箱格式不正确")
    |> validate_format(:phone, ~r/^\d{5,20}$/, message: "手机号格式不正确")
    |> validate_required([:phone], message: "必须填手机号")
    |> put_password()
    |> unique_constraint(:email, name: :admin_users_email_index)
    |> unique_constraint([:phone_region, :phone], name: :admin_users_phone_index)
    |> foreign_key_constraint(:avatar_id)
  end

  @doc "只改档案,动不了角色和密码 —— 那两样各有各的入口。"
  def profile_changeset(admin, attrs) do
    admin
    |> cast(attrs, [:nickname, :avatar_id])
    |> validate_length(:nickname, max: 64)
    |> foreign_key_constraint(:avatar_id)
  end

  def password_changeset(admin, password) do
    admin |> change(password: password) |> put_password()
  end

  defp put_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password when byte_size(password) < 8 ->
        add_error(changeset, :password, "密码至少 8 位")

      password ->
        salt = :crypto.strong_rand_bytes(@salt_bytes) |> Base.encode64()

        changeset
        |> put_change(:password_salt, salt)
        |> put_change(:password_hash, hash(password, salt, @iterations))
        |> put_change(:password_iterations, @iterations)
        |> delete_change(:password)
    end
  end

  @doc "算摘要。导出是为了能对着 core 的实现做交叉验证。"
  def hash(password, salt, iterations \\ @iterations) do
    :crypto.pbkdf2_hmac(:sha256, password, Base.decode64!(salt), iterations, @key_bytes)
    |> Base.encode64()
  end

  @doc """
  验证密码。用 `:crypto.hash_equals/2` 定长比较 —— 普通的 `==` 会在第一个
  不同的字节就返回,时间差能被用来一位一位地猜出摘要。
  """
  def valid_password?(%__MODULE__{password_hash: h, password_salt: s, password_iterations: i}, pw)
      when is_binary(h) and is_binary(s) and is_binary(pw) do
    :crypto.hash_equals(hash(pw, s, i), h)
  rescue
    # 盐不是合法 Base64(脏数据)时当成验证失败,而不是 500
    ArgumentError -> false
  end

  def valid_password?(_, _) do
    # 没有摘要也要走一遍同样耗时的运算,否则"这个账号存不存在"能从响应时间读出来
    dummy_verify()
    false
  end

  defp dummy_verify do
    hash("no-such-password", Base.encode64(<<0::128>>), @iterations)
    false
  end

  def iterations, do: @iterations
end

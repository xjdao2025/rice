defmodule Rice.Admin do
  @moduledoc """
  管理端。身份、鉴权,以及那些只有管理员能做的操作。

  ## 登录为什么是两步

  core 的流程是:`login-with-password` 只回一个 bool,前端再自己调**公开的**
  `/sms/send` 要验证码,最后 `login-with-verification-code` 换令牌。
  那个公开的发码接口意味着**不知道密码也能让管理员的手机响** ——
  这里把前两步合成一个:密码对了才发码。
  """
  import Ecto.Query

  alias Rice.Admin.{AdminToken, AdminUser, LoginAttempt}
  alias Rice.{Pagination, Repo}

  @code_purpose "admin_login"
  @reset_purpose "admin_reset_password"
  @grant_purpose "admin_grant"

  # ── 身份 ────────────────────────────────────────────────────────────────

  def get_admin(id) do
    if Rice.Tsid.valid?(id),
      do: Repo.one(from a in active(), where: a.id == ^id, preload: [:avatar])
  end

  def list_admins(params \\ %{}) do
    from(a in active(), preload: [:avatar])
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  @doc """
  新建管理员。返回 `{:ok, admin, 初始密码}` —— 初始密码只在这一刻可见,
  库里只有摘要。core 也是这个做法。
  """
  def create_admin(attrs) do
    password = generate_password()

    changeset =
      %AdminUser{}
      |> AdminUser.changeset(Map.put(normalize(attrs), "password", password))

    case Repo.insert(changeset) do
      {:ok, admin} -> {:ok, Repo.preload(admin, :avatar), password}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "软删。超管删不掉,自己也删不掉自己。"
  def delete_admin(%AdminUser{} = actor, %AdminUser{} = target) do
    cond do
      target.superuser -> {:error, :cannot_delete_superuser}
      target.id == actor.id -> {:error, :cannot_delete_self}
      true -> do_delete_admin(target)
    end
  end

  defp do_delete_admin(target) do
    Ecto.Multi.new()
    |> Ecto.Multi.update(:admin, Ecto.Changeset.change(target, deleted_at: DateTime.utc_now()))
    |> Ecto.Multi.delete_all(
      :tokens,
      from(t in AdminToken, where: t.admin_user_id == ^target.id)
    )
    |> Repo.transaction()
    |> case do
      {:ok, %{admin: admin}} -> {:ok, admin}
      {:error, _, reason, _} -> {:error, reason}
    end
  end

  def update_profile(%AdminUser{} = admin, attrs) do
    admin
    |> AdminUser.profile_changeset(normalize(attrs))
    |> Repo.update()
    |> case do
      {:ok, admin} -> {:ok, Repo.preload(admin, :avatar, force: true)}
      other -> other
    end
  end

  # ── 登录 ────────────────────────────────────────────────────────────────

  @doc """
  第一步:验密码,对了就发登录验证码。

  密码错、账号不存在、账号被停用返回的都是同一个 `:invalid_credentials` ——
  区分开就是一个"这个手机号是不是管理员"的探测器。

  连错 `LoginAttempt.max_attempts/0` 次之后锁一段时间,返回 `:too_many_attempts`。
  验证码那边一直有 5 次上限,密码这边原先一次都没数 —— 而这个接口的
  202/401 正好是一个可以无限问的"密码对不对"。
  """
  def start_login(region, phone, password) do
    with {:ok, _admin} <- check_password(region, phone, password) do
      Rice.Accounts.send_verification_code(
        "sms",
        Rice.Accounts.phone_target(region, phone),
        @code_purpose
      )
    end
  end

  # 两步登录都要过这一关 —— 第二步要是不数失败次数,带着错验证码反复试密码
  # 就绕开了锁定。
  defp check_password(region, phone, password) do
    now = DateTime.utc_now()
    attempt = get_login_attempt(region, phone)
    admin = get_admin_by_phone(region, phone)

    cond do
      LoginAttempt.locked?(attempt, now) ->
        {:error, :too_many_attempts}

      AdminUser.valid_password?(admin || %AdminUser{}, password) and enabled?(admin) ->
        clear_login_attempts(region, phone)
        {:ok, admin}

      true ->
        record_login_failure(region, phone, attempt, now)
        {:error, :invalid_credentials}
    end
  end

  defp get_login_attempt(region, phone) when is_binary(region) and is_binary(phone) do
    Repo.get_by(LoginAttempt, phone_region: region, phone: phone)
  end

  defp get_login_attempt(_, _), do: nil

  # 存不存在这个管理员都记 —— 只给存在的记的话,第六次还返回 401 就等于
  # 告诉对方"这个号不是管理员"
  defp record_login_failure(region, phone, attempt, now)
       when is_binary(region) and is_binary(phone) do
    attempts = ((attempt && attempt.attempts) || 0) + 1

    locked_until =
      if attempts >= LoginAttempt.max_attempts(),
        do: DateTime.add(now, LoginAttempt.lock_minutes() * 60, :second)

    %LoginAttempt{}
    |> LoginAttempt.changeset(%{
      phone_region: region,
      phone: phone,
      attempts: attempts,
      locked_until: locked_until
    })
    |> Repo.insert(
      on_conflict: [set: [attempts: attempts, locked_until: locked_until, updated_at: now]],
      conflict_target: [:phone_region, :phone]
    )
  end

  defp record_login_failure(_, _, _, _), do: :ok

  defp clear_login_attempts(region, phone) do
    Repo.delete_all(
      from a in LoginAttempt, where: a.phone_region == ^region and a.phone == ^phone
    )
  end

  @doc "第二步:密码 + 验证码换令牌。密码要再验一次 —— 只有验证码不够。"
  def login(region, phone, password, code) do
    target = Rice.Accounts.phone_target(region, phone)

    with {:ok, admin} <- check_password(region, phone, password),
         :ok <- Rice.Accounts.verify_code("sms", target, @code_purpose, code),
         {:ok, token} <- issue_token(admin) do
      Repo.update!(Ecto.Changeset.change(admin, last_login_at: DateTime.utc_now()))
      {:ok, Repo.preload(admin, :avatar), token}
    end
  end

  def issue_token(%AdminUser{} = admin, opts \\ []) do
    {plaintext, changeset} = AdminToken.build(admin, opts)

    case Repo.insert(changeset) do
      {:ok, _} -> {:ok, plaintext}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "用明文令牌换管理员。过期、被撤销、被停用、被删都返回 nil。"
  def admin_by_token(plaintext) when is_binary(plaintext) do
    hash = AdminToken.hash(plaintext)
    now = DateTime.utc_now()

    query =
      from t in AdminToken,
        join: a in assoc(t, :admin_user),
        where: t.token_hash == ^hash and t.expires_at > ^now,
        where: is_nil(a.deleted_at) and is_nil(a.disabled_at),
        select: a

    case Repo.one(query) do
      nil ->
        nil

      admin ->
        Repo.update_all(from(t in AdminToken, where: t.token_hash == ^hash),
          set: [last_used_at: now]
        )

        Repo.preload(admin, :avatar)
    end
  end

  def admin_by_token(_), do: nil

  def revoke_token(plaintext) when is_binary(plaintext) do
    hash = AdminToken.hash(plaintext)
    {count, _} = Repo.delete_all(from t in AdminToken, where: t.token_hash == ^hash)
    if count > 0, do: :ok, else: {:error, :not_found}
  end

  def revoke_all_tokens(%AdminUser{id: id}) do
    {count, _} = Repo.delete_all(from t in AdminToken, where: t.admin_user_id == ^id)
    {:ok, count}
  end

  @doc "凭手机验证码重置管理员密码。成功后踢掉该管理员的全部会话。"
  def reset_password(region, phone, code, new_password) do
    target = Rice.Accounts.phone_target(region, phone)

    with :ok <- Rice.Accounts.verify_code("sms", target, @reset_purpose, code),
         %AdminUser{} = admin <- get_admin_by_phone(region, phone),
         {:ok, admin} <- admin |> AdminUser.password_changeset(new_password) |> Repo.update() do
      {:ok, _} = revoke_all_tokens(admin)
      {:ok, admin}
    else
      nil -> {:error, :invalid_code}
      other -> other
    end
  end

  def send_reset_code(region, phone) do
    # 手机号不是管理员时也返回 :ok,不泄露"这个号是不是管理员"
    if get_admin_by_phone(region, phone) do
      Rice.Accounts.send_verification_code(
        "sms",
        Rice.Accounts.phone_target(region, phone),
        @reset_purpose
      )
    else
      {:ok, :sent}
    end
  end

  # ── 发放稻米的二次验证 ──────────────────────────────────────────────────

  @doc """
  给当前管理员自己的手机发一个发放验证码。

  发稻米是动钱的操作,core 要求管理员在发之前用短信验证码再证明一次身份
  (`AdminUserScoreDistribution`)。令牌可能被人从浏览器里捞走,短信在管理员
  自己手上 —— 两者同时到手才发得出去。这一层照搬过来。
  """
  def send_grant_code(%AdminUser{phone: phone, phone_region: region})
      when is_binary(phone) do
    Rice.Accounts.send_verification_code(
      "sms",
      Rice.Accounts.phone_target(region, phone),
      @grant_purpose
    )
  end

  def send_grant_code(_), do: {:error, :contact_not_set}

  @doc "校验发放验证码。发给谁就验谁 —— 不能拿别人手机上的码来发。"
  def verify_grant_code(%AdminUser{phone: phone, phone_region: region}, code)
      when is_binary(phone) do
    Rice.Accounts.verify_code(
      "sms",
      Rice.Accounts.phone_target(region, phone),
      @grant_purpose,
      code || ""
    )
  end

  def verify_grant_code(_, _), do: {:error, :contact_not_set}

  def code_purposes, do: [@code_purpose, @reset_purpose, @grant_purpose]

  # ── 内部 ────────────────────────────────────────────────────────────────

  defp get_admin_by_phone(region, phone) when is_binary(region) and is_binary(phone) do
    Repo.one(from a in active(), where: a.phone == ^phone and a.phone_region == ^region)
  end

  defp get_admin_by_phone(_, _), do: nil

  defp enabled?(%AdminUser{disabled_at: nil}), do: true
  defp enabled?(_), do: false

  defp active, do: from(a in AdminUser, where: is_nil(a.deleted_at))

  # 12 位,去掉了容易看错的 0/O/1/l/I —— 这串要靠人念给同事听。
  # 随机源用 :crypto,不用 Enum.random(:rand 不是密码学安全的)。
  @password_alphabet "23456789ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz"
  defp generate_password do
    for <<byte <- :crypto.strong_rand_bytes(12)>>, into: "" do
      binary_part(@password_alphabet, rem(byte, byte_size(@password_alphabet)), 1)
    end
  end

  defp normalize(attrs) do
    Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
  end
end

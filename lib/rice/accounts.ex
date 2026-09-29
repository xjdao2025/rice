defmodule Rice.Accounts do
  @moduledoc """
  身份:用户档案、访问令牌、验证码。

  密码不在这里 —— PDS 是密码权威,登录就是 `com.atproto.server.createSession`。
  """
  import Ecto.Query
  require Logger

  alias Ecto.Multi
  alias Rice.Accounts.{ApiToken, SemiLink, User, VerificationCode}
  alias Rice.{Notifications, Pagination, Repo}

  defp pds, do: Rice.PDS.Api.impl()

  # ── Semi ↔ PDS 账号映射 ─────────────────────────────────────────────────
  #
  # Semi 登录链路(Rice.Bridge)在用,生产已跑。期 3 不动它 ——
  # 等 users 表接管身份之后再考虑把 semi_links 并进来。

  def get_link_by_sub(sub) when is_binary(sub), do: Repo.get_by(SemiLink, semi_sub: sub)

  def get_link_by_did(did) when is_binary(did), do: Repo.get_by(SemiLink, did: did)
  def get_link_by_did(_), do: nil

  def create_link(attrs) do
    %SemiLink{}
    |> SemiLink.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  刷新链接上的钱包地址。**每次 Semi 登录都调** —— 用户可能是先用 Semi 注册、
  之后才在 Semi 那边绑的钱包,只在建链接时写一次的话那些人永远看不到地址。

  值没变就不写,避免每次登录都产生一次 UPDATE。
  """
  def update_link_wallet(%SemiLink{} = link, wallet_address) do
    wallet = normalize_wallet(wallet_address)

    if wallet == link.wallet_address do
      {:ok, link}
    else
      link |> SemiLink.changeset(%{wallet_address: wallet}) |> Repo.update()
    end
  end

  defp normalize_wallet(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_wallet(_), do: nil

  @doc """
  给一个 did 找到 rice 档案,没有就建一个。Semi 登录链路用。

  Semi 用户的身份权威在 PDS(`Rice.Bridge` 建的账号),但 C 端整套业务接口都以
  rice 的 `users` 行为准 —— 没有这一行,`/api/*` 全是 401,提案、评论、稻米余额
  一个都用不了。所以桥接完 PDS 之后必须在这里落一行。

  已存在就原样返回(**不覆盖**昵称等字段:用户可能已经在 app 里改过)。

  软删的用户不算数 —— `get_user_by_did/1` 只看活着的行,而两个唯一索引都带
  `where deleted_at is null`,所以注销过的人再用 Semi 登录会得到一份新档案,
  而不是把注销掉的那份挖出来。
  """
  def ensure_user_for_did(%{did: did, handle: handle} = identity) do
    case get_user_by_did(did) do
      %User{} = user ->
        {:ok, user}

      nil ->
        attrs = %{
          did: did,
          handle: handle,
          nickname: Map.get(identity, :nickname) || default_nickname(handle)
        }

        %User{} |> User.registration_changeset(attrs) |> Repo.insert()
    end
  end

  # ── 查询 ────────────────────────────────────────────────────────────────

  def get_user(id) do
    if Rice.Tsid.valid?(id) do
      Repo.one(from u in active_users(), where: u.id == ^id, preload: [:avatar])
    end
  end

  def get_user_by_did(did), do: Repo.one(from u in active_users(), where: u.did == ^did)

  @doc """
  按 core 的 `t_user.id` 找人 —— 只有老 daoJwt 的兜底认证会用到(它的 `uid`
  claim 就是这个值)。禁用的人不返回,和 `user_by_token/1` 一致。
  """
  def get_user_by_legacy_id(legacy_id) when is_binary(legacy_id) and legacy_id != "" do
    Repo.one(
      from u in active_users(),
        where: u.legacy_id == ^legacy_id and is_nil(u.disabled_at),
        preload: [:avatar]
    )
    |> put_semi_wallet()
  end

  def get_user_by_legacy_id(_), do: nil

  @doc "按 handle / 邮箱 / 手机号找人 —— 登录时用。"
  def get_user_by_identifier(identifier) when is_binary(identifier) do
    normalized = String.downcase(String.trim(identifier))

    Repo.one(
      from u in active_users(),
        where:
          fragment("lower(?)", u.handle) == ^normalized or
            fragment("lower(?)", u.email) == ^normalized or
            u.phone == ^normalized,
        limit: 1
    )
  end

  def get_user_by_identifier(_), do: nil

  @doc """
  按公开标识找人:rice id / DID / handle。

  刻意**不认邮箱和手机号** —— `get_user_by_identifier/1` 认,那是登录用的。
  公开接口上认联系方式就等于送了一个"这个邮箱注册过没有"的探测器。
  """
  def get_public_user(identifier) when is_binary(identifier) do
    identifier = String.trim(identifier)

    get_user(identifier) || get_user_by_did(identifier) ||
      Repo.one(
        from u in active_users(),
          where: fragment("lower(?)", u.handle) == ^String.downcase(identifier),
          preload: [:avatar]
      )
  end

  def get_public_user(_), do: nil

  @doc "按昵称或 handle 搜索公开档案；不查询联系方式，也不列出停用或已注销账号。"
  def search_public_users(params) do
    q = params["q"]
    q = if is_binary(q), do: String.trim(q), else: ""

    if String.length(q) in 1..256 do
      pattern = "%" <> String.replace(q, ["\\", "%", "_"], &"\\#{&1}") <> "%"

      from(u in enabled_users(),
        where: ilike(u.nickname, ^pattern) or ilike(u.handle, ^pattern),
        preload: [:avatar]
      )
      |> Pagination.paginate(Repo, Pagination.params(Map.take(params, ["limit", "before"])))
    else
      %{entries: [], next_cursor: nil}
    end
  end

  @doc """
  后台按运营输入的任意写法找人:rice id / DID / handle / 邮箱 / 手机号。

  只给**后台**用 —— 它认联系方式,放在公开接口上就是一个"这个手机号注册过没有"
  的探测器(所以 `get_public_user/1` 不认)。

  停用和已注销的都找不到。发勋章、发稻米都用这个:早先发稻米那边是
  `get_public_user/1` 兜底再查联系方式,结果按手机号找不到停用的用户、
  按 DID 却找得到,同一个人两种写法两个结果。
  """
  def find_user(identifier) when is_binary(identifier) do
    identifier = String.trim(identifier)

    enabled(get_public_user(identifier)) || find_by_contact(identifier)
  end

  def find_user(_), do: nil

  defp enabled(%User{disabled_at: nil} = user), do: user
  defp enabled(_), do: nil

  defp find_by_contact(identifier) do
    cond do
      String.contains?(identifier, "@") ->
        Repo.one(
          from u in enabled_users(),
            where: fragment("lower(?)", u.email) == ^String.downcase(identifier),
            preload: [:avatar]
        )

      Regex.match?(~r/^\d{5,20}$/, identifier) ->
        Repo.one(from u in enabled_users(), where: u.phone == ^identifier, preload: [:avatar])

      true ->
        nil
    end
  end

  defp enabled_users,
    do: from(u in User, where: is_nil(u.deleted_at) and is_nil(u.disabled_at))

  # 软删的行留在库里(外键要指得到),但任何查询都不该看见它们
  defp active_users, do: from(u in User, where: is_nil(u.deleted_at))

  # ── 验证码 ──────────────────────────────────────────────────────────────

  @doc """
  发一个验证码。

  带频率限制 —— core 完全没有这层,同一个手机号可以被无限次轰炸。
  """
  def send_verification_code(channel, target, purpose) do
    with :ok <- validate_code_request(channel, target, purpose),
         code = VerificationCode.generate_code(),
         {:ok, record} <-
           Repo.transaction(fn ->
             # 同一联系方式的检查与占位必须原子完成,切换用途也不能绕过。
             Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
               "verification:#{channel}:#{String.downcase(target)}"
             ])

             if verification_retry_after(channel, target) > 0,
               do: Repo.rollback(:too_many_requests)

             case Repo.insert(VerificationCode.build(channel, target, purpose, code)) do
               {:ok, record} -> record
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
      case deliver(channel, target, code) do
        :ok ->
          {:ok, record}

        {:error, _} = error ->
          Repo.delete(record)
          error
      end
    end
  end

  # target 要按通道分别校验形状。只查"非空"是不够的:phone_target("86", "")
  # 得到 "86-",非空但根本不是个手机号,会一路走到真的去发短信。
  defp validate_code_request(channel, target, purpose) do
    cond do
      channel not in VerificationCode.channels() -> {:error, :invalid_channel}
      purpose not in VerificationCode.purposes() -> {:error, :invalid_purpose}
      not valid_target?(channel, target) -> {:error, :invalid_target}
      true -> :ok
    end
  end

  defp valid_target?("sms", target) when is_binary(target),
    do: Regex.match?(~r/^\d{1,8}-\d{5,20}$/, target)

  defp valid_target?("email", target) when is_binary(target),
    do: Regex.match?(~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, target) and byte_size(target) <= 255

  defp valid_target?(_, _), do: false

  @doc "同一联系方式距离下次允许发码的秒数,包括已消费的验证码。"
  def verification_retry_after(channel, target) do
    sent_at =
      Repo.one(
        from c in VerificationCode,
          where:
            c.channel == ^channel and fragment("lower(?)", c.target) == ^String.downcase(target),
          select: max(c.inserted_at)
      )

    if sent_at do
      remaining =
        DateTime.add(sent_at, VerificationCode.resend_interval_seconds(), :second)
        |> DateTime.diff(DateTime.utc_now(), :millisecond)

      max(0, ceil(remaining / 1_000))
    else
      0
    end
  end

  defp deliver("sms", target, code) do
    {region, phone} = split_phone(target)

    Notifications.send_sms(
      region,
      phone,
      "验证码 #{code},#{VerificationCode.validity_minutes()} 分钟内有效。"
    )
  end

  defp deliver("email", target, code) do
    Notifications.send_email(
      target,
      "乡建DAO 验证码",
      "验证码 #{code},#{VerificationCode.validity_minutes()} 分钟内有效。"
    )
  end

  # sms 的 target 存成 `<区号>-<号码>`,这样同号不同区号不会互相顶掉
  def phone_target(region, phone), do: "#{region}-#{phone}"

  defp split_phone(target) do
    case String.split(target, "-", parts: 2) do
      [region, phone] -> {region, phone}
      [phone] -> {"86", phone}
    end
  end

  @doc """
  校验验证码。成功即消费(一次性)。

  失败时累加 `attempts`,超过上限就锁死这条记录 —— core 那边 6 位码可以无限次猜。
  """
  def verify_code(channel, target, purpose, code) when is_binary(code) do
    now = DateTime.utc_now()

    query =
      from c in VerificationCode,
        where:
          c.channel == ^channel and c.target == ^target and c.purpose == ^purpose and
            is_nil(c.consumed_at),
        order_by: [desc: c.id],
        limit: 1

    case Repo.one(query) do
      nil ->
        {:error, :invalid_code}

      record ->
        cond do
          DateTime.compare(record.expires_at, now) != :gt ->
            {:error, :code_expired}

          record.attempts >= VerificationCode.max_attempts() ->
            {:error, :too_many_attempts}

          # 定长比较,避免按字符早退泄露信息
          not :crypto.hash_equals(record.code_hash, VerificationCode.hash(code)) ->
            bump_attempts(record)
            {:error, :invalid_code}

          true ->
            consume_code(record, now)
        end
    end
  end

  def verify_code(_, _, _, _), do: {:error, :invalid_code}

  @doc """
  把一条验证码标记成已消费。**只有一个调用方能成功。**

  上面是"先查出来、再写回去"。两个并发请求会同时读到同一条未消费的记录,
  都比对成功,然后都往下走 —— 一个短信码就能触发两次发放。

  所以消费这一步是带条件的 UPDATE(`consumed_at IS NULL`),靠数据库判胜负:
  受影响行数是 1 的那个才算验过。这是 compare-and-set,不是先查后写。
  """
  def consume_code(%VerificationCode{} = record, now \\ DateTime.utc_now()) do
    {count, _} =
      Repo.update_all(
        from(c in VerificationCode, where: c.id == ^record.id and is_nil(c.consumed_at)),
        set: [consumed_at: now, updated_at: now]
      )

    # 输给了另一个并发请求 —— 对调用方来说这个码就是用过了
    if count == 1, do: :ok, else: {:error, :invalid_code}
  end

  # 原子自增。读-改-写的话,两次并发的错误尝试会双双把 4 写成 5,
  # 尝试次数上限就形同虚设。
  defp bump_attempts(%VerificationCode{id: id}) do
    Repo.update_all(from(c in VerificationCode, where: c.id == ^id), inc: [attempts: 1])
  end

  # ── 注册 ────────────────────────────────────────────────────────────────

  @doc """
  注册:先在 PDS 建账号(那边持有密码),再建本地档案,最后签发令牌。

  PDS 建成功但本地建档失败时,PDS 上会留下一个孤儿账号 —— 这里如实返回错误,
  不做补偿删除(`deleteAccount` 需要管理员凭据,而且删错了不可逆)。
  同一 handle 重试会命中 PDS 的 HandleNotAvailable,不会静默产生第二个账号。
  """
  def register(%{handle: handle, password: password} = attrs) do
    email = attrs[:email]
    phone = attrs[:phone]
    phone_region = attrs[:phone_region] || "86"

    with :ok <- ensure_contact_available(email, phone, phone_region),
         {:ok, session} <-
           pds().create_account(%{
             email: pds_email(handle),
             handle: handle,
             password: password
           }) do
      user_attrs = %{
        did: session["did"],
        handle: session["handle"] || handle,
        email: email,
        phone: phone,
        phone_region: phone_region,
        nickname: attrs[:nickname] || default_nickname(handle)
      }

      case Repo.insert(User.registration_changeset(%User{}, user_attrs)) do
        {:ok, user} ->
          # PDS 公开资料使用同一昵称;资料写入失败不让已创建的账号卡在注册页。
          case pds().put_profile(session["accessJwt"], user.did, %{"displayName" => user.nickname}) do
            {:ok, _} ->
              :ok

            {:error, _} ->
              Logger.warning("registration: initial profile write failed for #{user.did}")
          end

          {:ok, token} = issue_token(user)
          {:ok, %{user: user, token: token, pds_session: session}}

        {:error, changeset} ->
          {:error, changeset}
      end
    end
  end

  defp pds_email(handle) do
    handle |> String.split(".") |> hd() |> Kernel.<>("@" <> pds().email_domain())
  end

  defp default_nickname(handle), do: handle |> String.split(".") |> hd()

  # 建 PDS 账号之前先查一遍本地占用 —— 否则 PDS 上会留下一个用不上的孤儿账号。
  # 真正的唯一性仍由数据库索引保证,这里只是把常见冲突提前拦掉。
  # 分开查而不是拼一条带 nil 的 or —— Ecto 会拒绝把 nil 当作可比较的固定值,
  # 而且分开写也更容易看出"没填就不查"这层意思。
  defp ensure_contact_available(email, phone, phone_region) do
    cond do
      email_taken?(email) -> {:error, :contact_taken}
      phone_taken?(phone, phone_region) -> {:error, :contact_taken}
      true -> :ok
    end
  end

  defp email_taken?(email) when is_binary(email) and email != "" do
    normalized = String.downcase(String.trim(email))

    normalized != "" and
      Repo.exists?(from u in active_users(), where: fragment("lower(?)", u.email) == ^normalized)
  end

  defp email_taken?(_), do: false

  defp phone_taken?(phone, region) when is_binary(phone) and phone != "" do
    Repo.exists?(from u in active_users(), where: u.phone == ^phone and u.phone_region == ^region)
  end

  defp phone_taken?(_, _), do: false

  # ── 登录 ────────────────────────────────────────────────────────────────

  @doc "登录。密码由 PDS 校验,rice 只发自己的令牌。"
  def login(identifier, password) do
    case get_user_by_identifier(identifier) do
      nil ->
        # 用户不存在时也走一次 PDS,避免用响应时间区分"账号不存在"和"密码错"
        pds().create_session(identifier, password) |> login_failure()

      user ->
        cond do
          not is_nil(user.disabled_at) ->
            {:error, :account_disabled}

          true ->
            case pds().create_session(user.handle, password) do
              {:ok, session} ->
                {:ok, token} = issue_token(user)
                {:ok, %{user: put_semi_wallet(user), token: token, pds_session: session}}

              {:error, _} = error ->
                login_failure(error)
            end
        end
    end
  end

  # 错误凭据与上游不可用分开；不存在的本地账号也走同一错误分类。
  defp login_failure({:error, {:pds, _, status, _}}) when status in [400, 401],
    do: {:error, :invalid_credentials}

  defp login_failure({:ok, _session}), do: {:error, :invalid_credentials}
  defp login_failure(_), do: {:error, :login_unavailable}

  # ── 令牌 ────────────────────────────────────────────────────────────────

  def issue_token(user, opts \\ []) do
    {plaintext, changeset} = ApiToken.build(user, opts)

    case Repo.insert(changeset) do
      {:ok, _record} -> {:ok, plaintext}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "用明文令牌换用户。过期、被撤销、用户被禁用都返回 nil。"
  def user_by_token(plaintext) when is_binary(plaintext) do
    hash = ApiToken.hash(plaintext)
    now = DateTime.utc_now()

    query =
      from t in ApiToken,
        join: u in assoc(t, :user),
        where: t.token_hash == ^hash and t.expires_at > ^now,
        where: is_nil(u.deleted_at) and is_nil(u.disabled_at),
        select: {t, u},
        preload: [user: :avatar]

    case Repo.one(query) do
      nil ->
        nil

      {token, _user} ->
        # 只在超过一分钟没更新时才写,避免每个请求都产生一次写
        maybe_touch(token, now)
        Repo.preload(token, user: :avatar).user |> put_semi_wallet()
    end
  end

  def user_by_token(_), do: nil

  @doc """
  把 `semi_links` 上的钱包地址填进用户的虚拟字段。

  在这里做(而不是在视图里现查)是为了让每个"当前用户"都自带这个字段 ——
  `/api/users/me` 和登录响应共用同一个 `UserJSON.data/1`,两边都要有。
  多一次按 did 的索引查询,表只有几行,代价可以忽略。

  非 Semi 用户查不到链接,字段保持 nil。
  """
  def put_semi_wallet(%User{} = user) do
    case get_link_by_did(user.did) do
      %SemiLink{wallet_address: wallet} -> %{user | wallet_address: wallet}
      _ -> user
    end
  end

  def put_semi_wallet(other), do: other

  defp maybe_touch(token, now) do
    stale? =
      is_nil(token.last_used_at) or DateTime.diff(now, token.last_used_at, :second) > 60

    if stale? do
      Repo.update_all(from(t in ApiToken, where: t.id == ^token.id), set: [last_used_at: now])
    end
  end

  def revoke_token(plaintext) when is_binary(plaintext) do
    hash = ApiToken.hash(plaintext)
    {count, _} = Repo.delete_all(from t in ApiToken, where: t.token_hash == ^hash)
    if count > 0, do: :ok, else: {:error, :not_found}
  end

  @doc "撤销一个用户的全部令牌 —— 禁用/删号/改密码时用。JWT 做不到这件事。"
  def revoke_all_tokens(%User{id: id}) do
    {count, _} = Repo.delete_all(from t in ApiToken, where: t.user_id == ^id)
    {:ok, count}
  end

  # ── 重置密码 / 改绑 ─────────────────────────────────────────────────────

  @doc """
  凭验证码重置密码。**匿名可用** —— 忘了密码的人本来就登不进来。

  密码在 PDS,所以这里调 `com.atproto.admin.updateAccountPassword`。
  成功后撤销该用户的全部令牌:改了密码就该把别处的登录踢掉。
  """
  def reset_password(channel, target, code, new_password) do
    with :ok <- validate_password(new_password),
         :ok <- verify_code(channel, target, "reset_password", code),
         {:ok, user} <- find_by_contact(channel, target),
         :ok <- pds().update_account_password(user.did, new_password) do
      {:ok, _} = revoke_all_tokens(user)
      {:ok, user}
    end
  end

  @doc "改绑手机。需要新号码的验证码。"
  def change_phone(%User{} = user, region, phone, code) do
    target = phone_target(region, phone)

    with :ok <- verify_code("sms", target, "modify_phone", code) do
      update_contact(user, %{phone: phone, phone_region: region})
    end
  end

  @doc "改绑邮箱。需要新邮箱的验证码。"
  def change_email(%User{} = user, email, code) do
    with :ok <- verify_code("email", email, "modify_email", code) do
      update_contact(user, %{email: email})
    end
  end

  defp validate_password(p) when is_binary(p) and byte_size(p) >= 8, do: :ok
  defp validate_password(_), do: {:error, :weak_password}

  # 验证码是对着联系方式发的,所以从联系方式反查用户
  defp find_by_contact("email", target) do
    case Repo.one(
           from u in active_users(),
             where: fragment("lower(?)", u.email) == ^String.downcase(target)
         ) do
      nil -> {:error, :user_not_found}
      user -> {:ok, user}
    end
  end

  defp find_by_contact("sms", target) do
    case String.split(target, "-", parts: 2) do
      [region, phone] ->
        case Repo.one(
               from u in active_users(), where: u.phone == ^phone and u.phone_region == ^region
             ) do
          nil -> {:error, :user_not_found}
          user -> {:ok, user}
        end

      _ ->
        {:error, :user_not_found}
    end
  end

  defp find_by_contact(_, _), do: {:error, :user_not_found}

  # ── 档案 ────────────────────────────────────────────────────────────────

  def update_profile(%User{} = user, attrs) do
    user |> User.profile_changeset(attrs) |> Repo.update()
  end

  @doc "改绑手机 / 邮箱,必须先过验证码。"
  def update_contact(%User{} = user, attrs) do
    user |> User.contact_changeset(attrs) |> Repo.update()
  end

  @doc """
  软删账号,先验证码后删。

  注销是不可逆的,所以和改绑一样要求当场验证一次联系方式 —— 光有一个
  可能被偷走的令牌不够。验证码发到账号自己的手机或邮箱,别人的不算。
  """
  def delete_user_with_code(%User{} = user, channel, code) do
    with {:ok, target} <- own_contact_target(user, channel),
         :ok <- verify_code(channel, target, "delete_account", code) do
      delete_user(user)
    end
  end

  defp own_contact_target(%User{email: email}, "email") when is_binary(email) and email != "",
    do: {:ok, email}

  defp own_contact_target(%User{phone: phone, phone_region: region}, "sms")
       when is_binary(phone) and phone != "",
       do: {:ok, phone_target(region, phone)}

  defp own_contact_target(_, _), do: {:error, :contact_not_set}

  @doc "软删账号,同时撤销全部令牌。"
  def delete_user(%User{} = user) do
    Multi.new()
    |> Multi.update(:user, Ecto.Changeset.change(user, deleted_at: DateTime.utc_now()))
    |> Multi.delete_all(:tokens, from(t in ApiToken, where: t.user_id == ^user.id))
    |> Repo.transaction()
  end

  @doc "清掉过期的令牌和验证码 —— Oban 定时任务调用。"
  def prune_expired do
    now = DateTime.utc_now()
    {tokens, _} = Repo.delete_all(from t in ApiToken, where: t.expires_at < ^now)

    {codes, _} =
      Repo.delete_all(
        from c in VerificationCode,
          where: c.expires_at < ^DateTime.add(now, -24 * 3600, :second)
      )

    %{tokens: tokens, codes: codes}
  end
end

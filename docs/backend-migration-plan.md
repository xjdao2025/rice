# 把 xiangjiandao-core 的后端能力迁移到 rice —— 调研与方案

> 状态:**C 端(36 个接口)与管理端(56 个接口)的后端全部完成**,两个前端
> (`social-app`、`social-app-admin`)的调用点也已全部切到 rice(进度见 §9)。
> `mix rice.import` 覆盖 core 的 14 张表,§7.3 的对账断言全部实现(见 §6.2)。
> rice 532 个测试全绿;social-app 分支 `rice-backend` 相对 master 零新增类型错误。
>
> 全部在本地库开发验证,**生产环境未接触,未做任何数据迁移**。
> 三个分支(`rice/backend-migration`、两个前端的 `rice-backend`)均未合并未部署。
> 目标:用 Phoenix(rice)替换 .NET 的 `xiangjiandao-core`,顺便把跟着 DDD/EF 脚手架长出来的
> 数据模型和 RPC 风格 API 重做成 Rails/Phoenix 惯例的样子。
> 日期:2026-07-27

---

## 1. 现状盘点

### 1.1 core 是什么

`xiangjiandao-core` 是 .NET 9 + FastEndpoints + NetCorePal(DDD 脚手架)+ EF Core + MediatR +
DotNetCore.CAP(outbox)+ RabbitMQ + MySQL + Redis。对外暴露 **96 个端点**:

| 面 | 端点数 | 消费方 |
|---|---|---|
| C 端(`/api/v1/…`,非 Admin*) | 36 | `social-app` 的 `src/server/dao/apiMap.ts` |
| 管理端(`Admin*` / `UserManage`) | 60 | `social-app-admin`(89 条 `defineAPI`) |

C 端 36 个接口前端**全部在用**(grep 确认,无死接口)。

### 1.2 它并不管的东西

划清边界很重要 —— 以下都不在本次迁移范围内,迁完也不动:

- **PDS / bsky / plc** —— 帖子、关注、点赞、图片全部走 AT Protocol,core 不碰。
- **post-cache**(Rust)—— 它连的是 **Postgres**,不是 MySQL,与 `t_user` 无耦合,独立存在。
- **密码** —— core 不存 C 端用户密码。登录 = 拿 `domain_name` + 密码去 PDS 打
  `com.atproto.server.createSession`,PDS 是密码权威。这条要原样保留。
  (`t_admin_user.secret_data` 是管理员密码,那是另一回事。)

### 1.3 core 真正拥有的业务

1. **身份档案** —— `t_user`:昵称/头像/简介/手机/邮箱/DID/handle,以及注册流程(短信/邮件验证码 → 预注册 → 建 PDS 账号 → 建档 → 发 token)。
2. **稻米(积分)** —— 余额、打赏、赠送、后台发放、明细。
3. **提案与投票** —— 提案、投票、评论。
4. **勋章** —— 后台批量发放,C 端展示。
5. **内容位** —— 公告、Banner、节点、应用列表、基金会信息。
6. **文件** —— 上传/下载/外链图片代理。
7. **管理后台** —— 上面每一项的 CRUD + 用户管理 + 帖子下架。

### 1.4 rice 现在有什么

Phoenix 1.8 / Elixir,已在生产跑 `rice.xjdao.xyz`。已有:Postgres(`Rice.Repo`,一张
`semi_links` 表)、Semi OAuth 客户端、PDS 客户端(`Rice.PDS`)、内存 ticket 交接
(`Rice.Handoff`),以及一个**临时的耦合点**:`Rice.Dao` 直连 core 的 MySQL 写 `t_user`,
并从 Redis 里偷 core 的 JWKS 自己签 daoJwt。

**这个耦合点正是本次迁移最大的收益** —— 迁完 `Rice.Dao` 整个删掉。

---

## 2. 主键方案:TSID

### 2.1 为什么

现状是 `char(36)` 的 UUIDv4 做主键 —— 36 字节、随机、B-tree 插入点四处乱跳、按时间排序要
另建 `created_at` 索引。TSID 是 13 字节、字典序 == 时间序、无中心协调。

`/Users/jiang/dev/semi/semi-backend/lib/tsid.rb` 的结构:

```
[ 53 bit 微秒时间戳 ][ 10 bit clock_id ]  →  base32 编码为 13 个字符
字母表: "234567abcdefghijklmnopqrstuvwxyz"
```

字母表按 ASCII 单调递增(`'2'..'7'` = 0x32–0x37,`'a'..'z'` = 0x61–0x7a),所以
**字符串排序结果等于数值排序结果** —— 这正是它能当 cursor 用的原因。
63 位有效值编到 13 字符(65 位容量),首字符落在 `2`–`b` 之间。
53 位微秒撑到公元 2255 年。

### 2.2 Elixir 移植

`lib/rice/tsid.ex`:

```elixir
defmodule Rice.Tsid do
  @moduledoc """
  时间排序 ID,与 semi-backend 的 `lib/tsid.rb` 二进制兼容(同字母表、同位宽),
  两边生成的 ID 可以互相 parse。
  """
  import Bitwise

  @chars ~c"234567abcdefghijklmnopqrstuvwxyz"
  @chars_tuple List.to_tuple(@chars)
  @clock_id_bits 10
  @length 13

  @doc "启动时调一次:随机 clock_id + 单调性用的 atomics 槽"
  def init do
    :persistent_term.put(__MODULE__, {:atomics.new(1, signed: false),
                                      :rand.uniform(1 <<< @clock_id_bits) - 1})
  end

  def generate do
    {ref, clock_id} = :persistent_term.get(__MODULE__)
    us = monotonic_us(ref, System.os_time(:microsecond))
    encode((us <<< @clock_id_bits) ||| clock_id)
  end

  # 同一微秒内多次调用时 +1,保证严格递增(对齐 ruby 的 ensure_monotonicity)
  defp monotonic_us(ref, now) do
    last = :atomics.get(ref, 1)
    next = max(now, last + 1)

    case :atomics.compare_exchange(ref, 1, last, next) do
      :ok -> next
      _   -> monotonic_us(ref, now)
    end
  end

  defp encode(int), do: encode(int, @length, [])
  defp encode(_int, 0, acc), do: List.to_string(acc)
  defp encode(int, n, acc),
    do: encode(div(int, 32), n - 1, [elem(@chars_tuple, rem(int, 32)) | acc])

  @doc "解回 {timestamp_us, clock_id}"
  def parse(<<_::binary-13>> = tsid) do
    int = Enum.reduce(String.to_charlist(tsid), 0, fn c, acc ->
      acc * 32 + Enum.find_index(@chars, &(&1 == c))
    end)
    {int >>> @clock_id_bits, int &&& (1 <<< @clock_id_bits) - 1}
  end
end
```

`Rice.Tsid.init/0` 挂在 `Rice.Application.start/2` 最前面。

### 2.3 接进 Ecto

```elixir
defmodule Rice.Tsid.Type do
  use Ecto.Type
  def type, do: :string
  def cast(<<_::binary-13>> = v), do: {:ok, v}
  def cast(_), do: :error
  def load(v), do: {:ok, v}
  def dump(<<_::binary-13>> = v), do: {:ok, v}
  def dump(_), do: :error
  def autogenerate, do: Rice.Tsid.generate()
end

defmodule Rice.Schema do
  defmacro __using__(_) do
    quote do
      use Ecto.Schema
      import Ecto.Changeset
      @primary_key {:id, Rice.Tsid.Type, autogenerate: true}
      @foreign_key_type Rice.Tsid.Type
      @timestamps_opts [type: :utc_datetime_usec]
    end
  end
end
```

所有新 schema `use Rice.Schema`。列类型统一 `varchar(13)`。

> 顺带:现有的 `semi_links` 用的是 `bigserial`,一并改成 TSID,库里不留两套主键风格。

### 2.4 `legacy_id`

每张从 MySQL 搬过来的表都带:

```sql
legacy_id varchar(36)                       -- 原 char(36) UUID;评论表是 bigint,存成十进制字符串
create unique index … on … (legacy_id);     -- partial: where legacy_id is not null
```

- 新建的行 `legacy_id` 为 `NULL`。
- **外键在导入时通过 `legacy_id` join 解析**,不额外存 `legacy_xxx_id` 列 —— 导完就只剩一列冗余。
- 唯一索引让导入脚本可以 `on_conflict: :nothing` 反复跑,支持"预导 → 增量 → 切换"三段式。
- 迁移观察期(建议 3 个月)结束后一条 migration 删掉全部 `legacy_id`。

---

## 3. 数据模型重做

### 3.1 全局规约(相对 core 的改动)

| core 的做法 | 新做法 | 理由 |
|---|---|---|
| 表名 `t_user` / `t_point_record` | `users` / `grain_transfers`,复数 snake_case,无前缀 | Rails 惯例 |
| `created_at` / `updated_at` | `inserted_at` / `updated_at`,`timestamptz` 微秒 | Phoenix 惯例 |
| `created_by` / `updated_by` varchar(64) | 删。确需审计的地方用 `actor_id` 外键 | 存的是自由文本(`'rice'`、`'admin'`),不可查 |
| `deleted tinyint` 满天飞 | 只在 `users`/`proposals`/`proposal_comments` 上保留 `deleted_at timestamptz` | 其余表(banner/app/node)后台直接删就行 |
| `row_version int` 乐观锁 | 删。余额靠 SQL 条件更新,其余靠 MVCC | 见 §3.3 |
| 枚举存 `int`(0=Unknown) | 存字符串,`Ecto.Enum` | 库里可读;`Unknown = 0` 这种占位值本身就是坏味道 |
| 大量反范式冗余列 | 删,改 join | 见下 |
| `NOT NULL DEFAULT ''` 表示"没有" | 可空列 + partial unique index | 见 §3.2 的真实 bug |

**反范式冗余的规模**(core 把用户信息复制进了每张关联表):
`t_proposal` 有 `initiator_did/domain_name/name/email/avatar` 5 列;
`t_user_medal` 有 `nick_name/avatar/phone/phone_region/email` 5 列;
`t_point_record` 有 `participator_domain_name/participator_nick_name`;
`t_point_distribute_record` 有 `nick_name/phone/phone_region/email`。
**用户改个昵称,这些全是脏数据。** 一律删掉走 join。

### 3.2 `users`

```sql
create table users (
  id            varchar(13) primary key,
  legacy_id     varchar(36),
  did           varchar(128) not null,
  handle        varchar(256) not null,          -- 原 domain_name
  email         varchar(255),
  phone         varchar(32),
  phone_region  varchar(8)   not null default '86',
  nickname      varchar(64)  not null default '',
  bio           varchar(512) not null default '',
  avatar_id     varchar(13)  references attachments(id),
  grain_balance bigint       not null default 0 check (grain_balance >= 0),
  node_member   boolean      not null default false,   -- 原 node_user
  disabled_at   timestamptz,                            -- 原 disable tinyint
  deleted_at    timestamptz,
  inserted_at   timestamptz not null,
  updated_at    timestamptz not null
);

create unique index users_did_idx     on users (did)            where deleted_at is null;
create unique index users_handle_idx  on users (lower(handle))  where deleted_at is null;
create unique index users_email_idx   on users (lower(email))   where deleted_at is null and email is not null;
create unique index users_phone_idx   on users (phone_region, phone) where deleted_at is null and phone is not null;
create unique index users_legacy_idx  on users (legacy_id)      where legacy_id is not null;
```

> **这里修掉一个真实缺陷。** core 的 `t_user` 上 `email`/`phone` 是
> `NOT NULL DEFAULT ''` 且**没有任何唯一索引**;"该手机号或邮箱已被使用"只在
> `UserRegisterEndpoint` 里用一次 `SELECT` 判断。两个请求并发注册同一手机号会双双通过。
> 导入时需要先跑一遍重复检测 —— 见 §6.3。

### 3.3 稻米:两张表并成一张

core 现在是:`t_point_record`(每笔转账**写两行**,收付各一行,`score` 带符号)+
`t_point_distribute_record`(后台发放,又一份)。

```sql
create table grain_transfers (
  id           varchar(13) primary key,
  legacy_id    varchar(36),
  kind         varchar(16) not null,   -- reward(打赏) | gift(赠送) | grant(后台发放)
  from_user_id varchar(13) references users(id),          -- NULL = 增发/后台发放
  to_user_id   varchar(13) not null references users(id),
  amount       bigint not null check (amount > 0),
  memo         varchar(256) not null default '',
  subject_uri  varchar(512),           -- at://… 被打赏的帖子,原 ExtendInfo
  actor_id     varchar(13) references admins(id),         -- grant 时的操作员
  inserted_at  timestamptz not null
);
create index on grain_transfers (to_user_id, id desc);
create index on grain_transfers (from_user_id, id desc) where from_user_id is not null;
```

- "我的稻米明细" = `where from_user_id = $me or to_user_id = $me order by id desc` ——
  **`order by id` 直接就是时间序**,这是 TSID 的直接红利。
- 分页用 `id < $cursor` 的 keyset 分页,替掉 `OFFSET`。

**并发扣款不再需要分布式锁。** core 现在为此拉了 Redis
(`IXiangjiandaoDistributedDisLock`,`RewardScoreEndpoint` 里对付款方和收款方各 acquire 一次,
5 秒超时)。新做法一条 SQL:

```elixir
Repo.transaction(fn ->
  {1, _} = Repo.update_all(
    from(u in User, where: u.id == ^from_id and u.grain_balance >= ^amount),
    inc: [grain_balance: -amount])
  Repo.update_all(from(u in User, where: u.id == ^to_id), inc: [grain_balance: amount])
  Repo.insert!(transfer)
end)
```

匹配 0 行就是余额不足,事务回滚。**Redis 分布式锁这个依赖整个消失。**

### 3.4 提案

```sql
create table proposals (
  id            varchar(13) primary key,
  legacy_id     varchar(36),
  user_id       varchar(13) not null references users(id),   -- 替掉 6 个 initiator_* 列
  title         varchar(128) not null,
  attachment_id varchar(13) references attachments(id),
  closes_at     timestamptz not null,                        -- 原 end_at
  status        varchar(16) not null default 'open',         -- open | passed | rejected
  agree_count   bigint not null default 0,
  oppose_count  bigint not null default 0,
  listed        boolean not null default true,               -- 原 on_shelf
  deleted_at    timestamptz,
  inserted_at   timestamptz not null,
  updated_at    timestamptz not null
);

create table proposal_votes (
  id          varchar(13) primary key,
  legacy_id   varchar(36),
  proposal_id varchar(13) not null references proposals(id) on delete cascade,
  user_id     varchar(13) not null references users(id),
  choice      varchar(8) not null,          -- agree | oppose
  inserted_at timestamptz not null
);
create unique index on proposal_votes (proposal_id, user_id);   -- ← core 没有这个约束

create table proposal_comments (
  id          varchar(13) primary key,
  legacy_id   varchar(36),                  -- 原表主键是 bigint,存十进制字符串
  proposal_id varchar(13) not null references proposals(id) on delete cascade,
  user_id     varchar(13) not null references users(id),
  body        varchar(512) not null,
  deleted_at  timestamptz,
  inserted_at timestamptz not null
);
create index on proposal_comments (proposal_id, id desc);
```

- 删 `total_votes`(= agree + oppose,存三份计数是三份不一致的机会)。
- `status` 的 `Unknown = 0` 去掉;`ProposalStatus` 前后端枚举值本来就对不齐
  (后端 `Review/Pass/Oppose`,前端 `InProgress/Pass/Fail`),换字符串顺手解决。
- **`proposal_votes` 的唯一索引是新增的** —— core 靠应用层查重,并发可重复投票。

### 3.5 其余表(概要)

| core | 新表 | 主要改动 |
|---|---|---|
| `t_medal` | `badges` | 删 `file_id`/`quantity`(数量 = count 关联);`attach_id` → `image_id` 外键 |
| `t_user_medal` | `badge_awards` | 删 5 列用户冗余;`(badge_id, user_id)` 唯一;`get_time` → `awarded_at` |
| `t_information` | `announcements` | `name` → `title`;`attach_id` → `attachment_id` 外键 |
| `t_banner` | `banners` | `banner_file_id` → `image_id` 外键;`link_address` → `url` |
| `t_app` | `apps` | `desc`(SQL 保留字附近的坏名)→ `description`;`link` → `url` |
| `t_node` | `nodes` | 删 `user_did`(join users);`logo` → `logo_id` 外键 |
| `t_global_config` | `site_settings` | 单行表 + `check (id = 'settings')`;`foundation_public_document` json → `foundation_documents` 关联表 |
| `t_admin_user` | `admins` | `secret_data` json → `password_hash`(bcrypt);`role` int → `role` 字符串;`special` → `superadmin` |
| (无) | `attachments` | 见 §3.6 |
| (无) | `api_tokens` | 见 §4.3 |
| (无) | `verification_codes` | 见 §4.4 |

### 3.6 文件

core 现在:上传写到容器内 `AppDomain.BaseDirectory/Data/{Picture,File}/`,fileId 是
`"1-<guid32>-<原始文件名>"` 这样一个**把类型、ID、用户提供的文件名拼在一起的字符串**,
下载时反向解析。用户文件名进路径 = 路径穿越的现成入口面。

```sql
create table attachments (
  id           varchar(13) primary key,
  legacy_id    varchar(200),                  -- 原 fileId 整串,给旧引用兜底
  kind         varchar(16) not null,          -- image | file
  filename     varchar(255) not null,         -- 仅用于下载时的 Content-Disposition
  content_type varchar(128) not null,
  byte_size    bigint not null,
  checksum     varchar(64) not null,          -- sha256
  storage_key  varchar(256) not null,         -- <id 前两位>/<id>,与用户输入无关
  inserted_at  timestamptz not null
);
```

落盘路径只由 TSID 决定,用户文件名只在响应头里出现。

---

## 4. API 重做

### 4.1 现状风格

全部是 `POST /api/v1/<名词>/<动词>`(`/user/reset-password`、`/proposal/delete-my-proposal`、
`/score/user-sore-record-page` —— 注意这个 typo,`sore`,已经进了生产 URL),
返回统一信封 `ResponseData<T>` = `{code, message, data}`,HTTP 一律 200。

### 4.2 目标风格

REST + 复数资源 + HTTP 状态码,信封去掉:

```elixir
scope "/api", RiceWeb.Api do
  pipe_through :api

  post   "/registrations/verification",  RegistrationController, :verify   # 校验码 → 预注册票
  post   "/registrations",               RegistrationController, :create   # 建 PDS 账号 + 建档
  post   "/session",                     SessionController, :create        # 登录
  delete "/session",                     SessionController, :delete

  post   "/verification_codes",          VerificationCodeController, :create   # 发短信/邮件

  get    "/users/me",                    UserController, :me
  patch  "/users/me",                    UserController, :update
  delete "/users/me",                    UserController, :delete
  put    "/users/me/password",           UserController, :update_password
  put    "/users/me/phone",              UserController, :update_phone
  put    "/users/me/email",              UserController, :update_email
  get    "/users/me/badges",             BadgeController, :index

  resources "/proposals", ProposalController, only: [:index, :show, :create, :delete] do
    resources "/comments", ProposalCommentController, only: [:index, :create, :delete]
    get  "/vote",  ProposalVoteController, :show      # 我的投票
    post "/vote",  ProposalVoteController, :create
  end

  get    "/grain_transfers",             GrainTransferController, :index
  post   "/grain_transfers",             GrainTransferController, :create   # kind: reward | gift
  get    "/grain_grants",                GrainGrantController,    :index

  resources "/announcements", AnnouncementController, only: [:index, :show]
  get    "/nodes",                       NodeController, :index
  get    "/nodes/members",               NodeController, :members
  get    "/apps",                        AppController, :index
  get    "/banners",                     BannerController, :index
  get    "/settings/foundation",         SettingsController, :foundation

  post   "/attachments",                 AttachmentController, :create
  get    "/attachments/:id",             AttachmentController, :show
end
```

**分页**:`?limit=20&before=<tsid>` keyset 分页,响应

```json
{"data": [...], "meta": {"limit": 20, "next_cursor": "abc…"}}
```

替掉 `PagedData` 的 `page/pageSize/total`(总数需要 `COUNT(*)` 全表扫,列表页基本用不上;
确需 total 的管理端页面单独提供 `?with_total=true`)。

**错误**:HTTP 状态码 + `{"errors": {"phone": ["已被使用"]}}`,Ecto changeset 直出。

### 4.3 认证

现在这套很绕:core 把 RS256 私钥丢在 Redis `netcorepal:jwtsettings`,rice **从同一个 key
读出来自己签 daoJwt**,core 只验签名和 `type=client` 声明(issuer/audience 都不验)。

新方案 —— **不透明 token 存库**(Rails 惯例):

```sql
create table api_tokens (
  id          varchar(13) primary key,
  user_id     varchar(13) references users(id),
  admin_id    varchar(13) references admins(id),
  token_hash  bytea not null,          -- sha256(明文),明文只在签发时返回一次
  context     varchar(16) not null,    -- client | admin
  expires_at  timestamptz not null,
  last_used_at timestamptz,
  inserted_at timestamptz not null,
  check (num_nonnulls(user_id, admin_id) = 1)
);
create unique index on api_tokens (token_hash);
```

- 可撤销(禁用用户 = 删他的 token,现在的 JWT 做不到,只能等 30 天过期)。
- 没有密钥分发问题,Redis JWKS 这条依赖消失。
- `Rice.Dao` 整个模块删除。

PDS 的 accessJwt/refreshJwt 照旧原样透传给前端 —— 那是 PDS 的凭据,rice 不代管。

### 4.4 验证码

现在在 Redis 里,30 分钟 TTL(上次刚从 5/10 分钟改的)。搬成表:

```sql
create table verification_codes (
  id          varchar(13) primary key,
  channel     varchar(8)  not null,     -- sms | email
  target      varchar(255) not null,    -- 手机号或邮箱
  purpose     varchar(24) not null,     -- register | reset_password | modify_phone | modify_email
  code_hash   bytea not null,
  attempts    int not null default 0,
  consumed_at timestamptz,
  expires_at  timestamptz not null,
  inserted_at timestamptz not null
);
create index on verification_codes (channel, target, purpose, id desc);
```

比 Redis 多出来的:可审计、可按 target 限流(`发码 60 秒一次 / 每小时 5 条`,现在**没有任何限流**)、
可限制尝试次数(现在**可以无限次猜 6 位码**)。定期清理用 Oban 的 cron job。

### 4.5 RabbitMQ 和 Redis 各自在做什么 —— 实测

在 `node.xjdao.xyz` 上实际查过,不是看代码猜的。

#### RabbitMQ:**完全没在用**

core 在 `Program.cs` 里配了 `AddRabbitMQ` + `AddCap(x => x.UseRabbitMQ(...))`,但:

| 检查项 | 结果 |
|---|---|
| 代码里 `ICapPublisher` 的调用点 | **0 处** |
| `[CapSubscribe]` 订阅者 | **0 个** |
| `IIntegrationEvent` 实现类 | **0 个** |
| `CAPPublishedMessage` / `CAPReceivedMessage` / `CAPLock` 行数 | **0 / 0 / 0** |
| RabbitMQ 里的 vhost | 只有 `/`;core 配的 `xiangjiandao` vhost **根本不存在** |
| RabbitMQ 活动连接 | **0** |
| core 近 24h 日志里 rabbit 相关行 | **0** |

配置了 `VirtualHost=xiangjiandao` 而这个 vhost 不存在,却一条错误日志都没有 ——
说明 CAP 的 RabbitMQ transport 因为没有任何发布者和订阅者,**从来没尝试建立连接**。
这是 NetCorePal 脚手架带进来的样板,不是业务需要。

> `Xiangjiandao.Domain/DomainEvents/` 下那 4 个领域事件
> (`MedalCreated` / `ScoreDistributeRecordCreated` / `ScoreRecordCreated` / `UserModified`)
> 走的是 **MediatR 进程内派发**,不经过 CAP,也不出进程。

**结论:RabbitMQ 现在就是纯浪费(512MB 内存配额,常驻 130MB)。**
它不需要等迁移完成 —— 从 rice 的角度它压根不存在。

#### Redis:四类用途,三类可以直接消失

实测 db1 共 4678 个 key:

| 用途 | key 形态 | 实测占比 | rice 里怎么办 |
|---|---|---|---|
| **Hangfire 任务存储** | `hangfire:Xiangjiandao:job:<id>{,:state,:history}` | 4629 个(1543 个任务 × 3)= **99%** | **Oban**,任务表进 Postgres |
| **JWT 签名私钥** | `netcorepal:jwtsettings` | 1 个 | **消失** —— 换成 §4.3 的库内不透明 token |
| **验证码** | 阿里云短信 / 邮件验证码,30min TTL | 快照时为 0(全过期了) | **消失** —— 换成 §4.4 的 `verification_codes` 表 |
| **预注册票** | hash `xiangjiandao-pre-register`,30min TTL | 快照时为 0 | **消失** —— 并入 `verification_codes` |
| **分布式锁** | `score-distribution-lock:<uid>` | 瞬时,快照时为 0 | **消失** —— 见 §3.3 的条件更新 |
| **图片审核暂存** | `<guid>` + `content_type_<guid>`,10min TTL | 0 | 见下 |

Hangfire 里那 1543 个任务是 `ProposalEndJob` —— **每分钟**跑一次,扫
`proposals where closes_at <= now() and status = 'open'` 结票。这是 core 唯一的定时任务。
Oban 的 `Oban.Plugins.Cron` 一行 `{"* * * * *", Rice.Workers.CloseProposals}` 等价替换,
而且任务记录落 Postgres,和业务表同一个事务边界。

**图片审核那条要单独说。** `ImageUploadModerationMiddleware` 拦
`/pds/xrpc/com.atproto.repo.uploadBlob`,把图片塞进 Redis 生成一个临时 URL 给阿里云内容安全
回调抓取,审完删掉;配套的 `GET /api/v1/external/image/{imageId}` 就是给阿里云抓的。
但 `AliYunModerationOptions.EnableImageModeration` 默认 `false`,
生产和测试的 Nomad spec 里**都没有设这个开关** —— 也就是说**这条链路在线上是关着的,是死代码**。

迁移时的处理:先原样不实现(保持现状=关闭)。将来真要开图片审核,用
`attachments` 表 + `GET /api/attachments/:id` 就够了,不需要 Redis 中转 —— 那个设计当初
就是因为图片没有持久化存储才绕的。

#### 净结果

**Redis 和 RabbitMQ 两个服务在 rice 里都不需要。**

- RabbitMQ:零使用,直接停。
- Redis:唯一有实质流量的是 Hangfire,由 Oban(Postgres)接管;其余三类用途在新设计里
  各自并入了 Postgres 表。

同时消失的还有 `CAPPublishedMessage` / `CAPReceivedMessage` / `CAPLock` 三张表
(就是上周闹大小写那三张,一直是 0 行)。

> 注意:`bsky-redis` 是 bsky AppView 自己的缓存,**与本文无关,不能停**。
> 要停的是 `redis` 这个 job(core 专用,db1)。

---

## 5. 接口映射表(C 端 36 个)

| 旧 | 新 |
|---|---|
| `POST /user/pre-register` | `POST /api/registrations/verification` |
| `POST /user/register` | `POST /api/registrations` |
| `POST /user/login` | `POST /api/session` |
| `POST /user/login-user-detail` | `GET /api/users/me` |
| `POST /user/edit-profile` | `PATCH /api/users/me` |
| `POST /user/reset-password` | `POST /api/passwords/reset`(匿名 + 验证码,和 core 一样) |
| `POST /user/modify-phone` | `PUT /api/users/me/phone` |
| `POST /user/modify-email-address` | `PUT /api/users/me/email` |
| `POST /user/delete` | `DELETE /api/users/me` |
| `POST /user/node-user-list` | `GET /api/nodes/members` |
| `POST /sms/send` + `POST /email/send` | `POST /api/verification_codes`(`channel` 区分) |
| `POST /sms/verify` | 并入 `POST /api/registrations/verification` |
| `POST /score/reward` | `POST /api/grain_transfers` `{kind:"reward"}` |
| `POST /score/send` | `POST /api/grain_transfers` `{kind:"gift"}` |
| `POST /score/user-sore-record-page` | `GET /api/grain_transfers` |
| `POST /score-distribute-record/page` | `GET /api/grain_grants` |
| `POST /proposal/create` | `POST /api/proposals` |
| `POST /proposal/page` | `GET /api/proposals` |
| `POST /proposal/detail` | `GET /api/proposals/:id` |
| `POST /proposal/my-proposal-list` | `GET /api/proposals?mine=true` |
| `POST /proposal/delete-my-proposal` | `DELETE /api/proposals/:id` |
| `POST /proposal/vote` | `POST /api/proposals/:id/vote` |
| `POST /proposal/my-proposal-choice` | `GET /api/proposals/:id/vote` |
| `POST /proposal/comment` | `POST /api/proposals/:id/comments` |
| `POST /proposal/delete-my-comment` | `DELETE /api/proposals/:id/comments/:cid` |
| `POST /user-medal/page` | `GET /api/users/me/badges` |
| `POST /information/page` / `detail` | `GET /api/announcements` / `:id` |
| `POST /node/list` | `GET /api/nodes` |
| `POST /app/list` | `GET /api/apps` |
| `POST /banner/list` | `GET /api/banners` |
| `POST /global-config/foundation-info` | `GET /api/settings/foundation` |
| `POST /file/upload` | `POST /api/attachments` |
| `GET /file/download` | `GET /api/attachments/:id` |
| `GET /external/image/{imageId}` | `GET /api/attachments/:id`(合并) |

管理端 60 个映射到 `/api/admin/*` 的同名 REST 资源,原则一致,细节等 C 端做完再定。

---

## 6. 迁移执行

### 6.1 分期

前端 `apiMap.ts` 是脚本生成的,一次性全换风险太大。分期,每期"后端上线 → 前端切 → 观察 → 删旧"。

| 期 | 内容 | 风险 | 说明 |
|---|---|---|---|
| **0** | TSID、`Rice.Schema`、Oban、`mix rice.import` 骨架、**测试与对拍脚手架(§7)** | 无 | 不动线上,**进行中** —— 见 §9 |
| **1** | 只读内容:attachments(元数据)/ apps / banners / announcements / settings | 低 | 没有写路径;先拿它验证整套约定。**已完成,见 §9** |
| **2** | attachments 的存取与回填 | 低 | 老 fileId 通过 `legacy_id` 继续可读。**已完成,见 §9** |
| **3** | 身份:users / api_tokens / verification_codes、注册登录 | **高** | 见 §6.3 |
| **4** | 稻米账本 + 节点 + 勋章 | 中 | 涉及余额,需对账。**已完成,见 §9** |
| **5** | 提案 / 投票 / 评论 + 重置密码 / 改绑 | 中 | **已完成,见 §9** |
| **6** | 管理端 60 个接口 | 中 | 量最大,但只影响内部 |
| **7** | 停 core、**停 MySQL / Redis / RabbitMQ**、删 `Rice.Dao`、删 `legacy_id` | | 见 §4.5 |

期 3 之前,rice 和 core **同时在跑**,`Rice.Dao` 保持现状 —— 期 3 就是干掉它的那一期。

### 6.2 导入工具

rice 已经有到 core MySQL 的连接(`Rice.DaoSql`),直接复用,写一个 `mix rice.import`:

- 按依赖序:`users` → `attachments` → `badges` → `badge_awards` → `nodes` → `proposals` →
  `proposal_votes` → `proposal_comments` → `grain_transfers` → 其余。
- 每行 `legacy_id` 上 `on_conflict: :nothing`,**可反复跑** → 支持提前预导 + 停机窗口内只跑增量。
- 外键靠 `join` 老 `legacy_id` 解析。
- `--dry-run` 输出每表行数与冲突数。
- 结束打一份对账:两库行数、稻米总额、投票数。

**2026-08-09:14 张表全部覆盖,§7.3 的对账断言全部实现。**

导入顺序即依赖顺序:

```
attachments ← apps / banners / announcements / site_settings / admin_users
            ← users ← nodes / badges ← badge_awards
                    ← proposals ← proposal_votes / proposal_comments
                    ← grain_transfers
```

几处不是一对一的映射:

| 处理 | 为什么 |
|---|---|
| `t_point_record` + `t_point_distribute_record` → 一张 `grain_transfers` | 每笔转账 core 写两行(收付各一),折成一行;后者是前者 `type=3` 的完整副本,**只用来对账,不作为数据源**,否则后台发放会被记两次 |
| `t_user` / `t_proposal` / `t_proposal_comment` **连软删的行一起导** | 它们的软删行有下游引用(§6.4⑤⑥)。其余表只取 `deleted = 0` |
| fileId 从**七**张表的列里收集 | core 没有附件表。原来只收了四处,漏掉的那三处(管理员头像、节点 logo、勋章图、提案附件)会静悄悄变成 null,而行数对账看不出来 |

### 折半这一步加了断言

只取 `score > 0` 是有损操作 —— 丢掉的负行必须先证明确实冗余。所以每条正行都要
在负行里找到配对的那一条(键是 `{付方, 收方, 金额}`,收付视角互换),配不上的
留警告并计入对账的「流水配对」一项。**没有这层断言,折半就是在猜。**

后台发放不参与配对:它是增发,本来就只有正行。第一版把它算了进去,结果每一条
发放都被报成「未配对」,真正配不上的反而淹没在里面 —— 被 `import_test.exs` 抓到。

### 对账项(§7.3 全部落地)

每表行数、稻米守恒(余额总和 == 发放总额)、发放副本核对(行数与金额)、
流水配对、提案票数与投票记录一致、存活用户手机/邮箱/handle/DID 无重复、
随机 200 个用户逐字段抽样比对。

### 测试

`test/rice/import_test.exs` 跑的是**整条链路**,只有取数那一层是假的
(`Rice.FakeImportSource`)—— changeset、唯一索引、CHECK 约束、外键解析顺序、
对账查询全部是真的,打在真的 Postgres 上。数据集刻意复刻了 §6.4 那几条实测
结论的形状:软删用户与存活用户撞 handle 和手机号、投票指向软删的提案、
后台发放的 participator 是全零 GUID、流水成对可折半。

桩打在取数这条线上是有意的:导入的风险不在能不能连上 MySQL,而在映射和约束。
再往深打就会把要测的东西一起桩掉 —— 这个项目在这上面栽过一次(530 个测试
全绿之后人工实跑抓出约 10 个缺陷,其中 9 个是桩替掉了真正会出错的那一层)。

### 6.3 期 3 的三个真实风险

1. ~~**`t_user` 里可能已有重复手机/邮箱**(§3.2 的缺陷)~~ —— **已于 2026-07-27 实测,无重复**,
   见 §6.4。唯一索引可以直接建。但**软删用户与存活用户之间存在冲突**(1 个 handle、5 个手机号),
   所以 §3.2 的 partial unique index(`where deleted_at is null`)不是可选项而是必需的。
2. **双写窗口**。切换瞬间 core 和 rice 都可能写 `t_user`。方案:停机窗口(注册登录停 ~10 分钟)
   跑增量导入 + 切流量,比双写简单得多,业务量也完全撑得住。
3. **token 失效**。切换后所有在用的 daoJwt 作废,全体用户被登出一次。
   缓解:期 3 上线时让 rice **同时接受**老 daoJwt(用同一把 Redis 私钥验签)和新 token,
   30 天后(daoJwt 的有效期)删掉兼容分支。

### 6.4 生产数据体检结果(2026-07-27 实测,只读)

生产库 `xiangjiandao`,存活用户 1986。**数据比预期干净得多,没有阻断项。**

| 检查 | 结果 |
|---|---|
| 重复手机 / 邮箱 / handle / DID(存活用户) | **全部 0** |
| handle / DID 为空 | **0**(手机为空 375、邮箱为空 1578 —— 正常,二选一注册) |
| 重复投票 `(proposal_id, user_id)` | **0** —— 唯一索引可直接建 |
| 稻米对账 | `sum(users.score)` = `sum(point_record)` = `sum(distribute)` = **8,941,666**,三者完全一致 |
| 余额与流水不符的用户 | **0** |
| 提案票数与投票记录不符 | **0** |
| 外键孤儿 | 仅 `point_record.participator_id` 32 行,见下 |

几条对设计有直接影响的发现:

**① 那 32 个"孤儿"验证了 §3.3 的合并方案。** 它们全是 `type=3`(后台发放),
`participator_id = 00000000-0000-0000-0000-000000000000` —— 一个假的零 GUID 占位。
新模型里就是 `from_user_id = NULL`,语义正确且不再需要哨兵值。

**② `t_point_distribute_record` 是 `t_point_record where type=3` 的完整副本。**
32 行对 32 行,金额同为 8,941,666。两张表存的是同一件事,合并零信息损失。

**③ 全站稻米 100% 来自后台发放。** 发放总额 == 所有用户余额之和,说明打赏/赠送是零和的
内部转移。这给了导入对账一条很强的断言:`sum(balance) == sum(grants)`。

**④ 流水严格成对**,可以安全地折半:

| type | 行数 | 正 | 负 | 合并后 |
|---|---|---|---|---|
| 1 打赏 | 640 | 320 | 320 | 320 |
| 2 赠送 | 1856 | 928 | 928 | 928 |
| 3 发放 | 32 | 32 | 0 | 32 |
| **合计** | **2560**(+32 副本) | | | **1280** |

导入规则:**只取 `score > 0` 的行**,`to_user_id = user_id`,`from_user_id = participator_id`
(零 GUID → NULL)。2592 行变 1280 行。导入时断言每个正行都有配对负行。

**⑤ 软删用户必须导入,且 partial unique index 是必需的。**
7 个软删用户**没有被任何表引用**(提案/投票/流水/节点全是 0),但他们与存活用户之间
有 **1 个 handle 冲突和 5 个手机号冲突**。若唯一索引不带 `where deleted_at is null`,
建索引会直接失败。§3.2 的写法正确。

**⑥ 29 条投票指向已软删的提案。** 21 个提案里 8 个是软删的。新 schema 里
`proposal_votes.proposal_id` 是 `on delete cascade`,但提案走软删不走物理删,不受影响 ——
只需注意列表查询要过滤 `deleted_at is null`。

> 测试库 `xiangjiandao-dev` 同样干净(12 个用户,无任何重复)。

### 6.5 不迁的、要保留的

- PDS 仍是**密码权威**,登录仍是 `createSession`。
- `pds_plc_rotation_key` 绝对不动。
- post-cache 独立,不受影响。
- `semi_links` 和 Semi 登录链路照旧,只是 `Rice.Bridge` 里那句 `Rice.Dao.token_for` 换成
  本地的 `Rice.Accounts.issue_token/1`。

---

## 7. 测试与上线闸门

### 7.0 硬性约束

> **在得到明确确认之前,不碰生产数据库、不碰生产环境。**
> 全部开发、导入演练、对拍都在一次性的本地/测试库上进行。
> `mix rice.import` 默认 `--dry-run`,真正写库需要显式 `--commit` 且目标库不是生产。
> 每一期的验收材料(测试报告 + 对拍差异 + 对账数字)先交出来,确认后才谈上线。

### 7.1 覆盖率要求

**每个 controller action 都必须有 `ConnCase` 测试**,不是"主要的有就行"。C 端 36 个接口
展开成约 40 个 action,每个至少覆盖:

1. **成功路径** —— 正确入参 → 正确状态码 + 响应体形状(用 `json_response/2` 断言键与值)。
2. **未认证** → 401(除少数 `AllowAnonymous` 的:注册、登录、发码、公开列表)。
3. **越权** —— 拿 A 的 token 删 B 的提案/评论 → 403 或 404。core 里
   `delete-my-proposal` / `delete-my-comment` 这类"my"语义**必须**有对应的负例。
4. **入参校验失败** → 422 + `errors` 里带上出错字段。
5. **业务规则** —— 每条 `KnownException` 对应一个用例。比如打赏:余额不足、打赏自己、
   目标用户不存在、目标用户被禁用、金额 ≤ 0,五条各一个测试。

外部依赖(PDS、阿里云短信、SMTP)用 behaviour + Mox 打桩,不打真实服务。
`Rice.PDS` 已经是个薄客户端,抽个 `@behaviour` 出来即可。

### 7.2 功能一致性怎么保证 —— 对拍

光有单元测试证明不了"和原来一样"。加一层**双跑对拍**:

1. 从生产 MySQL 拉一份脱敏快照,导进测试库,**core 和 rice 各连一份相同数据的副本**。
2. 写一组请求剧本(`test/parity/cases/*.exs`),每条给出:旧接口 + 入参、新接口 + 入参。
3. 对拍脚本同时打两边,把响应按字段映射表归一化后 diff:
   - 忽略:信封 `{code,message,data}` 的外层、字段命名(`domainName` → `handle`)、
     ID(TSID vs UUID,按 `legacy_id` 对齐)、时间格式。
   - 不忽略:**业务值**。列表条数、排序、余额、票数、权限判定结果、错误是否发生。
4. 差异清单人工逐条裁决,归入"预期改动"或"缺陷",缺陷清零才算这一期完成。

读接口(列表/详情)全量对拍;写接口按剧本跑一遍再对拍后续的读接口。

### 7.3 导入正确性

`mix rice.import` 自带对账,跑完打印并写文件:

| 项 | 断言 |
|---|---|
| 每表行数 | MySQL(`deleted = 0`)== Postgres |
| 稻米守恒 | `sum(users.grain_balance)` 两边相等;且 == `sum(收) - sum(付)` |
| 提案票数 | `proposals.agree_count` == `count(proposal_votes where choice='agree')`,反对同理 |
| 外键完整性 | 没有任何 `legacy_id` 解析失败的行(解析失败 = 硬错误,不静默跳过) |
| 唯一性 | 手机/邮箱/handle/DID 无重复 —— 见 §6.3 风险 1 |
| 抽样比对 | 随机 200 个用户,逐字段比对(时间戳按秒对齐) |

导入演练至少完整跑 **两次**:一次全量,一次"全量 + 增量"(模拟切换日流程),两次对账都要过。

### 7.4 每一期的验收清单

一期算完成,必须四项齐备:

- [ ] 该期所有 action 的 ConnCase 测试通过,`mix test` 全绿
- [ ] 该期接口的对拍差异清单已裁决,无未解释差异
- [ ] 导入对账全过(涉及数据的期)
- [ ] 在 **xjdao.net 测试环境**跑通端到端手工验证,截图/日志留档

四项交付并得到确认后,才动生产。

---

## 8. 工作量与结论

粗估(单人):期 0–2 约 1 周,期 3 约 1.5 周(含对账和演练),期 4–5 约 1.5 周,
期 6 约 2 周,期 7 几天。**开发合计 6–7 周;加上 §7 的测试与对拍,按 9–10 周估。**

迁完的净收益:

- **少四个服务:core、MySQL、Redis、RabbitMQ** —— 全站只剩 Postgres 一个数据库
  (rice 业务 + Oban 任务 + post-cache 本来就在 Postgres;PDS 用自己的 SQLite,不变)。
- 少三张 CAP 表、一套 EF migration、一套 Hangfire 的 Redis 存储。
- 少一层"rice 偷 core 的私钥签 token"的耦合。
- 少一个 Redis 分布式锁。
- 修掉三个并发缺陷:手机/邮箱重复注册、重复投票、余额竞态。
- 主键从 36 字节 UUID 变 13 字节 TSID,列表页排序索引可以全部去掉。

主要代价:期 3 的停机窗口和一次全员登出,以及管理后台 60 个接口的机械劳动。

---

## 9. 实施进度

### 期 0(进行中)

**已完成 —— 2026-07-27,`mix precommit` 全绿,46 个测试通过。全程未接触生产。**

| 文件 | 内容 |
|---|---|
| `lib/rice/tsid.ex` | TSID 生成器。`:atomics` CAS 保严格单调,`:persistent_term` 存 clock_id |
| `lib/rice/tsid/type.ex` | Ecto 类型。`cast/1`/`dump/1` 校验长度与字母表 |
| `lib/rice/schema.ex` | `use Rice.Schema` —— TSID 主键 + TSID 外键 + `utc_datetime_usec` 时间戳 |
| `lib/rice/migration.ex` | `tsid_primary_key/0`、`tsid_references/2` |
| `priv/repo/migrations/*_create_tsid_domain.exs` | `CREATE DOMAIN tsid AS varchar(13)` |
| `priv/repo/migrations/*_add_oban.exs` | Oban 表 |
| `test/rice/tsid_test.exs` | 21 个用例,含 **tsid.rb 交叉验证向量** |
| `test/rice/tsid/type_test.exs` | 7 个用例 |
| `test/rice/schema_test.exs` | 10 个用例,真打 Postgres(sandbox 事务内建表) |
| `test/rice/oban_test.exs` | 4 个用例,含事务回滚时任务不残留 |

几个落地时定下来的决定:

**① 用 Postgres domain 而不是每处手写 `varchar(13)`。**
`references(..., type: :string)` 会生成 `varchar(255)`,主键和外键宽度对不上。
`CREATE DOMAIN tsid AS varchar(13)` 让两边是同一个类型,外键干净,也不会写错宽度。

**② 跨语言兼容有测试向量兜着。** `test/rice/tsid_test.exs` 里的 5 组
`{时间戳, clock_id, 整数, 编码}` 是用真实的 `semi-backend/lib/tsid.rb` 跑出来的。
以后改动编码逻辑,这组断言必须原样通过 —— 两个系统的 ID 要能互认。

**③ 记下一个反直觉的性质:突发生成会把时间戳推向未来。**
单调性靠 `max(now, last + 1)`,所以同一微秒内连发 N 个 ID,时间戳最多超前 N 微秒
(Ruby 版行为相同)。1 微秒/个 = 每秒 100 万个才会持续偏移,真实负载下会自己收敛回 0。
这条写成了测试(`突发生成会把时间戳推向未来,但幅度有上界`),免得日后被当成 bug。

**④ Oban 在生产默认完全关闭。** `config/runtime.exs` 里,没设 `OBAN_ENABLED=true` 时
`queues: false, plugins: false` —— 进程照常启动但完全不碰数据库。
即便在 Oban 迁移跑到目标库之前误部署,rice 也只是没有后台任务,不会启动失败。
(另外 Oban 的 `verify_migrated!` 只在 `testing != :disabled` 时执行,生产本来就不校验,
这里是第二层保险。)

**⑤ 顺手修了一个一直红着的测试。** `test/rice_web/controllers/page_controller_test.exs`
还在断言 Phoenix 生成器的默认首页文案,而首页在 `f168843` 就换成 Semi 登录调试页了。
改成断言实际内容。

### 期 1(已完成 —— 2026-07-27)

**`mix precommit` 全绿,86 个测试通过。生产未接触。**

覆盖 attachments(元数据)/ apps / banners / announcements / site_settings。
`nodes` 从期 1 挪到期 3 —— 它的 `score` 字段是对 `users.grain_balance` 的 join,
没有 users 就给不出完整响应,放在这里是假的独立。

5 张表、5 个只读接口、31 个新测试,外加 `mix rice.import`。

| 接口 | 说明 |
|---|---|
| `GET /api/apps` | 按 position 升序 |
| `GET /api/banners` | 按 position 升序 |
| `GET /api/announcements` | keyset 分页,新的在前 |
| `GET /api/announcements/:id` | |
| `GET /api/settings/foundation` | 含公开文件列表 |

落地时定下来的几件事:

**① 分页彻底换成 keyset。** `Rice.Pagination` 用 TSID 当游标:`?limit=20&before=<tsid>`,
响应 `{data, meta: {next_cursor}}`。没有 `OFFSET`(深翻页全表扫),没有 `COUNT(*)`
(列表页用不上,大表上却是最贵的一次查询)。垃圾 limit 退回默认、垃圾游标退回第一页,
都不是 500 —— 游标是不透明串,客户端不该猜它的结构。

**② 单例约束交给数据库。** `t_global_config` 在 core 里是普通表,靠应用层"取第一行"
假装单例,插第二行毫无阻力。新表上建了恒真表达式的唯一索引,第二行会被数据库挡下。

**③ `foundation_public_document` 从 json 数组拆成关联表。** 原本是一个裸 fileId 的字符串
数组,没有顺序语义也挂不上外键。现在是 `site_setting_documents`,position 显式、外键真实。

**④ 附件先只导元数据。** core 没有附件表,fileId 散落在四个字段里
(`t_app.logo` / `t_banner.banner_file_id` / `t_information.attach_id` /
`t_global_config.foundation_public_document`)。导入时汇总去重建出 `attachments` 行,
`byte_size` / `checksum` / `storage_key` 暂时可空 —— 文件本体的搬运是期 2,搬完再收紧成 NOT NULL。
这样期 1 就不需要改列名,后面也没有返工。

**⑤ `mix rice.import` 的两道安全阀。** 不加 `--commit` 时整个导入跑在必定回滚的事务里,
能拿到真实行数但什么都不留下;加了 `--commit` 且目标看起来是生产库时,还要再加
`--i-know-this-is-production` 才继续。

### 期 1 的实测

用 SSH 隧道连生产 MySQL(只读)跑了导入,目标是本机 Postgres:

```
表                         新增       已存在
attachments               21         0
apps                       2         0
banners                    6         0
announcements              3         0
site_settings             11         0        (1 行配置 + 10 个公开文件)

对账(MySQL deleted=0  vs  Postgres,在事务内统计):
  ✅ apps             2 -> 2
  ✅ banners          6 -> 6
  ✅ announcements    3 -> 3
```

外键 2/2、6/6、3/3 全部解析成功;`fund_scale=754313`、`issued_grain_scale=8941666`、
`proposal_approval_votes=20` 与生产一致;含中文和连字符的文件名
(`乡建DAO-截至20250831 财务收支 （公示）.pdf`、`GU logo 1-512.jpg`)解析正确。

**过程中修掉两个自己写出来的缺陷:**

1. **对账在事务外算,dry-run 回滚后全读到 0**,显示三个 ❌ —— 结论完全反了。
   移进事务内。
2. **幂等报告在说谎。** 第二次跑仍报"新增 21",而对账显示行数没变。原因是
   `on_conflict: :nothing` 只在主键由数据库生成时才把未插入行的 `id` 置为 nil,
   而 TSID 是应用侧生成的,`id` 永远有值,所以 `%{id: nil}` 的判断从未生效。
   改成插入前后各数一次。这个坑在 `test/rice/schema_test.exs` 里留了回归测试。

改完连跑三次验证:空库 → 全部"新增";再跑两次 → 全部"已存在",行数不变。

### 期 2(已完成 —— 2026-07-27)

**128 个测试通过。生产未接触。**

| 文件 | 内容 |
|---|---|
| `lib/rice/files/storage.ex` | 存储 behaviour(put/get/delete/exists?) |
| `lib/rice/files/storage/local.ex` | 本机磁盘实现 |
| `lib/rice/files.ex` | 校验、落盘、回填、读取 |
| `lib/rice_web/api/attachment_controller.ex` | `GET /api/attachments/:id` |
| `lib/rice/import/attachments.ex` + `mix rice.backfill_attachments` | 从 core 搬文件 |

**① 上传端点不在本期。** core 的 `/api/v1/file/upload` 标了 `AllowAnonymous` ——
任何人都能往服务器写文件,没有认证、没有速率限制。这个缺陷不照搬:
`Rice.Files.create_attachment/2` 已经就绪(大小上限 20MB、content-type 白名单、
sha256 校验和),但 HTTP 端点要等期 3 的认证到位才接上。
`test/rice_web/api/attachment_controller_test.exs` 里有一条测试直接扫路由表,
确保在那之前不会有人"顺手"把一个匿名上传路由加回来。

**② 落盘路径只由 TSID 决定。** core 的 fileId 是
`<类型码>-<guid>-<用户提供的文件名>`,并且直接用它拼落盘路径 —— 用户文件名进路径
是现成的路径穿越入口。新的 `storage_key` 形状是 `<id 前两位>/<id>`,
原始文件名只在下载时的 `Content-Disposition` 里出现,且做 RFC 5987 编码
(线上文件名含中文、空格、全角括号)。`Storage.Local` 在拼路径前还会再用正则
挡一道 —— 这类检查成本接近于零,漏掉一次的代价是任意文件读写。

**③ 写入顺序:先落盘,后写库。** 反过来的话,落盘失败会留下一条指向不存在文件的
记录,接口就会返回坏数据;这个方向最多留下一个孤儿文件,由清理任务回收。
测试里用 Mox 覆盖了两种失败:校验失败时存储一次都不被调用,落盘失败时数据库零行。

**④ 元数据先于字节存在,读到时是 404 不是 500。** 期 1 只导了元数据,
`storage_key` 为 NULL 的行在回填前是"还没有内容"。

### 期 3 后端(已完成 —— 2026-07-27,仅本地)

**207 个测试通过。本地库,未接触生产,未做数据迁移。**

新增 3 张表(`users` / `api_tokens` / `verification_codes`)和 10 个接口。

| 接口 | |
|---|---|
| `POST /api/verification_codes` | 发短信 / 邮件验证码 |
| `POST /api/registrations/verification` | 校验验证码 → 注册票 |
| `POST /api/registrations` | 凭票注册 |
| `POST /api/session` / `DELETE /api/session` | 登录 / 登出 |
| `GET·PATCH·DELETE /api/users/me` | 档案 |
| `POST /api/attachments` | 上传(**需登录**) |

补上的、core 没有的防线(每条都有测试):

| | core | rice |
|---|---|---|
| 发码频率 | **无限制** | 60 秒一次 |
| 验证码猜测次数 | **无限次** | 5 次后锁死 |
| 手机/邮箱唯一性 | 只有应用层一次 SELECT | 数据库 partial unique index |
| 令牌撤销 | JWT,签出去收不回 | 库内不透明 token,登出/禁用/删号立即失效 |
| 上传认证 | `AllowAnonymous` | 必须登录 |
| 账号枚举 | 未处理 | "账号不存在"与"密码错"响应逐字节相同 |

两个设计点:

**① 预注册票据从 Redis 换成签名票。** core 把它放在一个 Redis hash 里(30 分钟 TTL)。
现在是 `Phoenix.Token` 签名,无服务端状态。有一条测试专门盯着
**票据里的手机号不可被请求参数覆盖** —— 能覆盖的话,拿自己的手机验一次
就能给任意号码注册,验证码等于白做。

**② 外部依赖全部抽成 behaviour + Mox**:`Rice.PDS.Api`、`Rice.Notifications`、
`Rice.Files.Storage`。测试不打 PDS、不发短信、不碰磁盘。

### 前端集成(social-app 分支 `rice-backend`)

采用**方案 B**:新写 `src/server/rice/` 客户端,按接口逐个替换调用点,
不做兼容层。`server.dao(...)` 与 `server.rice.*` 共存,直到 core 的接口全部迁完。

刻意没有复用 `#/lib/request` —— 那一层是围绕 core 的 `{code, message, data}`
信封建的:丢掉 HTTP 状态码、把 401 当全局登出信号、还要拆一层 data。
rice 是标准 REST,套上去反而要处处绕开。

已迁移的调用点(全是只读):

| 页面 | 原 | 现 |
|---|---|---|
| Applications | `POST /app/list` | `listApps()` |
| HomeHeader | `POST /banner/list` | `listBanners()` |
| Hall / AnnouncementList | `POST /information/page` | `listAnnouncements()` |
| Hall / Announcement | `POST /information/detail` + `GET /file/download` | `getAnnouncement()` + 附件 URL |
| Hall / DocList | `POST /global-config/foundation-info` | `getFoundationSettings()` |

附件的处理变化最大:core 的 fileId 是 `<类型码>-<guid>-<文件名>` 一个字符串,
前端要用 `parseFileComposeId` 拆开再拼下载地址;rice 直接给结构化对象和 URL,
`extractAssetUrl` / `parseFileComposeId` 在这些页面已经不需要了。

### 期 4(已完成 —— 2026-07-27,仅本地)

**246 个测试通过。本地库,未接触生产。**

新增 4 张表(`nodes` / `grain_transfers` / `badges` / `badge_awards`)和 6 个接口。
接口总数 21。

**① 分布式锁没了。** core 为并发扣款拉了 Redis(`IXiangjiandaoDistributedDisLock`,
对付款方和收款方各 acquire 一次,5 秒超时)。这里是一条带条件的 UPDATE:

```sql
update users set grain_balance = grain_balance - $1
where id = $2 and grain_balance >= $1
```

匹配 0 行即余额不足,整个事务回滚。数据库上另有 `check (grain_balance >= 0)` 兜底。
有一条测试用 20 个并发任务对 100 稻米各转 10:**恰好成功 10 次**,付款方归零,
账本正好 10 行。

**② 两张表并成一张。** `t_point_record`(每笔写两行)+ `t_point_distribute_record`
(是前者 `type=3` 的完整副本)→ 单张 `grain_transfers`。
"我的明细"改成 `where from_user_id = me or to_user_id = me`,方向由渲染层根据
当前用户算出(`in`/`out`),不再靠两行带符号的记录来表达。

**③ 约束下沉到数据库。** core 在应用层判断的几件事现在是 check 约束:
金额为正、不能转给自己、`grant` 必须没有付款方而 `reward`/`gift` 必须有。
另外 `badge_awards` 上加了 `(badge_id, user_id)` 唯一索引 —— core 的
`t_user_medal` 允许同一枚勋章重复发给同一个人。

**④ 反范式冗余全部删掉。** `t_user_medal` 上的 5 列用户信息副本、
`t_node.user_did`、`t_medal.quantity`(count 的缓存)一律改成 join 或现算。

有两条测试盯着越权:**付款方永远是当前登录用户**(请求里塞 `from`/`from_user_id` 无效),
**客户端不能把 kind 指定成 grant**(否则就能凭空增发),后者还顺带断言了总量守恒。

### 期 5(已完成 —— 2026-07-27,仅本地)

**311 个测试通过。C 端 36 个接口的后端全部就位,rice 共 33 个 REST 端点。**

新增 3 张表(`proposals` / `proposal_votes` / `proposal_comments`)和 12 个接口。

**① 一人一票交给数据库。** `(proposal_id, user_id)` 上的唯一索引 —— core 靠
应用层先查后插,并发能重复投。有两条并发测试:20 人同时投,计数正好 20;
同一个人并发点 10 次,**只成功 1 次**,计数是 1。票数用原子自增维护,
另有测试断言 `agree_count` / `oppose_count` 与实际投票行数始终一致。

**② `total_votes` 删掉了。** core 存了三个计数(总/同意/反对),那是三份不一致的机会。
现在只存两个,总数在渲染时相加。

**③ 结票任务从 Hangfire 换成 Oban。** `{"* * * * *", Rice.Workers.CloseProposals}`。
core 的 `ProposalEndJob` 任务状态存 Redis —— 生产 Redis 里 99% 的 key 都是它留下的
(4629 / 4678)。结票逻辑幂等:`where status = 'open'` 让重跑和并发不会重复计数。

**④ 重置密码补上了 PDS 管理接口。** 密码在 PDS,所以走
`com.atproto.admin.updateAccountPassword`。这个接口要的是**完整的 Basic 头**,
不是裸密码 —— 2026-07 生产上 `BlueSky__AdminToken` 配成裸密码,
reset-password 一直 500。代码注释里记了这一笔。
重置成功后撤销该用户全部令牌:改了密码就该把别处的登录踢掉,JWT 做不到。

**⑤ 两处防账号枚举。** 重置密码时"手机号未注册"与"验证码错误"返回**逐字节相同**的
响应,否则这就是一个"这个号码注册过没有"的探测接口。登录那边同理。

### 前端全量迁移(2026-07-28,social-app 分支 `rice-backend`)

**C 端所有调用点已从 core 切到 rice。`src/server/index.ts` 不再导出 `server.dao`。**

选择把 dao 从入口摘掉、而不是留着"暂时不用",是因为 **rice 的登录不再签发
daoJwt** —— 任何遗漏的 core 调用不会在编译期报错,只会在运行期 401。
摘掉之后想调 core 必须显式 import,这是个显眼的例外。
(`src/server/dao/` 目录仍在:`defineProxyAPI` 被 post 服务复用,管理端也还没迁。)

迁移过程中反过来给 rice 补了几处后端能力 —— 前端有需求、rice 没有:

| 补的能力 | 为什么 |
|---|---|
| `GET /api/proposals?mine=created\|voted\|all` | 个人页三个标签(我发布的 / 我参与的 / 全部)。用 `EXISTS` 而不是 join:投过多次的提案 join 会重复,再靠 `distinct` 去重又和游标分页的 `order_by` 打架 |
| 提案 JSON 增加 `my_vote` | 列表和详情都要显示"已投票"。一次查询批量取,不做 N+1;未登录恒为 null,不泄露别人投了什么 |
| `GET /api/badges` | 勋章墙要把**没获得的**也灰着列出来。返回勋章全集,每一枚带当前用户的 `awarded_at`(没获得是 null) |
| 转账收款方支持 handle / 邮箱 / 手机号 | 转账界面只有一个输入框。core 分 `toUserId` 和 `userPhoneOrEmail` 两个字段,rice 用一个 `to` 全认 |
| `DELETE /api/users/me` 要求验证码 | **原实现只凭令牌就能注销**,而前端界面一直在收验证码。注销不可逆,补上 `delete_account` 用途的验证码校验:必须发到账号自己绑定的联系方式,用途也必须对得上(5 条测试盯着) |

前端这边同时把 core 时代的几套词汇换成了 rice 的:

- 提案状态:数字枚举 `ProposalStatus{Unknown,InProgress,Pass,Fail}` → `'all'|'open'|'passed'|'rejected'`
- 投票选项:`ProposalVoteType` → `'agree'|'oppose'`
- 验证码用途:数字 `codeType`(2/4/5/9)→ `'reset_password'|'modify_email'|'modify_phone'|'delete_account'`
- 分页:`{items,total,pageIndex,pageSize}` → `{data, meta.next_cursor}`,`useInfiniteScroll` 的 `isNoMore` 改成看游标
- 附件:`extractAssetUrl` / `parseFileComposeId` / `OssImage` 全部退场,统一 `attachmentUrl(附件对象)`
- feed 描述符:`proposal|<数字>|<did>` 的第二段同时兼着"状态"和"my-proposal 类型"两种含义,
  靠有没有 did 区分;现在拆成 `proposal|<状态>` 和 `proposal|<关系>|me`

有一处能力**没有**跟着迁:`updateProfile` 不再同步头像。
PDS 上的头像是 blob URL,rice 要的是自己的附件 id,两者对不上。
rice 侧的头像只用于它自己那几个页面(节点成员、评论、转账记录),暂时保持不变。

#### 类型检查这件事翻过一次车

`cloud/xjdao/scripts/verify-app.sh` 里 tsc 的输出被 `| tail -40` 截断,
于是我在 2026-07-27 把"19 个错误"当成了全量基线,并据此宣称"零新增类型错误"。
**实际全量是 master 313 个、分支当时 344 个 —— 有 31 个新增错误被截断藏住了。**
这和脚本开头记的那次"零输出当通过"是同一类错误:把工具的沉默当成通过。

已把 `tail -40` 去掉。现在的真实数字:**master 313,分支 294,新增为空**
(逐行 diff,不是比总数)。分支比 master 少 19 个,是因为迁移顺手消掉了
core 那些 VO 类型带来的老错误。

### 管理端(2026-07-28,rice 分支 `backend-migration`)

**core 的 56 个 `/api/v1/admin/*` 接口 → rice 的 52 条 REST 路由。411 个测试全绿。**
逐条核对过映射:56 条全部落到真实存在的路由上(脚本比对 `mix phx.routes` 的输出)。

接口数变少不是漏了,是几处 RPC 本来就是同一件事的不同参数:

| core | rice | 为什么能合 |
|---|---|---|
| `user/page`、`node-user/page`、`user/search`、`user/search-by-name`、`unbound-node-user-search` | `GET /api/admin/users?q=&node_member=` | 五个都是同一个列表的不同过滤 |
| `user/enable`、`user/disable`、`set-node-user`、`cancel-node-user` | `PATCH /api/admin/users/:id` | 同一行上的两个布尔位 |
| `score-distribution/single`、`score-distribution/batch` | `POST /api/admin/grain_grants` | 收款人永远是数组,发一个人就是长度 1 |
| `global-config/detail`、`modify-foundation-info`、`modify-proposal-config` | `GET`/`PATCH /api/admin/settings` | 改的是同一行 |
| app/banner/information/node 各自的 list/detail/create/modify/delete/sort | 四组 REST 路由指向同一个 `CatalogController` | 四种资源的后台操作完全同构 |

#### 顺手补上的几个洞

**① 不知道密码也能让管理员的手机响。** core 的登录是三步:`login-with-password`
只回一个 bool,验证码要前端自己去调**公开的** `/sms/send`,再
`login-with-verification-code` 换令牌。也就是说发码这一步根本不校验密码。
rice 合成两步:`POST /session/challenge` 密码对了**才**发码。

**② 管理端接口没有权限校验。** core 的角色控制只在前端 ——
`_app.tsx` 里 `hideInMenu: !adminAuth` 把「投放管理」和「管理员管理」藏起来,
接口本身不查。运营人员知道路径就能调。rice 在路由上加了 `:admin_only` 管线,
服务端强制 `role=admin`(有测试:operator 调 `/admin_users` 是 403,
但内容运营照常 201)。

**③ 禁用一个用户要等 30 天才生效。** core 只把标记写进库,用户手上的 daoJwt
还能用满有效期。rice 的 `PATCH /users/:id {disabled:true}` 在同一个事务里
撤销该用户的全部令牌 —— 有测试断言禁用前 200、禁用后 401。

**④ 下架之后就找不回来了。** core 的 `proposal/take-off` 是单向的,
而管理端列表和 C 端用的是同一个「只看上架」的查询,下架的提案后台自己也看不见,
没法复核。rice 的后台列表看得到下架的,`PATCH` 也能把 `listed` 改回 true。

**⑤ 管理端和 C 端的令牌是两套。** 单独一张 `admin_tokens` 表,不是在
`api_tokens` 上加一个 context 列 —— 后者写错一个 where 就是把管理员权限
发给普通用户。有两条测试对着换:C 端令牌调 `/api/admin/me` 是 401,
管理端令牌调 `/api/users/me` 也是 401。

**⑥ 搜索框里的 `%` 是通配符。** 后台按昵称/手机/邮箱模糊搜,用户输入直接进
`ILIKE`。一个 `%` 就是整表。rice 转义 `%`、`_`、`\`,有测试。

**⑦ 密码摘要照抄,盐不照抄。** PBKDF2-HMAC-SHA256、27500 轮、64 字节、Base64,
和 core 的 `PasswordHashGenerator` 逐字节兼容 —— 迁数据时不必强制所有管理员改密码。
唯一不照抄的是盐:core 用 `Random.Shared`,那不是密码学安全的随机源,
rice 用 `:crypto.strong_rand_bytes/1`。老密码照样验得过,验证不关心盐当初怎么来的。
比对摘要用 `:crypto.hash_equals/2` 定长比较,账号不存在时也走一遍同样耗时的运算。

#### 不迁的两条

- `POST /post/api/posts/list` —— 管理端本来就是直连 post 服务,不经过 core。
- `POST /admin/post/take-off-post` —— 贴文不在 rice 库里,rice 只做一层薄代理
  (`POST /api/admin/post_takedowns`),意义在于 post 服务的管理凭据不必下发到前端。
  顺带补了个恢复的入口(`DELETE`),core 只能单向下架。

#### 还没做

- ~~`social-app-admin` 前端还没切过来~~ —— **已于 2026-07-29 切完**(分支
  `rice-backend`,11 个提交,core 客户端已删)。见下。
- ~~管理员账号的数据迁移~~ —— **已于 2026-08-08 补上**,见下。

### 补上的两处(2026-08-08,rice 分支 `backend-migration`)

**① `mix rice.import` 有 `admin_users` 了。**
`lib/rice/import/admin_users.ex`。这张表非导不可,原因不是省事:密码摘要能
**原样搬**(两边都是 PBKDF2-HMAC-SHA256 / 27500 轮 / 64 字节 / Base64),
让运营重建账号等于所有管理员一起换密码,而管理端没有自助改密的入口。

两类行会被**跳过并留下警告**,不静默丢:

| 跳过 | 为什么 |
|---|---|
| `phone = ''` | rice 的登录和找回密码只认手机号,这种账号存得进去也登不进来;库上还有 `admin_users_phone_check` 拦着 |
| `role = 0` | core 的 `RoleType.Unknown`,没初始化的脏值。默认成 operator 等于凭空发一份后台权限 |

对账的分母是"**打算导入的**行"(`deleted = 0 AND phone <> '' AND role IN (1,2)`)
而不是全部存活行 —— 否则库里只要有一个没手机号的旧账号,对账就永远是 ❌,
看的人很快会学会忽略它。

顺带修了一处:`t_admin_user.avatar` 原先不在附件收集的四个来源里,
导进来的管理员头像会全部变成 null,而这在行数上完全看不出来。

`secret_data` 的键名大小写(`Value`/`value`)两种都认。认错的表现是**所有管理员
都登不进去**,而导入这边行数对得上、一条警告都没有;盐不是合法 Base64 的行
也拦下来 —— `valid_password?/2` 会把 `:crypto` 的 `ArgumentError` rescue 成
"密码不对",那种坏行只有当事人登录时才暴露。

结构上顺手拆了一下:事务和 dry-run 回滚挪到 `Rice.Import`,
插入+计数挪到 `Rice.Import.Writer`,`Content` 只管映射。

**② `POST /api/admin/badges/:badge_id/holders` —— 给已有勋章补发持有人。**
core 没有这个入口,漏了谁只能重建一枚同名勋章,而那会把先拿到的人的获得时间
一起改掉。语义和新建时的名单一致(认不出来的人整批不发),只有一处放宽:
**已经持有的人不算错**,补名单时运营粘的常常是完整名单而不是差集。

写入是一条带 `ON CONFLICT DO NOTHING` 的 `INSERT`,所以"已持有"和"两个运营
同时点提交"走的是同一条路 —— 唯一索引说了算,不靠先查后写那个会漏的窗口。
返回 `{awarded, already_held}`。实现见 `lib/rice_web/api/admin/badge_controller.ex`。

### 期 0–5 剩余

- Mox 打桩 —— 依赖把 `Rice.PDS` 抽成 behaviour,和期 3 一起做。
- 对拍脚本(§7.2)—— 需要新旧两套接口同时存在才有意义,期 1 出第一个接口时再写。

### 未决

- `semi_links` 现在还是 `bigserial` 主键。改成 TSID 是一次带数据的表改造,
  且这张表在生产有真实数据,放到期 3(身份)一起做,不单独动。

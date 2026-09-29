import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/rice start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :rice, RiceWeb.Endpoint, server: true
end

config :rice, RiceWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Semi OAuth 2.0 / OIDC provider ("Login with Semi"). rice is a confidential
# client: it holds the client_secret and performs the code→token exchange
# server-side. Secrets come from env (SEMI_* injected via the secret/xjdao
# Nomad Variable in production); the non-secret defaults match the registered
# OAuth app. Read for all envs so local dev works when the env vars are set.
config :rice, :semi,
  client_id: System.get_env("SEMI_CLIENT_ID"),
  client_secret: System.get_env("SEMI_CLIENT_SECRET"),
  redirect_uri: System.get_env("SEMI_REDIRECT_URI") || "https://rice.together.li/callback",
  # The browser-facing consent page is served by the Semi *frontend*
  # (www.semi.im/oauth/authorize renders HTML). The API host
  # (api.semi.im/oauth/authorize) only returns JSON consent metadata — the
  # OIDC discovery doc lists it as `authorization_endpoint`, but it's not where
  # a human browser should land. Token/userinfo are on the API (issuer).
  authorize_base: System.get_env("SEMI_FRONTEND_URL") || "https://www.semi.im",
  issuer: System.get_env("SEMI_ISSUER") || "https://api.semi.im"

# AT Protocol PDS the identity bridge provisions/logs into. On the deployed
# host the PDS is reachable directly (host networking, no Cloudflare hop) for
# rice's own calls; `public_url` is the browser-facing PDS URL handed to the
# front-end so its Agent talks to the same PDS.
config :rice, :pds,
  base_url: System.get_env("PDS_BASE_URL") || "http://127.0.0.1:3200",
  public_url: System.get_env("PDS_PUBLIC_URL") || "https://web5.together.li",
  handle_domain: System.get_env("PDS_HANDLE_DOMAIN") || "web5.together.li",
  email_domain: System.get_env("PDS_EMAIL_DOMAIN") || "web5.together.li",
  # 重置密码要调 com.atproto.admin.*。注意 PDS 那边要的是完整的 Basic 头,
  # 这里只存密码,Rice.PDS.admin_auth/0 负责拼。
  admin_password: System.get_env("PDS_ADMIN_PASSWORD")

# Session handoff to the front-end (social-app). After the bridge mints a PDS
# session, rice redirects the browser here with a one-time ticket the app
# redeems cross-origin; `allowed_origin` scopes the redeem endpoint's CORS.
# 允许跨域调 /api 的来源,逗号分隔。C 端 app 和 rice 不同源,web 版靠这个。
#
# 只在环境变量真的设了的时候才覆盖 —— runtime.exs 在 dev.exs / test.exs
# **之后**执行,无条件写的话会把那两个环境配好的本地来源清空。
if origins = System.get_env("CORS_ORIGINS") do
  config :rice, :cors, origins: Rice.Cors.parse(origins)
end

config :rice, :handoff,
  target_url: System.get_env("HANDOFF_URL") || "https://together.li/semi-callback",
  allowed_origin: System.get_env("HANDOFF_ALLOWED_ORIGIN") || "https://together.li"

# xiangjiandao DAO backend integration: rice provisions t_user rows and signs
# the "daoJwt" the social-app uses for DAO API calls, replacing the DAO
# backend's own login-token issuance for Semi users. Enabled only when
# DAO_MYSQL_PASSWORD is set (see Rice.Dao / Rice.Application.dao_children).
config :rice, :dao,
  mysql_host: System.get_env("DAO_MYSQL_HOST") || "127.0.0.1",
  mysql_port: String.to_integer(System.get_env("DAO_MYSQL_PORT") || "3306"),
  mysql_user: System.get_env("DAO_MYSQL_USER") || "xiangjiandao",
  mysql_password: System.get_env("DAO_MYSQL_PASSWORD"),
  mysql_database: System.get_env("DAO_MYSQL_DATABASE") || "xiangjiandao",
  # 签名用的 JWKS 原文（JSON 数组）。2026-08-21 之前是每次去共享 Redis 读
  # `netcorepal:jwtsettings`；core 停机后那把钥匙没有写入者也不进备份，
  # 于是搬进 secret/xjdao。详见 Rice.Dao 的模块文档。
  #
  # ⚠️ **必须走 base64，不能直接放 JSON。** Nomad 的 env 模板用 go-envparse
  # 解析 `KEY=VALUE`，它会把值里的双引号**吃掉** —— 实测注入进来的是
  # `[{PrivateKey:MII...}]`，引号全没了，于是 Jason 在第 2 个字符就报错。
  # 这类问题不会在本地复现（本地是直接给环境变量），只在 Nomad 里炸。
  jwks:
    (case System.get_env("DAO_JWKS_B64") do
       b64 when is_binary(b64) and b64 != "" ->
         case Base.decode64(b64) do
           {:ok, json} ->
             json

           :error ->
             raise "DAO_JWKS_B64 不是合法 base64；生成方式：base64 -w0 jwks.json"
         end

       _ ->
         # 本地/测试直接给 JSON 原文即可
         System.get_env("DAO_JWKS")
     end),
  # Mirror the DAO backend's Jwt__* env (issuer/audience are not validated
  # by the .NET side, kept identical for fidelity; 43200 min = 30 days).
  jwt_issuer: System.get_env("DAO_JWT_ISSUER") || "xiangjiandao",
  jwt_audience: System.get_env("DAO_JWT_AUDIENCE") || "account",
  jwt_exp_minutes: String.to_integer(System.get_env("DAO_JWT_EXP_MINUTES") || "43200")

# Key for encrypting stored account passwords at rest (32 raw bytes,
# base64-encoded in RICE_LINK_ENC_KEY). Left nil when unset so non-bridge
# environments boot fine; Rice.Vault raises only if actually used.
#
# 只在环境变量真的设了的时候才写 —— 和上面 CORS_ORIGINS 同样的道理:
# runtime.exs 在 test.exs **之后**执行,无条件写会把测试里配好的固定密钥
# 清成 nil,而 Vault 一被用到就 raise(Semi 桥接的测试全跑不了)。
case System.get_env("RICE_LINK_ENC_KEY") do
  nil -> :ok
  "" -> :ok
  b64 -> config :rice, Rice.Vault, key: Base.decode64!(b64)
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :rice, Rice.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # 附件落盘位置。必须是容器外挂载进来的卷,否则重新部署就全丢。
  config :rice, :storage_root, System.get_env("STORAGE_ROOT") || "/srv/rice/storage"

  # 验证码外发。注册 / 找回密码 / 改绑 / 注销都靠它。
  # 日志模拟必须显式启用；真实通道未配置不能伪装成发送成功。
  case System.get_env("RICE_VERIFICATION_MODE", "live") do
    "live" -> config :rice, :notifications, Rice.Notifications.Dispatcher
    "log" -> config :rice, :notifications, Rice.Notifications.Log
    _ -> raise "RICE_VERIFICATION_MODE must be live or log"
  end

  config :rice, Rice.Notifications.AliyunSms,
    access_key_id: System.get_env("ALIYUN_SMS_ACCESS_KEY_ID"),
    access_key_secret: System.get_env("ALIYUN_SMS_ACCESS_KEY_SECRET"),
    sign_name: System.get_env("ALIYUN_SMS_SIGN_NAME"),
    template_code: System.get_env("ALIYUN_SMS_TEMPLATE_CODE"),
    endpoint: System.get_env("ALIYUN_SMS_ENDPOINT") || "https://dysmsapi.aliyuncs.com"

  config :rice, Rice.Notifications.Smtp,
    sender_name: System.get_env("SMTP_SENDER_NAME") || "乡建DAO",
    sender_address: System.get_env("SMTP_SENDER_ADDRESS") || "no-reply@xjdao.xyz"

  if (smtp_relay = System.get_env("SMTP_RELAY")) not in [nil, ""] do
    config :rice, Rice.Mailer,
      adapter: Swoosh.Adapters.SMTP,
      relay: smtp_relay,
      port: String.to_integer(System.get_env("SMTP_PORT") || "587"),
      username: System.get_env("SMTP_USERNAME"),
      password: System.get_env("SMTP_PASSWORD"),
      # StartTls,和 core 的 SecureSocketOptions 默认值一致
      tls: :always,
      auth: :always,
      retries: 1

    config :swoosh, :api_client, Swoosh.ApiClient.Req
  end

  # Oban 在生产默认**完全关闭**(不起队列、不起插件 = 不碰数据库),要等
  # priv/repo/migrations 里的 oban 迁移在目标库跑过之后,再设 OBAN_ENABLED=true 打开。
  # 这样即便在迁移前误部署,rice 也只是没有后台任务,不会启动失败。
  if System.get_env("OBAN_ENABLED") not in ~w(true 1) do
    config :rice, Oban, queues: false, plugins: false
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :rice, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :rice, RiceWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :rice, RiceWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :rice, RiceWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :rice, Rice.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end

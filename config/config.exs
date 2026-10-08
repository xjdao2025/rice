# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :rice,
  ecto_repos: [Rice.Repo],
  generators: [timestamp_type: :utc_datetime]

# 附件字节的落盘位置。生产在 runtime.exs 里覆盖成挂载出来的卷。
config :rice, :storage_root, Path.expand("../priv/storage", __DIR__)

# 后台任务。替代 core 的 Hangfire + Redis —— 任务表与业务表同库,
# 可以和业务写入放进同一个 Ecto.Multi,天然就是 outbox。
config :rice, Oban,
  repo: Rice.Repo,
  engine: Oban.Engines.Basic,
  queues: [default: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # core 用 Hangfire 每分钟跑一次 ProposalEndJob
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Rice.Workers.CloseProposals},
       {"* * * * *", Rice.Workers.ExpireTasks},
       {"* * * * *", Rice.Workers.StartEvents}
     ]}
  ]

# Configure the endpoint
config :rice, RiceWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: RiceWeb.ErrorHTML, json: RiceWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Rice.PubSub,
  live_view: [signing_salt: "2LmlxZvc"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :rice, Rice.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  rice: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  rice: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

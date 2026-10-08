defmodule Rice.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # 主键生成器的进程状态(atomics + 随机 clock_id)。必须在任何 Repo 写入之前。
    Rice.Tsid.init()

    children = [
      RiceWeb.Telemetry,
      Rice.Repo,
      {DNSCluster, query: Application.get_env(:rice, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Rice.PubSub},
      # 后台任务。生产上由 OBAN_ENABLED 控制,未开启时 queues/plugins 均为 false,
      # 进程照常启动但不访问数据库。见 config/runtime.exs。
      {Oban, Application.fetch_env!(:rice, Oban)},
      # One-time session-handoff ticket store (Semi → social-app login).
      Rice.Handoff,
      Rice.RateLimit,
      # Start to serve requests, typically the last entry
      RiceWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Rice.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RiceWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

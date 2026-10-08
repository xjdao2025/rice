defmodule Rice.PDS.Api do
  @moduledoc """
  PDS 客户端的 behaviour。`Rice.PDS` 是真实实现,测试里换成 Mox。

  抽这一层是因为注册和登录都必须打真实 PDS,而单元测试不能依赖一个跑着的 PDS。
  """

  @callback create_session(identifier :: String.t(), password :: String.t()) ::
              {:ok, map()} | {:error, term()}
  @callback create_account(attrs :: map()) :: {:ok, map()} | {:error, term()}
  @callback get_profile(access_jwt :: String.t(), did :: String.t()) ::
              {:ok, map()} | :missing | {:error, term()}
  @callback put_profile(access_jwt :: String.t(), did :: String.t(), record :: map()) ::
              {:ok, map()} | {:error, term()}
  @callback update_account_password(did :: String.t(), password :: String.t()) ::
              :ok | {:error, term()}
  @callback handle_domain() :: String.t()
  @callback email_domain() :: String.t()

  @spec impl() :: module()
  def impl, do: Application.get_env(:rice, :pds_client, Rice.PDS)
end

defmodule Rice.Files.Storage do
  @moduledoc """
  附件字节的存取。抽成 behaviour 有两个理由:测试里可以打桩不碰磁盘,
  以及将来换成 S3/OSS 时只加一个实现,业务代码不动。

  `key` 由 `Rice.Files.storage_key/1` 从 TSID 算出,**永远不含用户输入** ——
  core 的做法是把用户提供的文件名拼进路径,那是现成的路径穿越入口。
  """

  @callback put(key :: String.t(), content :: binary()) :: :ok | {:error, term()}
  @callback get(key :: String.t()) :: {:ok, binary()} | {:error, term()}
  @callback delete(key :: String.t()) :: :ok | {:error, term()}

  @spec impl() :: module()
  def impl, do: Application.get_env(:rice, :storage, Rice.Files.Storage.Local)

  @spec put(String.t(), binary()) :: :ok | {:error, term()}
  def put(key, content), do: impl().put(key, content)
  @spec get(String.t()) :: {:ok, binary()} | {:error, term()}
  def get(key), do: impl().get(key)
  @spec delete(String.t()) :: :ok | {:error, term()}
  def delete(key), do: impl().delete(key)
end

defmodule Rice.Files.Storage.Local do
  @moduledoc """
  本机磁盘。根目录由 `config :rice, :storage_root` 给出。

  key 的形状是 `<id 前两位>/<id>` —— 分两级目录是为了避免单目录下堆几十万个文件,
  多数文件系统在那种情况下 readdir 会明显变慢。
  """
  @behaviour Rice.Files.Storage

  @impl true
  def put(key, content) when is_binary(key) and is_binary(content) do
    path = path_for(key)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, content)
    end
  end

  @impl true
  def get(key) when is_binary(key), do: File.read(path_for(key))

  @impl true
  def delete(key) when is_binary(key) do
    case File.rm(path_for(key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  @spec root() :: String.t()
  def root, do: Application.fetch_env!(:rice, :storage_root)

  # key 是我们自己按 TSID 生成的,但拼路径前仍然再挡一道 —— 这类检查的成本
  # 接近于零,而漏掉一次的代价是任意文件读写。
  defp path_for(key) do
    unless safe_key?(key), do: raise(ArgumentError, "非法的 storage key: #{inspect(key)}")
    Path.join(root(), key)
  end

  defp safe_key?(key), do: Regex.match?(~r"^[a-z0-9]{2}/[a-z0-9]{13}$", key)
end

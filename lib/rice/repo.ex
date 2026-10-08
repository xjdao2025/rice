defmodule Rice.Repo do
  use Ecto.Repo,
    otp_app: :rice,
    adapter: Ecto.Adapters.Postgres

  @doc """
  用户输入的搜索词 → `ilike` 的"包含"模式。`%` `_` `\\` 必须转义,
  否则搜一个 `%` 就是全表。
  """
  def contains(q), do: "%" <> String.replace(String.trim(q), ["\\", "%", "_"], &"\\#{&1}") <> "%"
end

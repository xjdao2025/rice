defmodule Rice.Repo do
  use Ecto.Repo,
    otp_app: :rice,
    adapter: Ecto.Adapters.Postgres

  import Ecto.Query, only: [where: 3]

  @doc """
  用户输入的搜索词 → `ilike` 的"包含"模式。`%` `_` `\\` 必须转义,
  否则搜一个 `%` 就是全表。
  """
  def contains(q), do: "%" <> String.replace(String.trim(q), ["\\", "%", "_"], &"\\#{&1}") <> "%"

  @doc """
  按 TSID 主键取一条,`{:ok, record}` 或 `{:error, :not_found}`。

  长度/字符不合法的 id 根本不可能存在,直接当 404,不去打数据库。
  """
  def fetch(queryable, id),
    do: if(Rice.Tsid.valid?(id), do: found(get(queryable, id)), else: {:error, :not_found})

  def found(nil), do: {:error, :not_found}
  def found(record), do: {:ok, record}

  @doc "写库成功就把结果预加载好再返回,失败原样透传。"
  def preload_ok(result, preloads, opts \\ [])
  def preload_ok({:ok, record}, preloads, opts), do: {:ok, preload(record, preloads, opts)}
  def preload_ok(other, _preloads, _opts), do: other

  @doc "后台列表按创建时间筛。时间解析不了就当没传 —— 一个手滑的日期不该让整个列表 500。"
  def inserted_between(query, since, until) do
    query
    |> filter_time(since, fn query, dt -> where(query, [r], r.inserted_at >= ^dt) end)
    |> filter_time(until, fn query, dt -> where(query, [r], r.inserted_at <= ^dt) end)
  end

  defp filter_time(query, value, filter) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} -> filter.(query, dt)
      _ -> query
    end
  end

  defp filter_time(query, _value, _filter), do: query
end

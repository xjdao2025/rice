defmodule Rice.Pagination do
  @moduledoc """
  两种分页,同一个入口。默认是 keyset(游标),传了 `page` 就切成页码。

  ## 游标(默认)

  用 TSID 主键当游标 —— 字典序即时间序,所以 `id < cursor` 就是"更早的那一页",
  不需要 `OFFSET`(深翻页会全表扫),也不需要 `COUNT(*)`(信息流用不上,
  而且在大表上是最贵的一次查询)。

      %{entries: [...], next_cursor: "3ke6kg3wk223e" | nil}

  默认按 id 倒序(新的在前)。`order: :asc` 用于 position 排序的内容位。

  ## 页码(传 `page` 时)

      %{entries: [...], next_cursor: ..., total: 137, page: 3, per_page: 15}

  游标分页翻不到"第 7 页" —— 它只知道下一页。管理后台的表格是页码式的:
  运营要跳页、要知道一共多少条。这两件事游标都给不了,所以后台列表按页码走。

  代价是每次多一条 `COUNT(*)`,以及深翻页的 `OFFSET`。在后台这是划算的:
  数据量是运营级别的(几千条),而且人在看,并发量约等于零。C 端的信息流
  仍然走游标 —— 那里才是深翻页和高并发同时出现的地方。
  """
  import Ecto.Query

  @default_limit 20
  @max_limit 100

  @typedoc "一页结果。页码模式多 `total` / `page` / `per_page` 三项。"
  @type page(entry) :: %{
          required(:entries) => [entry],
          required(:next_cursor) => String.t() | nil,
          optional(:total) => non_neg_integer(),
          optional(:page) => pos_integer(),
          optional(:per_page) => pos_integer()
        }

  @type opts :: [limit: pos_integer(), before: String.t() | nil, after: String.t() | nil]

  @doc """
  从请求参数里解析出分页选项。非法输入一律退回默认值,不报错。

  认 `page` / `per_page` 时进页码模式;`per_page` 不传就沿用 `limit` 的默认值。
  """
  @spec params(map()) :: %{
          limit: pos_integer(),
          before: String.t() | nil,
          after: String.t() | nil,
          page: pos_integer() | nil
        }
  def params(params) when is_map(params) do
    %{
      limit: parse_limit(params["per_page"] || params["limit"]),
      before: parse_cursor(params["before"]),
      after: parse_cursor(params["after"]),
      page: parse_page(params["page"])
    }
  end

  @doc """
  响应里 `meta` 的内容。游标模式只有 `next_cursor`,页码模式多三项。

  统一走这里,免得每个 JSON 视图各拼各的 —— 漏一个 `total`,前端的分页器
  就只剩一页。
  """
  @spec meta(page(term())) :: map()
  def meta(%{page: page, total: total, per_page: per_page, next_cursor: cursor}) do
    %{next_cursor: cursor, total: total, page: page, per_page: per_page}
  end

  def meta(%{next_cursor: cursor}), do: %{next_cursor: cursor}

  @doc "把分页条件套到 query 上。多取一条用来判断还有没有下一页。"
  @spec paginate(Ecto.Query.t(), Ecto.Repo.t(), map(), keyword()) :: page(term())
  def paginate(query, repo, opts, config \\ [])

  def paginate(query, repo, %{page: page, limit: per_page}, config) when is_integer(page) do
    order = Keyword.get(config, :order, :desc)

    # COUNT 和取数据是两条查询,不在一个事务里 —— 中间插进来一行,
    # total 会比实际多/少一条。后台表格能接受这个,加个事务不值当。
    total = count(query, repo)

    entries =
      query
      |> apply_order(order)
      |> limit(^per_page)
      |> offset(^((page - 1) * per_page))
      |> repo.all()

    %{
      entries: entries,
      # 页码模式下也给游标,这样同一个接口两种翻法都能用
      next_cursor: if(page * per_page < total, do: last_id(entries)),
      total: total,
      page: page,
      per_page: per_page
    }
  end

  def paginate(query, repo, %{limit: limit} = opts, config) do
    order = Keyword.get(config, :order, :desc)

    entries =
      query
      |> apply_cursor(opts, order)
      |> apply_order(order)
      |> limit(^(limit + 1))
      |> repo.all()

    case Enum.split(entries, limit) do
      {page, []} -> %{entries: page, next_cursor: nil}
      {page, _more} -> %{entries: page, next_cursor: last_id(page)}
    end
  end

  defp last_id([]), do: nil
  defp last_id(entries), do: entries |> List.last() |> Map.fetch!(:id)

  @doc false
  # 数一共多少条。看着比 `Repo.aggregate(query, :count)` 啰嗦,两处都是必要的:
  #
  #   * `exclude(:group_by)` —— Ecto 的 aggregate 遇到 group_by 直接抛
  #     `Ecto.QueryError`。勋章列表正是这样一个查询(左连 awards 数持有人),
  #     所以它在页码模式下会 500。
  #   * `count(distinct)` —— 去掉 group_by 之后,一枚有 3 个持有人的勋章会变成
  #     3 行。不去重的话 total 数的是连接后的行数,不是勋章数。
  #
  # select/order_by/limit/offset 也一并去掉:它们对计数没有意义,
  # 而带着 select 的话计数会去算那个表达式。
  defp count(query, repo) do
    query
    |> exclude(:preload)
    |> exclude(:select)
    |> exclude(:group_by)
    |> exclude(:order_by)
    |> exclude(:distinct)
    |> exclude(:limit)
    |> exclude(:offset)
    |> select([q], count(q.id, :distinct))
    |> repo.one()
  end

  defp apply_cursor(query, %{before: nil, after: nil}, _order), do: query

  defp apply_cursor(query, %{before: cursor}, _order) when is_binary(cursor),
    do: from(q in query, where: q.id < ^cursor)

  defp apply_cursor(query, %{after: cursor}, _order) when is_binary(cursor),
    do: from(q in query, where: q.id > ^cursor)

  defp apply_order(query, :desc), do: from(q in query, order_by: [desc: q.id])
  defp apply_order(query, :asc), do: from(q in query, order_by: [asc: q.id])

  defp parse_limit(nil), do: @default_limit

  defp parse_limit(value) when is_integer(value), do: clamp(value)

  defp parse_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} -> clamp(n)
      _ -> @default_limit
    end
  end

  defp parse_limit(_), do: @default_limit

  defp clamp(n) when n < 1, do: @default_limit
  defp clamp(n) when n > @max_limit, do: @max_limit
  defp clamp(n), do: n

  # 非法游标当作"没传",而不是 500 —— 游标是不透明串,客户端不该猜它的结构,
  # 传坏了退回第一页比报错更合理。
  defp parse_cursor(value) when is_binary(value) do
    if Rice.Tsid.valid?(value), do: value, else: nil
  end

  defp parse_cursor(_), do: nil

  # 没传 page 就是游标模式。传了个非法的值当第 1 页 —— 和游标一样,
  # 输入坏了退回第一页比 500 合理。
  defp parse_page(nil), do: nil
  defp parse_page(value) when is_integer(value) and value > 0, do: value
  defp parse_page(value) when is_integer(value), do: 1

  defp parse_page(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> n
      _ -> 1
    end
  end

  defp parse_page(_), do: nil

  @spec default_limit() :: pos_integer()
  def default_limit, do: @default_limit

  @spec max_limit() :: pos_integer()
  def max_limit, do: @max_limit
end

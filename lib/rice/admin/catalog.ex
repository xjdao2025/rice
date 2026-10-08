defmodule Rice.Admin.Catalog do
  @moduledoc """
  后台维护的四种"有序清单":应用入口、轮播位、公告、节点。

  它们的后台操作长得一模一样(增改删 + 排序),所以增删改共用同一段代码,
  差异只在 schema 和预加载。core 那边是 4 × 6 = 24 个动词式接口,
  内容基本重复。

  排序单独一个动作:core 的 `/sort` 传一个 id 数组,整表重排 ——
  这里保留同样的语义(整份顺序覆盖),但在一个事务里做,
  不会出现"排到一半"的中间状态。
  """
  import Ecto.Query

  alias Rice.Community.Node
  alias Rice.Content.{Announcement, App, Banner}
  alias Rice.Repo

  @resources %{
    apps: {App, [:logo]},
    banners: {Banner, [:image]},
    announcements: {Announcement, [:attachment]},
    nodes: {Node, [:logo, user: :avatar]}
  }

  def list(kind) do
    {schema, preloads} = fetch_resource(kind)

    Repo.all(from r in schema, order_by: [asc: r.position, asc: r.id], preload: ^preloads)
  end

  def fetch(kind, id) do
    {schema, preloads} = fetch_resource(kind)
    Repo.fetch(from(r in schema, preload: ^preloads), id)
  end

  def create(kind, attrs) do
    {schema, preloads} = fetch_resource(kind)

    struct(schema)
    |> schema.changeset(with_default_position(kind, attrs))
    |> Repo.insert()
    |> Repo.preload_ok(preloads)
  end

  def update(kind, id, attrs) do
    {schema, preloads} = fetch_resource(kind)

    with {:ok, record} <- fetch(kind, id) do
      record |> schema.changeset(attrs) |> Repo.update() |> Repo.preload_ok(preloads)
    end
  end

  def delete(kind, id) do
    with {:ok, record} <- fetch(kind, id), do: Repo.delete(record)
  end

  @doc """
  按给定的 id 顺序整体重排。事务内做完 —— 排到一半失败会整体回滚,
  不会留下一份半新半旧的顺序。

  没出现在列表里的记录不动;列表里不存在的 id 直接报错,免得静默吞掉笔误。
  """
  def reorder(kind, ids) when is_list(ids) do
    {schema, _} = fetch_resource(kind)

    Repo.transaction(fn ->
      existing = Repo.all(from r in schema, where: r.id in ^ids, select: r.id) |> MapSet.new()

      case Enum.reject(ids, &MapSet.member?(existing, &1)) do
        [] ->
          ids
          |> Enum.with_index()
          |> Enum.each(fn {id, index} ->
            Repo.update_all(from(r in schema, where: r.id == ^id), set: [position: index])
          end)

          :ok

        missing ->
          Repo.rollback({:unknown_ids, missing})
      end
    end)
  end

  def reorder(_kind, _), do: {:error, :invalid_ids}

  # 新建的排到最后 —— core 是新的排最前,但后台列表本来就是拖拽排序的,
  # 追加到末尾更符合"我刚加了一个"的直觉。
  defp with_default_position(kind, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)

    if Map.has_key?(attrs, "position") do
      attrs
    else
      {schema, _} = fetch_resource(kind)
      next = (Repo.aggregate(schema, :max, :position) || -1) + 1
      Map.put(attrs, "position", next)
    end
  end

  defp fetch_resource(kind), do: Map.fetch!(@resources, kind)
end

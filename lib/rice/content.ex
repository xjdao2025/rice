defmodule Rice.Content do
  @moduledoc """
  运营内容:应用入口、轮播位、公告。

  三者都是后台维护、C 端只读,没有用户维度,所以是整个迁移里依赖最少的一块 ——
  期 1 拿它来把 schema 约定、REST 风格和测试模板跑通。
  """
  import Ecto.Query

  alias Rice.Content.{Announcement, App, Banner}
  alias Rice.{Pagination, Repo}

  # ── 应用入口 ────────────────────────────────────────────────────────────

  @doc "按 position 升序列出所有应用。数量是个位数,不分页。"
  @spec list_apps() :: [App.t()]
  def list_apps do
    Repo.all(from a in App, order_by: [asc: a.position, asc: a.id], preload: [:logo])
  end

  # ── 轮播位 ──────────────────────────────────────────────────────────────

  @doc "按 position 升序列出所有 banner。"
  @spec list_banners() :: [Banner.t()]
  def list_banners do
    Repo.all(from b in Banner, order_by: [asc: b.position, asc: b.id], preload: [:image])
  end

  # ── 公告 ────────────────────────────────────────────────────────────────

  @doc """
  公告分页。**按 position 升序**,同一位置里新的在前。

  公告栏的顺序是后台拖出来的 —— 和应用入口、轮播位一样,由运营定,不是时间序。
  core 那边是 `ORDER BY Sort ASC, CreatedAt DESC`,这里保持一致;只按 id 倒序的话
  大厅首页那三条的顺序和生产对不上。

  游标是 id,和这个顺序对不上 —— 只有当 position 全相等时翻页才准确。公告是个位数
  量级,C 端两处调用(大厅取 3 条、列表取 100 条)都是一次取全,不翻页。真要翻页
  得先给 `Pagination` 加按 position 的游标。
  """
  @spec list_announcements(map()) :: Pagination.page(Announcement.t())
  def list_announcements(params \\ %{}) do
    from(a in Announcement,
      order_by: [asc: a.position, desc: a.inserted_at],
      preload: [:attachment]
    )
    |> Pagination.paginate(Repo, Pagination.params(params))
  end

  @doc "取单条公告。`{:ok, announcement}` 或 `{:error, :not_found}`。"
  @spec fetch_announcement(String.t()) :: {:ok, Announcement.t()} | {:error, :not_found}
  def fetch_announcement(id), do: Repo.fetch(from(a in Announcement, preload: [:attachment]), id)
end

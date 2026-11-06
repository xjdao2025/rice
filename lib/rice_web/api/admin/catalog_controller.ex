defmodule RiceWeb.Api.Admin.CatalogController do
  @moduledoc """
  应用入口 / 轮播位 / 公告 / 节点的后台增删改排序。

  四种资源的后台操作完全同构,所以走同一个控制器。资源类型和响应视图由
  路由的 `assigns` 指定 —— 不从 URL 参数推,免得把用户输入喂给
  `String.to_existing_atom/1`。

  core 那边是 4 × 6 = 24 个动词式接口,内容基本重复;这里是 4 组 REST 路由
  指向同一段代码。
  """
  use RiceWeb, :controller

  alias Rice.Admin.Catalog

  action_fallback RiceWeb.Api.FallbackController

  plug :put_catalog_view

  def index(conn, _params), do: render(conn, :index, records: Catalog.list(kind(conn)))

  def show(conn, %{"id" => id}) do
    with {:ok, record} <- Catalog.fetch(kind(conn), id), do: render(conn, :show, record: record)
  end

  def create(conn, params) do
    with {:ok, attrs} <- permitted_body(conn, params),
         {:ok, record} <- Catalog.create(kind(conn), attrs) do
      conn |> put_status(:created) |> render(:show, record: record)
    end
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, attrs} <- permitted_body(conn, params),
         {:ok, record} <- Catalog.update(kind(conn), id, attrs) do
      render(conn, :show, record: record)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, _} <- Catalog.delete(kind(conn), id), do: send_resp(conn, :no_content, "")
  end

  @doc ~S"""
  整份顺序覆盖,body 是 `{"ids": [...]}`,数组顺序即位置。

  core 的 `/sort` 也是整份覆盖,但一条条更新;这里放在一个事务里,
  不会留下排到一半的顺序。
  """
  def reorder(conn, %{"ids" => ids}) when is_list(ids) do
    case Catalog.reorder(kind(conn), ids) do
      {:ok, :ok} ->
        render(conn, :index, records: Catalog.list(kind(conn)))

      {:error, :invalid_ids} ->
        reorder(conn, %{})

      {:error, {:unknown_ids, missing}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{ids: ["这些 id 不存在: " <> Enum.join(missing, ", ")]}})
    end
  end

  def reorder(conn, _params) do
    conn |> put_status(:unprocessable_entity) |> json(%{errors: %{ids: ["需要一个 id 数组"]}})
  end

  # Assigning a node owner also grants wallet control. Content operators can
  # edit a node's presentation, but only financial administrators can bind or
  # transfer its owner (including clearing the owner).
  defp permitted_body(conn, params) do
    attrs = body(params)

    if kind(conn) == :nodes and Map.has_key?(attrs, "user_id") and
         conn.assigns.current_admin.role != "admin" do
      # Existing editors submit complete records, including an unchanged owner.
      # Permit that shape but strip the field, so a concurrent admin transfer
      # cannot be reverted between this check and the eventual UPDATE.
      owner = if attrs["user_id"] == "", do: nil, else: attrs["user_id"]

      case conn.path_params["id"] do
        nil ->
          if is_nil(owner), do: {:ok, Map.delete(attrs, "user_id")}, else: {:error, :forbidden}

        id ->
          with {:ok, node} <- Catalog.fetch(:nodes, id) do
            if owner == node.user_id,
              do: {:ok, Map.delete(attrs, "user_id")},
              else: {:error, :forbidden}
          end
      end
    else
      {:ok, attrs}
    end
  end

  # 路由参数不该被当成资源字段写进去
  defp body(params), do: Map.drop(params, ["id", "ids"])

  defp kind(conn), do: conn.assigns.kind

  defp put_catalog_view(conn, _opts), do: put_view(conn, json: conn.assigns.json_view)
end

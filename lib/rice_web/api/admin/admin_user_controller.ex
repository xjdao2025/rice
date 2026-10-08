defmodule RiceWeb.Api.Admin.AdminUserController do
  @moduledoc "管理员账号的增删查。只有 role=admin 能进(路由上有 require_admin_role)。"
  use RiceWeb, :controller

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, params) do
    render(conn, :index, page: Rice.Admin.list_admins(params))
  end

  def create(conn, params) do
    with {:ok, admin, password} <- Rice.Admin.create_admin(params) do
      conn |> put_status(:created) |> render(:created, admin: admin, password: password)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, target} <- Rice.Repo.found(Rice.Admin.get_admin(id)),
         {:ok, _} <- Rice.Admin.delete_admin(conn.assigns.current_admin, target) do
      send_resp(conn, :no_content, "")
    end
  end

  @doc "当前登录的管理员自己。"
  def me(conn, _params), do: render(conn, :show, admin: conn.assigns.current_admin)

  def update_me(conn, params) do
    with {:ok, admin} <- Rice.Admin.update_profile(conn.assigns.current_admin, params) do
      render(conn, :show, admin: admin)
    end
  end
end

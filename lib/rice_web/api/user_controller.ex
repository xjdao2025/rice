defmodule RiceWeb.Api.UserController do
  @moduledoc "当前用户的档案。替代 core 的 /user/login-user-detail 和 /user/edit-profile。"
  use RiceWeb, :controller

  alias Rice.Accounts

  action_fallback RiceWeb.Api.FallbackController

  def search(conn, params) do
    page = Accounts.search_public_users(params)

    json(conn, %{
      data: Enum.map(page.entries, &RiceWeb.Api.UserJSON.public/1),
      meta: Rice.Pagination.meta(page)
    })
  end

  def profile(conn, %{"identifier" => identifier}) do
    with {:ok, user} <- Rice.Repo.found(Accounts.get_public_user(identifier)) do
      json(conn, %{data: RiceWeb.Api.UserJSON.public(user)})
    end
  end

  def me(conn, _params) do
    render(conn, :show, user: conn.assigns.current_user)
  end

  def update(conn, params) do
    with {:ok, user} <- Accounts.update_profile(conn.assigns.current_user, params) do
      render(conn, :show, user: Rice.Repo.preload(user, :avatar, force: true))
    end
  end

  @doc "改绑手机。需要新号码上收到的验证码。"
  def update_phone(conn, params) do
    with {:ok, user} <-
           Accounts.change_phone(
             conn.assigns.current_user,
             params["phone_region"] || "86",
             params["phone"] || "",
             params["code"] || ""
           ) do
      render(conn, :show, user: Rice.Repo.preload(user, :avatar))
    end
  end

  @doc "改绑邮箱。"
  def update_email(conn, params) do
    with {:ok, user} <-
           Accounts.change_email(
             conn.assigns.current_user,
             params["email"] || "",
             params["code"] || ""
           ) do
      render(conn, :show, user: Rice.Repo.preload(user, :avatar))
    end
  end

  @doc "注销账号:软删 + 撤销全部令牌。"
  def delete(conn, params) do
    case Accounts.delete_user_with_code(
           conn.assigns.current_user,
           params["channel"],
           params["code"] || ""
         ) do
      {:ok, _} ->
        send_resp(conn, :no_content, "")

      {:error, :contact_not_set} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{channel: ["账号没有绑定这个联系方式"]}})

      error ->
        error
    end
  end
end

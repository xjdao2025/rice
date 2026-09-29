defmodule RiceWeb.Api.Admin.UserController do
  @moduledoc """
  后台用户管理。core 的 9 个接口在这里是两个:
  一个带过滤的列表,一个改管理位的 PATCH。
  """
  use RiceWeb, :controller

  alias Rice.Admin.Users

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, params), do: render(conn, :index, page: Users.list_users(params))

  def show(conn, %{"id" => id}) do
    with {:ok, user} <- Users.fetch_user(id), do: render(conn, :show, user: user)
  end

  def update(conn, %{"id" => id} = params) do
    with {:ok, user} <- Users.fetch_user(id),
         {:ok, user} <-
           Users.update_user(user, Map.take(params, ~w(disabled node_member can_publish_tasks))) do
      render(conn, :show, user: user)
    else
      {:error, :no_changes} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          errors: %{
            detail: "没有可改的字段(只接受 disabled / node_member / can_publish_tasks)"
          }
        })

      other ->
        other
    end
  end
end

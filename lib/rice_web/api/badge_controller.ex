defmodule RiceWeb.Api.BadgeController do
  @moduledoc """
  某个人的勋章墙。替代 core 的 `/user-medal/page?domainName=...`。

  返回的是**勋章全集**,每一枚带上这个人的 `awarded_at`(没获得是 null)——
  勋章墙要把没拿到的也灰着列出来,只返回已获得的话就渲染不出来了。
  """
  use RiceWeb, :controller

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, %{"user_id" => user_id}) do
    with {:ok, user} <- resolve(conn, user_id) do
      render(conn, :index, badges: Rice.Community.list_badges(user))
    end
  end

  # "me" 走当前登录用户;其余按 id / DID / handle 找。
  defp resolve(conn, "me") do
    case conn.assigns[:current_user] do
      nil -> {:error, :unauthorized}
      user -> {:ok, user}
    end
  end

  defp resolve(_conn, identifier), do: Rice.Repo.found(Rice.Accounts.get_public_user(identifier))
end

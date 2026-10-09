defmodule RiceWeb.Api.Admin.PostController do
  @moduledoc """
  贴文列表与下架 / 恢复。贴文不在 rice 库里,这里只是把请求转给 aerox 的审核服务 ——
  意义在于管理凭据不必下发到前端。

  下架用 uri + cid 定位,放在 body 里而不是路径上:AT URI 里有斜杠。
  """
  use RiceWeb, :controller

  alias Rice.Admin.Posts

  def index(conn, params), do: respond(conn, Posts.list(params))

  def create(conn, params), do: respond(conn, Posts.take_down(params["uri"], params["cid"]))

  def delete(conn, params), do: respond(conn, Posts.restore(params["uri"], params["cid"]))

  defp respond(conn, {:ok, page}), do: json(conn, page)
  defp respond(conn, :ok), do: send_resp(conn, :no_content, "")

  defp respond(conn, {:error, :invalid_uri}) do
    conn |> put_status(:unprocessable_entity) |> json(%{errors: %{uri: ["缺少贴文 uri 或 cid"]}})
  end

  defp respond(conn, {:error, :labeler_not_configured}) do
    conn |> put_status(:service_unavailable) |> json(%{errors: %{detail: "审核服务未配置"}})
  end

  defp respond(conn, {:error, reason}) do
    conn
    |> put_status(:bad_gateway)
    |> json(%{errors: %{detail: "审核服务返回错误: #{inspect(reason)}"}})
  end
end

defmodule RiceWeb.Api.GrainGrantController do
  @moduledoc "后台发放记录(公开)。替代 core 的 /score-distribute-record/page。"
  use RiceWeb, :controller

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, params) do
    page = Rice.Grains.list_grants(params)

    put_view(conn, json: RiceWeb.Api.GrainTransferJSON)
    |> render(:grants, page: page, total_granted: Rice.Grains.total_granted())
  end
end

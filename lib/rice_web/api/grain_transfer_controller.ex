defmodule RiceWeb.Api.GrainTransferController do
  @moduledoc """
  稻米流转。替代 core 的 /score/reward、/score/send、/score/user-sore-record-page
  和 /score-distribute-record/page。
  """
  use RiceWeb, :controller

  alias Rice.Grains

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, params) do
    page = Grains.list_transfers(conn.assigns.current_user, params)
    render(conn, :index, page: page, viewer: conn.assigns.current_user)
  end

  # 可以拿手机号 / 邮箱查人,等于一个"这个号是谁"的查询口 —— 按用户限流
  def recipient(conn, params) do
    with :ok <- Rice.RateLimit.hit({:recipient, conn.assigns.current_user.id}, 30, 3600),
         {:ok, user} <- Grains.resolve_recipient(params["to"]) do
      json(conn, %{data: RiceWeb.Api.UserJSON.public(Rice.Repo.preload(user, :avatar))})
    end
  end

  def create(conn, params) do
    opts = [
      kind: if(params["kind"] == "reward", do: "reward", else: "gift"),
      memo: params["memo"],
      subject_uri: params["subject_uri"],
      request_id: params["client_request_id"]
    ]

    with {:ok, amount} <- fetch_amount(params["amount"]),
         {:ok, transfer} <- Grains.transfer(conn.assigns.current_user, params["to"], amount, opts) do
      conn
      |> put_status(:created)
      |> render(:show, transfer: transfer, viewer: conn.assigns.current_user)
    else
      # 和 fallback 的"可用稻米不足"措辞不同,C 端一直是这句
      {:error, :insufficient_balance} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{amount: ["稻米不足"]}})

      error ->
        error
    end
  end

  # 金额必须是正整数。字符串数字也收 —— 前端 JSON 里偶尔会传成字符串。
  defp fetch_amount(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp fetch_amount(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> {:error, :invalid_amount}
    end
  end

  defp fetch_amount(_), do: {:error, :invalid_amount}
end

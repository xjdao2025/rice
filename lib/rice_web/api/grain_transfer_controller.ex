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

  def recipient(conn, params) do
    with :ok <- limit_contact_lookup(conn, params["to"]),
         {:ok, user} <- Grains.resolve_recipient(params["to"]) do
      json(conn, %{data: RiceWeb.Api.UserJSON.public(Rice.Repo.preload(user, :avatar))})
    end
  end

  # 「送给谁」:精确命中只回一个人(exact: true),否则是按昵称 / handle 找到的候选
  def recipients(conn, %{"q" => q}) do
    with :ok <- limit_contact_lookup(conn, q),
         {:ok, %{exact: exact, users: users}} <-
           Grains.search_recipients(conn.assigns.current_user, q) do
      json(conn, %{data: Enum.map(users, &RiceWeb.Api.UserJSON.public/1), exact: exact})
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
         :ok <- limit_contact_lookup(conn, params["to"]),
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

  # 拿手机号 / 邮箱找人等于问"这个号是谁"。转账接口也能这么问 —— 回"用户不存在"
  # 还是"稻米不足"就是答案 —— 所以两个接口共用一个按用户的限额
  defp limit_contact_lookup(conn, to) do
    if Grains.contact_identifier?(to),
      do: Rice.RateLimit.hit({:recipient, conn.assigns.current_user.id}, 30, 3600),
      else: :ok
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

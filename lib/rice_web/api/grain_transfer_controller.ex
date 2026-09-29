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
    case Grains.resolve_recipient(params["to"]) do
      {:ok, user} ->
        user = Rice.Repo.preload(user, :avatar)
        json(conn, %{data: RiceWeb.Api.UserJSON.public(user)})

      {:error, :recipient_not_found} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{to: ["接收用户不存在"]}})

      {:error, :recipient_disabled} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{to: ["接收用户已被禁用"]}})
    end
  end

  def create(conn, params) do
    kind = if params["kind"] == "reward", do: "reward", else: "gift"

    with {:ok, amount} <- fetch_amount(params["amount"]) do
      opts = [
        kind: kind,
        memo: params["memo"],
        subject_uri: params["subject_uri"]
      ]

      case Grains.transfer(conn.assigns.current_user, params["to"], amount, opts) do
        {:ok, transfer} ->
          conn
          |> put_status(:created)
          |> render(:show, transfer: transfer, viewer: conn.assigns.current_user)

        {:error, :insufficient_balance} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: %{amount: ["稻米不足"]}})

        {:error, :recipient_not_found} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: %{to: ["接收用户不存在"]}})

        {:error, :recipient_disabled} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: %{to: ["接收用户已被禁用"]}})

        {:error, :cannot_transfer_to_self} ->
          conn |> put_status(:unprocessable_entity) |> json(%{errors: %{to: ["不能转给自己"]}})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}
      end
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

defmodule RiceWeb.Api.PointWalletTransferController do
  use RiceWeb, :controller
  import Ecto.Query

  alias Rice.{Repo, Points, Pagination}
  alias Rice.Accounts.User
  alias Rice.Points.{Entry, Queries, Transaction, WalletAccounts}

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, %{"point_id" => point_id} = params) do
    user_id = conn.assigns.current_user.id

    with true <- Rice.Tsid.valid?(point_id),
         {:ok, wallet} <- WalletAccounts.fetch(point_id, user_id) do
      ids = from e in Entry, where: e.account_id == ^wallet.id, select: e.transaction_id

      page =
        from(t in Transaction, where: t.point_id == ^point_id and t.id in subquery(ids))
        |> Pagination.paginate(Repo, Pagination.params(Map.take(params, ["before", "limit"])))

      data =
        Enum.map(page.entries, fn tx ->
          view =
            case Queries.transaction_for_user(tx.id, user_id) do
              {:ok, view} ->
                view

              {:error, :not_found} ->
                %{id: tx.id, kind: tx.kind, public_note: tx.public_note, recipients: []}
            end

          deltas =
            Repo.all(
              from e in Entry,
                where: e.transaction_id == ^tx.id and e.account_id == ^wallet.id,
                select: {e.bucket, e.delta}
            )

          available =
            deltas
            |> Enum.filter(&(elem(&1, 0) == "available"))
            |> Enum.map(&elem(&1, 1))
            |> Enum.sum()

          held =
            deltas
            |> Enum.filter(&(elem(&1, 0) == "held"))
            |> Enum.map(&elem(&1, 1))
            |> Enum.sum()

          view
          |> Map.put(:available_delta, Integer.to_string(available))
          |> Map.put(:held_delta, Integer.to_string(held))
          |> Map.put(:inserted_at, tx.inserted_at)
          |> Map.update!(:recipients, fn recipients ->
            Enum.map(
              recipients,
              &Map.update!(&1, :amount, fn value -> Integer.to_string(value) end)
            )
          end)
        end)

      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{data: data, meta: Pagination.meta(page)})
    else
      _ -> {:error, :not_found}
    end
  end

  def create(
        conn,
        %{"point_id" => point_id, "to" => to, "amount" => amount, "client_request_id" => key} =
          params
      )
      when is_binary(to) and is_binary(amount) do
    user = conn.assigns.current_user

    with true <- Rice.Tsid.valid?(point_id),
         {value, ""} when value > 0 <- Integer.parse(amount),
         true <- Integer.to_string(value) == amount,
         %User{} = recipient <-
           Repo.one(
             from u in User,
               where:
                 (fragment("?::text", u.id) == ^to or u.did == ^to or
                    u.handle == ^String.trim_leading(to, "@")) and
                   is_nil(u.deleted_at) and is_nil(u.disabled_at)
           ),
         true <- recipient.id != user.id,
         {:ok, tx} <-
           Repo.transaction(fn ->
             with {:ok, payer} <- WalletAccounts.fetch(point_id, user.id),
                  {:ok, payee} <- WalletAccounts.ensure_recipient(point_id, recipient.id),
                  {:ok, tx} <-
                    Points.transfer(%{
                      payer_account_id: payer.id,
                      actor_id: user.id,
                      idempotency_key: key,
                      public_note: params["note"],
                      recipients: [%{account_id: payee.id, amount: value}]
                    }) do
               tx
             else
               {:error, reason} -> Repo.rollback(reason)
             end
           end) do
      json(conn, %{
        data: %{
          id: tx.id,
          amount: amount,
          to: %{handle: recipient.handle, nickname: recipient.nickname}
        }
      })
    else
      {:error, :idempotency_conflict} ->
        {:error, :conflict}

      {:error, :insufficient_balance} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{detail: "可用积分不足"}})

      {:error, _reason} ->
        {:error, :unprocessable_entity}

      _ ->
        {:error, :invalid_amount}
    end
  end

  def create(_conn, _params), do: {:error, :invalid_amount}
end

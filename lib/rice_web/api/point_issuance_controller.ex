defmodule RiceWeb.Api.PointIssuanceController do
  use RiceWeb, :controller

  alias Rice.{Accounts, Points, Tsid}
  alias Rice.Points.Queries

  action_fallback RiceWeb.Api.FallbackController

  def show(conn, %{"point_id" => point_id, "id" => id}) do
    with {:ok, issuance} <- Queries.issuance_for_user(point_id, id, conn.assigns.current_user.id) do
      json(conn, %{data: issuance})
    end
  end

  def create(conn, %{"point_id" => point_id, "kind" => "policy_change"} = params) do
    user_id = conn.assigns.current_user.id

    with {:ok, request} <- policy_request(conn, params, user_id),
         {:ok, issuance} <- Points.propose_issuance_policy(point_id, request),
         {:ok, view} <- Queries.issuance_for_user(point_id, issuance.id, user_id) do
      conn |> put_status(:created) |> json(%{data: view})
    else
      {:error, reason} -> approval_error(conn, reason)
    end
  end

  def create(conn, %{"point_id" => point_id} = params) do
    user_id = conn.assigns.current_user.id
    proposers = Application.get_env(:rice, :point_issuance_proposers, %{})

    with true <- Tsid.valid?(point_id) and user_id in Map.get(proposers, point_id, []),
         {:ok, kind, reason, request, expires_at} <- issuance_request(conn, params, user_id),
         {:ok, issuance} <- Points.propose_issuance(point_id, kind, reason, request, expires_at),
         {:ok, view} <- Queries.issuance_for_user(point_id, issuance.id, user_id) do
      conn |> put_status(:created) |> json(%{data: view})
    else
      false ->
        {:error, :forbidden}

      {:error, :idempotency_conflict} ->
        conn |> put_status(:conflict) |> json(%{error: "idempotency_conflict"})

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: Atom.to_string(reason)})
    end
  end

  def approval_code(conn, %{"point_id" => point_id, "id" => id, "channel" => channel}) do
    user = conn.assigns.current_user

    with {:ok, :authorized} <- Points.authorize_issuance_approval(point_id, id, user.id),
         {:ok, _} <- Accounts.send_issuance_code(user, channel, id) do
      send_resp(conn, :no_content, "")
    else
      {:error, reason} -> approval_error(conn, reason)
    end
  end

  def approval_code(conn, _), do: approval_error(conn, :invalid_request)

  def approve(conn, %{"point_id" => point_id, "id" => id, "channel" => channel, "code" => code}) do
    user = conn.assigns.current_user

    with {:ok, :authorized} <- Points.authorize_issuance_approval(point_id, id, user.id),
         :ok <- Accounts.verify_issuance_code(user, channel, id, code),
         {:ok, _} <- Points.approve_issuance(point_id, id, user.id) do
      case Points.execute_issuance(point_id, id, user.id) do
        {:ok, %{kind: "policy_change", transaction_id: tx}} ->
          json(conn, %{data: %{id: id, status: "succeeded", transaction_id: tx}})

        _ ->
          show(conn, %{"point_id" => point_id, "id" => id})
      end
    else
      {:error, reason} -> approval_error(conn, reason)
    end
  end

  def approve(conn, _), do: approval_error(conn, :invalid_request)

  defp approval_error(conn, reason) do
    status =
      case reason do
        :forbidden -> :forbidden
        :idempotency_conflict -> :conflict
        :too_many_requests -> :too_many_requests
        :issuance_not_found -> :not_found
        :point_not_found -> :not_found
        _ -> :unprocessable_entity
      end

    code = if is_atom(reason), do: Atom.to_string(reason), else: "verification_unavailable"
    conn |> put_status(status) |> json(%{error: code})
  end

  defp policy_request(
         conn,
         %{
           "reason" => reason,
           "expires_at" => expiry,
           "signers" => signers,
           "threshold" => threshold,
           "supply_cap" => cap
         },
         user_id
       )
       when is_binary(expiry) do
    with [key] <- get_req_header(conn, "idempotency-key"),
         {:ok, expires_at, _} <- DateTime.from_iso8601(expiry),
         {:ok, amount} <- parse_cap(cap) do
      {:ok,
       %{
         actor_id: user_id,
         idempotency_key: key,
         reason: reason,
         expires_at: expires_at,
         signers: signers,
         threshold: threshold,
         supply_cap: amount
       }}
    else
      _ -> {:error, :invalid_issuance_policy}
    end
  end

  defp policy_request(_, _, _), do: {:error, :invalid_issuance_policy}

  defp parse_cap(nil), do: {:ok, nil}

  defp parse_cap(cap) when is_binary(cap) and byte_size(cap) in 1..19 do
    case Integer.parse(cap) do
      {value, ""} when value >= 0 ->
        if cap == Integer.to_string(value), do: {:ok, value}, else: :error

      _ ->
        :error
    end
  end

  defp parse_cap(_), do: :error

  defp issuance_request(
         conn,
         %{"kind" => kind, "reason" => reason, "recipients" => rows, "expires_at" => expiry},
         user_id
       )
       when kind in ["initial_allocation", "mint"] and is_binary(reason) and is_binary(expiry) and
              is_list(rows) and rows != [] do
    with [key] <- get_req_header(conn, "idempotency-key"),
         {:ok, expires_at, _} <- DateTime.from_iso8601(expiry),
         {:ok, recipients} <- parse_recipients(rows) do
      {:ok, kind, reason, %{actor_id: user_id, idempotency_key: key, recipients: recipients},
       expires_at}
    else
      _ -> {:error, :invalid_issuance}
    end
  end

  defp issuance_request(_, _, _), do: {:error, :invalid_issuance}

  defp parse_recipients(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      %{"account_id" => id, "amount" => amount} = row, {:ok, acc}
      when is_binary(id) and is_binary(amount) and byte_size(amount) in 1..19 ->
        case Integer.parse(amount) do
          {value, ""} when value > 0 ->
            if amount == Integer.to_string(value) do
              {:cont, {:ok, [%{account_id: id, amount: value, note: row["note"]} | acc]}}
            else
              {:halt, {:error, :invalid_issuance}}
            end

          _ ->
            {:halt, {:error, :invalid_issuance}}
        end

      _, _ ->
        {:halt, {:error, :invalid_issuance}}
    end)
  end
end

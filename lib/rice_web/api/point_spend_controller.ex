defmodule RiceWeb.Api.PointSpendController do
  use RiceWeb, :controller

  import Ecto.Query
  alias Rice.{Accounts, Points, Repo, Tsid}
  alias Rice.Points.{SpendApproval, SpendPolicy, SpendProposal, SpendSigner}

  def create(
        conn,
        %{"point_id" => point_id, "account_id" => account, "expires_at" => expiry} = params
      )
      when is_binary(expiry) do
    with [key] <- get_req_header(conn, "idempotency-key"),
         {:ok, expires, _} <- DateTime.from_iso8601(expiry),
         request = %{
           payer_account_id: account,
           actor_id: conn.assigns.current_user.id,
           idempotency_key: key
         },
         {:ok, proposal} <- propose(point_id, params, request, expires) do
      conn |> put_status(:created) |> json(%{data: view(proposal)})
    else
      {:error, reason} -> error(conn, reason)
      _ -> error(conn, :invalid_request)
    end
  end

  def create(conn, _), do: error(conn, :invalid_request)

  def show(conn, %{"point_id" => point_id, "id" => id}) do
    user = conn.assigns.current_user.id

    proposal =
      if Tsid.valid?(point_id) and Tsid.valid?(id) do
        Repo.one(
          from p in SpendProposal,
            left_join: policy in SpendPolicy,
            on: policy.account_id == p.account_id and policy.current,
            left_join: s in SpendSigner,
            on: s.policy_id == policy.id and s.user_id == ^user,
            where: p.point_id == ^point_id and p.id == ^id,
            where: p.proposer_id == ^user or not is_nil(s.id)
        )
      end

    if proposal,
      do: json(conn, %{data: view(proposal)}),
      else: error(conn, :spend_proposal_not_found)
  end

  def approval_code(conn, %{"point_id" => point_id, "id" => id, "channel" => channel}) do
    user = conn.assigns.current_user

    with {:ok, :authorized} <- Points.authorize_spend_approval(point_id, id, user.id),
         {:ok, _} <- Accounts.send_spend_code(user, channel, id) do
      send_resp(conn, :no_content, "")
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def approval_code(conn, _), do: error(conn, :invalid_request)

  def approve(conn, %{"point_id" => point_id, "id" => id, "channel" => channel, "code" => code}) do
    user = conn.assigns.current_user

    with {:ok, :authorized} <- Points.authorize_spend_approval(point_id, id, user.id),
         :ok <- Accounts.verify_spend_code(user, channel, id, code),
         {:ok, _} <- Points.approve_spend(point_id, id, user.id) do
      case Points.execute_spend(point_id, id, user.id) do
        {:ok, proposal} ->
          json(conn, %{
            data: %{id: id, status: "succeeded", transaction_id: proposal.transaction_id}
          })

        {:error, :approval_threshold_not_met} ->
          show(conn, %{"point_id" => point_id, "id" => id})

        {:error, reason} ->
          error(conn, reason)
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def approve(conn, _), do: error(conn, :invalid_request)

  defp propose(point_id, %{"action" => "policy_change"} = params, request, expires) do
    Points.propose_spend_policy(
      point_id,
      Map.merge(request, %{
        expires_at: expires,
        threshold: params["threshold"],
        signers: params["signers"]
      })
    )
  end

  defp propose(point_id, %{"action" => action, "recipients" => rows} = params, request, expires)
       when action in ["transfer", "reserve"] and is_list(rows) do
    with {:ok, recipients} <- parse_recipients(rows) do
      Points.propose_spend(
        point_id,
        Map.merge(request, %{
          action: action,
          recipients: recipients,
          business_reference: params["business_reference"],
          public_note: params["public_note"],
          private_note: params["private_note"]
        }),
        expires
      )
    end
  end

  defp propose(_, _, _, _), do: {:error, :invalid_request}

  defp parse_recipients(rows) do
    Enum.reduce_while(rows, {:ok, []}, fn
      %{"account_id" => id, "amount" => amount} = row, {:ok, acc}
      when is_binary(id) and is_binary(amount) and byte_size(amount) in 1..19 ->
        case Integer.parse(amount) do
          {value, ""} when value > 0 ->
            if Integer.to_string(value) == amount,
              do: {:cont, {:ok, [%{account_id: id, amount: value, note: row["note"]} | acc]}},
              else: {:halt, {:error, :invalid_request}}

          _ ->
            {:halt, {:error, :invalid_request}}
        end

      _, _ ->
        {:halt, {:error, :invalid_request}}
    end)
  end

  defp view(proposal) do
    policy = Repo.get!(SpendPolicy, proposal.policy_id)

    approvals =
      Repo.aggregate(from(a in SpendApproval, where: a.proposal_id == ^proposal.id), :count)

    status =
      cond do
        proposal.transaction_id -> "succeeded"
        not policy.current -> "stale"
        DateTime.compare(proposal.expires_at, DateTime.utc_now()) != :gt -> "expired"
        approvals >= policy.threshold -> "approved"
        true -> "pending"
      end

    payload =
      case proposal.payload do
        %{"items" => items} = payload ->
          Map.put(
            payload,
            "items",
            Enum.map(items, &Map.update!(&1, "amount", fn value -> Integer.to_string(value) end))
          )

        payload ->
          payload
      end

    %{
      id: proposal.id,
      point_id: proposal.point_id,
      account_id: proposal.account_id,
      action: proposal.action,
      amount: Integer.to_string(proposal.amount),
      payload: payload,
      status: status,
      approvals: approvals,
      threshold: policy.threshold,
      expires_at: proposal.expires_at,
      transaction_id: proposal.transaction_id,
      execution_error: proposal.execution_error
    }
  end

  defp error(conn, reason) do
    status =
      case reason do
        :forbidden -> :forbidden
        :spend_proposal_not_found -> :not_found
        :point_not_found -> :not_found
        :idempotency_conflict -> :conflict
        :too_many_requests -> :too_many_requests
        _ -> :unprocessable_entity
      end

    code = if is_atom(reason), do: Atom.to_string(reason), else: "verification_unavailable"
    conn |> put_status(status) |> json(%{error: code})
  end
end

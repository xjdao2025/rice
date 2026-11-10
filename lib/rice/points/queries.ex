defmodule Rice.Points.Queries do
  @moduledoc "Permission-filtered transaction details and internal ledger reconciliation."

  import Ecto.Query

  alias Rice.{Repo, Tsid}

  alias Rice.Points.{
    Account,
    Entry,
    Issuance,
    IssuanceApproval,
    IssuancePolicy,
    IssuanceSigner,
    Recipient,
    Transaction
  }

  @doc "Returns a transaction view for an authenticated personal wallet owner."
  @spec transaction_for_user(String.t(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def transaction_for_user(transaction_id, user_id) do
    if valid_id?(transaction_id) and valid_id?(user_id) do
      case Repo.get(Transaction, transaction_id) do
        nil -> {:error, :not_found}
        tx -> personal_view(tx, user_id)
      end
    else
      {:error, :not_found}
    end
  end

  defp personal_view(tx, user_id) do
    payer? =
      Repo.exists?(
        from e in Entry,
          join: a in Account,
          on: a.id == e.account_id,
          where:
            e.transaction_id == ^tx.id and e.delta < 0 and
              a.owner_type == "user" and a.owner_id == ^user_id
      )

    recipients =
      from r in Recipient,
        where: r.transaction_id == ^tx.id,
        order_by: r.id,
        select: %{account_id: r.account_id, amount: r.amount, note: r.note}

    visible =
      if payer? do
        Repo.all(recipients)
      else
        Repo.all(
          from r in recipients,
            join: a in Account,
            on: a.id == r.account_id,
            where: a.owner_type == "user" and a.owner_id == ^user_id
        )
      end

    if payer? or visible != [] do
      details = %{
        id: tx.id,
        point_id: tx.point_id,
        kind: tx.kind,
        public_note: tx.public_note,
        inserted_at: tx.inserted_at,
        recipients: visible
      }

      {:ok, if(payer?, do: Map.put(details, :private_note, tx.private_note), else: details)}
    else
      {:error, :not_found}
    end
  end

  @doc "Returns issuance progress to its proposer or a current signer of the asset."
  @spec issuance_for_user(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found}
  def issuance_for_user(point_id, issuance_id, user_id) do
    if Enum.all?([point_id, issuance_id, user_id], &valid_id?/1) do
      query =
        from i in Issuance,
          join: policy in IssuancePolicy,
          on: policy.id == i.policy_id,
          left_join: current in IssuancePolicy,
          on: current.point_id == i.point_id and current.current,
          left_join: signer in IssuanceSigner,
          on: signer.policy_id == current.id and signer.user_id == ^user_id,
          left_join: approval in IssuanceApproval,
          on: approval.issuance_id == i.id,
          left_join: approver in IssuanceSigner,
          on: approver.id == approval.signer_id,
          left_join: enabled in Rice.Accounts.User,
          on:
            enabled.id == approver.user_id and is_nil(enabled.disabled_at) and
              is_nil(enabled.deleted_at),
          where: i.point_id == ^point_id and i.id == ^issuance_id,
          where: i.proposer_id == ^user_id or not is_nil(signer.id),
          group_by: [i.id, policy.threshold, current.id],
          select: {i, policy.threshold, current.id, count(enabled.id)}

      case Repo.one(query) do
        nil ->
          {:error, :not_found}

        {proposal, threshold, current_id, approvals} ->
          {:ok, issuance_view(proposal, threshold, current_id, approvals)}
      end
    else
      {:error, :not_found}
    end
  end

  defp issuance_view(proposal, threshold, current_id, approvals) do
    status =
      cond do
        proposal.transaction_id -> "succeeded"
        proposal.policy_id != current_id -> "stale"
        DateTime.compare(proposal.expires_at, DateTime.utc_now()) != :gt -> "expired"
        approvals >= threshold -> "approved"
        true -> "pending"
      end

    %{
      id: proposal.id,
      point_id: proposal.point_id,
      policy_id: proposal.policy_id,
      kind: proposal.kind,
      reason: proposal.reason,
      total: Integer.to_string(proposal.total),
      recipients: issuance_payload(proposal),
      status: status,
      approvals: approvals,
      threshold: threshold,
      expires_at: proposal.expires_at,
      transaction_id: proposal.transaction_id,
      execution_error: proposal.execution_error
    }
  end

  defp issuance_payload(%Issuance{kind: "policy_change", recipients: payload}) do
    Map.update!(payload, "supply_cap", fn
      nil -> nil
      amount -> Integer.to_string(amount)
    end)
  end

  defp issuance_payload(proposal) do
    Enum.map(
      proposal.recipients["items"],
      &Map.update!(&1, "amount", fn amount -> Integer.to_string(amount) end)
    )
  end

  @doc "Checks one asset's supply and account balances in a single database snapshot."
  @spec reconcile(String.t()) :: {:ok, map()} | {:error, :not_found}
  def reconcile(point_id) do
    sql = """
    WITH entries AS (
      SELECT account_id,
        COALESCE(SUM(delta) FILTER (WHERE bucket = 'available'), 0) AS available,
        COALESCE(SUM(delta) FILTER (WHERE bucket = 'held'), 0) AS held
      FROM point_entries WHERE point_id = $1 GROUP BY account_id
    ), accounts AS (
      SELECT a.id, a.owner_type, COALESCE(b.available, 0) AS available,
        COALESCE(b.held, 0) AS held,
        COALESCE(b.available, 0) <> COALESCE(e.available, 0)
          OR COALESCE(b.held, 0) <> COALESCE(e.held, 0) AS mismatch
      FROM point_accounts a
      LEFT JOIN point_balances b ON b.account_id = a.id
      LEFT JOIN entries e ON e.account_id = a.id
      WHERE a.point_id = $1
    ), unbalanced AS (
      SELECT transaction_id FROM point_entries WHERE point_id = $1
      GROUP BY transaction_id HAVING SUM(delta) <> 0
    )
    SELECT i.issued, i.burned,
      COALESCE(SUM(a.available::numeric + a.held) FILTER (WHERE a.owner_type <> 'system'), 0),
      COALESCE(SUM(a.available::numeric + a.held) FILTER (WHERE a.owner_type = 'system'), 0),
      COALESCE(ARRAY_AGG(a.id ORDER BY a.id) FILTER (WHERE a.mismatch), ARRAY[]::varchar[]),
      (SELECT COUNT(*) FROM unbalanced)
    FROM point_issuers i LEFT JOIN accounts a ON TRUE
    WHERE i.point_id = $1 GROUP BY i.id
    """

    case Repo.query!(sql, [point_id]).rows do
      [[issued, burned, circulating, system, mismatches, unbalanced]] ->
        circulating = Decimal.to_integer(circulating)
        system = Decimal.to_integer(system)
        expected = issued - burned

        {:ok,
         %{
           issued: issued,
           burned: burned,
           circulating: circulating,
           system: system,
           mismatched_accounts: mismatches,
           unbalanced_transactions: unbalanced,
           ok?:
             circulating == expected and system == -expected and mismatches == [] and
               unbalanced == 0
         }}

      [] ->
        {:error, :not_found}
    end
  end

  defp valid_id?(id), do: is_binary(id) and Tsid.valid?(id)
end

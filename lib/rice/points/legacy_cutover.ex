defmodule Rice.Points.LegacyCutover do
  @moduledoc "Database-wide switch from the legacy grain ledger to an imported Point asset."

  import Ecto.Query

  alias Rice.Points.{Entry, Hold, LegacySnapshot, Point, Queries, Transaction}
  alias Rice.Grains
  alias Rice.Grains.{Receipt, Transfer}
  alias Rice.{Repo, Tsid}

  @doc "Reads the active database switch, with a local rehearsal override."
  @spec point_id() :: String.t() | nil
  def point_id do
    case Repo.query!("SELECT point_id FROM point_legacy_cutover WHERE singleton").rows do
      [[id]] -> id
      [] -> Application.get_env(:rice, :point_legacy_hold_asset)
    end
  end

  @doc "Imports opening balances and enables the write guard in the same transaction."
  @spec activate(String.t()) :: {:ok, map()} | {:error, atom()}
  def activate(id) do
    Repo.transaction(
      fn ->
        lock_cutover!()
        if marker(), do: Repo.rollback(:legacy_cutover_active)

        case LegacySnapshot.import_opening(id) do
          {:ok, audit} ->
            Repo.query!("INSERT INTO point_legacy_cutover (point_id) VALUES ($1)", [id])
            audit

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end,
      timeout: :infinity
    )
  end

  @doc "Reopens legacy writes only if the new ledger has no post-cutover transactions."
  @spec rollback_before_writes(String.t()) :: {:ok, :rolled_back} | {:error, atom()}
  def rollback_before_writes(id) do
    if is_binary(id) and Tsid.valid?(id) do
      Repo.transaction(fn ->
        lock_cutover!()
        if marker() != id, do: Repo.rollback(:legacy_cutover_not_found)
        point = Repo.one!(from p in Point, where: p.id == ^id, lock: "FOR UPDATE")

        if Repo.exists?(
             from t in Transaction,
               where:
                 t.point_id == ^id and
                   t.kind not in ["legacy_opening", "legacy_opening_hold"]
           ),
           do: Repo.rollback(:point_ledger_has_writes)

        Repo.update!(Ecto.Changeset.change(point, status: "disabled"))
        Repo.query!("DELETE FROM point_legacy_cutover WHERE singleton")
        :rolled_back
      end)
    else
      {:error, :legacy_cutover_not_found}
    end
  end

  @doc """
  Produces a reconciliation snapshot before a post-write rollback. The caller must
  keep writes paused from the final report through replay and verification.
  """
  @spec rollback_report(String.t()) :: {:ok, map()} | {:error, atom()}
  def rollback_report(id) do
    if is_binary(id) and Tsid.valid?(id) do
      Repo.transaction(
        fn ->
          lock_cutover!()
          if marker() != id, do: Repo.rollback(:legacy_cutover_not_found)
          Repo.one!(from p in Point, where: p.id == ^id, lock: "FOR UPDATE")
          {:ok, target} = Queries.reconcile(id)

          transactions =
            Repo.all(
              from t in Transaction,
                where:
                  t.point_id == ^id and t.kind not in ["legacy_opening", "legacy_opening_hold"],
                order_by: t.id,
                select: %{
                  id: t.id,
                  kind: t.kind,
                  reference_type: t.reference_type,
                  reference_id: t.reference_id,
                  business_outcome_uri: t.business_outcome_uri
                }
            )

          holds =
            Repo.all(
              from h in Hold,
                join: t in Transaction,
                on: t.id == h.reservation_transaction_id,
                where: h.point_id == ^id and h.remaining_amount > 0,
                order_by: h.id,
                select: %{
                  id: h.id,
                  account_id: h.payer_account_id,
                  remaining: h.remaining_amount,
                  reservation_transaction_id: t.id,
                  reference_type: t.reference_type,
                  reference_id: t.reference_id
                }
            )

          %{
            legacy: LegacySnapshot.audit(),
            point: target,
            account_deltas: account_deltas(id),
            transactions: transactions,
            open_holds: holds,
            can_rollback_directly?: transactions == []
          }
        end,
        timeout: :infinity
      )
    else
      {:error, :legacy_cutover_not_found}
    end
  end

  @doc """
  Replays representable legacy transfers and business holds, then reopens the old ledger.
  The reviewed transaction IDs must match the locked ledger exactly.
  """
  @spec rollback_with_replay(String.t(), [String.t()]) ::
          {:ok, :rolled_back} | {:error, atom()}
  def rollback_with_replay(id, reviewed_ids) when is_list(reviewed_ids) do
    if is_binary(id) and Tsid.valid?(id) do
      Repo.transaction(
        fn ->
          lock_cutover!()
          if marker() != id, do: Repo.rollback(:legacy_cutover_not_found)

          Repo.query!(
            "LOCK TABLE users, nodes, grain_transfers, grain_receipts IN SHARE ROW EXCLUSIVE MODE"
          )

          point = Repo.one!(from p in Point, where: p.id == ^id, lock: "FOR UPDATE")

          transactions =
            Repo.all(
              from t in Transaction,
                where:
                  t.point_id == ^id and t.kind not in ["legacy_opening", "legacy_opening_hold"],
                order_by: t.id
            )

          if Enum.map(transactions, & &1.id) != reviewed_ids,
            do: Repo.rollback(:rollback_report_stale)

          {:ok, %{ok?: point_ok?, issued: issued, burned: burned}} = Queries.reconcile(id)
          source = LegacySnapshot.audit()

          unless point_ok? and source.ok? and issued == source.granted and burned == 0,
            do: Repo.rollback(:rollback_reconciliation_failed)

          if Application.get_env(:rice, :point_legacy_hold_asset),
            do: Repo.rollback(:rehearsal_override_active)

          Repo.query!("DELETE FROM point_legacy_cutover WHERE singleton")
          Enum.each(transactions, &replay!/1)

          unless account_deltas(id) == [] and LegacySnapshot.audit().ok?,
            do: Repo.rollback(:rollback_reconciliation_failed)

          Repo.update!(Ecto.Changeset.change(point, status: "disabled"))
          :rolled_back
        end,
        timeout: :infinity
      )
    else
      {:error, :legacy_cutover_not_found}
    end
  end

  def rollback_with_replay(_, _), do: {:error, :rollback_report_stale}

  defp replay!(
         %Transaction{kind: "hold_reserve", reference_type: "business_hold", reference_id: uri} =
           tx
       )
       when is_binary(uri) do
    case Enum.filter(replay_entries(tx), &(&1.bucket == "held")) do
      [%Entry{delta: amount, account: payer}] when amount > 0 ->
        replay_result!(Grains.reserve_business(Repo, legacy_owner!(payer), amount, uri))

      _ ->
        Repo.rollback(:unsupported_rollback_transaction)
    end
  end

  defp replay!(
         %Transaction{kind: kind, business_outcome_uri: outcome, reference_id: hold_id} = tx
       )
       when kind in ["hold_settle", "hold_release"] and is_binary(outcome) and is_binary(hold_id) do
    entries = replay_entries(tx)

    case Enum.filter(entries, &(&1.bucket == "held")) do
      [%Entry{delta: delta, account: payer}] when delta < 0 ->
        amount = -delta
        payer_id = legacy_owner!(payer)
        reservation = reservation_uri!(hold_id, tx.point_id, payer.id)
        recipient = outcome_recipient!(kind, entries, payer.id, amount)
        replay_hold_outcome!(kind, payer_id, recipient, amount, reservation, outcome)

      _ ->
        Repo.rollback(:unsupported_rollback_transaction)
    end
  end

  defp replay!(tx) do
    changeset = replay_transfer!(tx)
    Repo.insert!(changeset)
    Enum.each(replay_entries(tx), &apply_available_delta!/1)
  end

  defp replay_entries(tx) do
    Repo.all(from e in Entry, where: e.transaction_id == ^tx.id, preload: [:account])
  end

  defp reservation_uri!(hold_id, point_id, payer_id) do
    tx =
      Repo.one(
        from h in Hold,
          join: t in Transaction,
          on: h.reservation_transaction_id == t.id,
          where: h.id == ^hold_id and h.point_id == ^point_id and h.payer_account_id == ^payer_id,
          select: t
      )

    case tx do
      %Transaction{kind: "legacy_opening_hold", reference_id: id} ->
        Repo.get!(Receipt, id).subject_uri

      %Transaction{kind: "hold_reserve", reference_type: "business_hold", reference_id: uri} ->
        uri

      _ ->
        Repo.rollback(:unsupported_rollback_transaction)
    end
  end

  defp outcome_recipient!(kind, entries, payer, amount) do
    case {kind, Enum.filter(entries, &(&1.bucket == "available"))} do
      {"hold_release", [%Entry{account_id: ^payer, delta: ^amount}]} -> nil
      {"hold_settle", [%Entry{account: account, delta: ^amount}]} -> legacy_owner!(account)
      _ -> Repo.rollback(:unsupported_rollback_transaction)
    end
  end

  defp replay_hold_outcome!("hold_release", payer, nil, amount, uri, uri),
    do: replay_result!(Grains.refund_business(Repo, payer, amount, uri))

  defp replay_hold_outcome!("hold_settle", payer, recipient, amount, uri, uri),
    do: replay_result!(Grains.settle_business(Repo, payer, recipient, amount, uri))

  defp replay_hold_outcome!(kind, payer, recipient, amount, uri, outcome) do
    legacy_kind = if kind == "hold_settle", do: "settled", else: "refunded"

    replay_result!(
      Grains.draw_reservation(Repo, payer, recipient, amount, uri, outcome, legacy_kind)
    )
  end

  defp replay_result!({:ok, _}), do: :ok
  defp replay_result!({:error, _}), do: Repo.rollback(:rollback_reconciliation_failed)

  defp legacy_owner!(%{owner_type: "user", owner_id: id}), do: id
  defp legacy_owner!(%{owner_type: "node", owner_id: id}), do: {:node, id}
  defp legacy_owner!(_), do: Repo.rollback(:unsupported_rollback_transaction)

  defp replay_transfer!(%Transaction{kind: "transfer", reference_type: kind} = tx)
       when kind in ["gift", "reward"] do
    rows = Repo.all(from e in Entry, where: e.transaction_id == ^tx.id, preload: [:account])

    case Enum.sort_by(rows, & &1.delta) do
      [
        %Entry{bucket: "available", delta: debit, account: payer},
        %Entry{bucket: "available", delta: credit, account: payee}
      ]
      when debit < 0 and credit == -debit and payer.owner_type in ["user", "node"] and
             payee.owner_type == "user" ->
        attrs = %{
          kind: kind,
          amount: credit,
          to_user_id: payee.owner_id,
          memo: tx.public_note || "",
          subject_uri: tx.reference_id,
          request_id: tx.idempotency_key
        }

        attrs =
          Map.put(
            attrs,
            if(payer.owner_type == "user", do: :from_user_id, else: :from_node_id),
            payer.owner_id
          )

        changeset = Transfer.changeset(%Transfer{id: tx.id, inserted_at: tx.inserted_at}, attrs)
        if changeset.valid?, do: changeset, else: Repo.rollback(:unsupported_rollback_transaction)

      _ ->
        Repo.rollback(:unsupported_rollback_transaction)
    end
  end

  defp replay_transfer!(_), do: Repo.rollback(:unsupported_rollback_transaction)

  defp apply_available_delta!(%Entry{account: account, delta: delta}) do
    schema = if account.owner_type == "user", do: Rice.Accounts.User, else: Rice.Community.Node
    minimum = max(0, -delta)

    case Repo.update_all(
           from(a in schema, where: a.id == ^account.owner_id and a.grain_balance >= ^minimum),
           inc: [grain_balance: delta]
         ) do
      {1, _} -> :ok
      _ -> Repo.rollback(:rollback_reconciliation_failed)
    end
  end

  defp account_deltas(id) do
    sql = """
    WITH old_balances AS (
      SELECT 'user' AS owner_type, id AS owner_id, grain_balance AS available, grain_frozen_balance AS held FROM users
      UNION ALL
      SELECT 'node', id, grain_balance, grain_frozen_balance FROM nodes
    ), new_balances AS (
      SELECT a.owner_type, a.owner_id, COALESCE(b.available, 0) AS available, COALESCE(b.held, 0) AS held
      FROM point_accounts a LEFT JOIN point_balances b ON b.account_id = a.id
      WHERE a.point_id = $1 AND a.owner_type IN ('user', 'node')
    )
    SELECT owner_type, owner_id, COALESCE(o.available, 0), COALESCE(n.available, 0),
      COALESCE(o.held, 0), COALESCE(n.held, 0)
    FROM old_balances o FULL JOIN new_balances n USING (owner_type, owner_id)
    WHERE COALESCE(o.available, 0) <> COALESCE(n.available, 0)
       OR COALESCE(o.held, 0) <> COALESCE(n.held, 0)
    ORDER BY owner_type, owner_id
    """

    for [type, owner, old_available, new_available, old_held, new_held] <-
          Repo.query!(sql, [id]).rows do
      %{
        owner_type: type,
        owner_id: owner,
        old_available: old_available,
        new_available: new_available,
        available_delta: new_available - old_available,
        old_held: old_held,
        new_held: new_held,
        held_delta: new_held - old_held
      }
    end
  end

  defp lock_cutover! do
    Repo.query!("LOCK TABLE point_legacy_cutover IN SHARE ROW EXCLUSIVE MODE")
  end

  defp marker do
    case Repo.query!("SELECT point_id FROM point_legacy_cutover WHERE singleton").rows do
      [[id]] -> id
      [] -> nil
    end
  end
end

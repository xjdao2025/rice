defmodule Rice.Points.LegacySnapshot do
  @moduledoc "Preflight and opening balance import for the legacy Rice ledger."

  alias Rice.Repo

  import Ecto.Query

  alias Rice.Points.{Account, Balance, Entry, Hold, Issuer, Point, Queries, Transaction}
  alias Rice.{Repo, Tsid}

  @max_amount 9_223_372_036_854_775_807

  @snapshot """
  WITH accounts AS (
    SELECT 'user' AS owner_type, id, grain_balance AS available, grain_frozen_balance AS frozen FROM users
    UNION ALL
    SELECT 'node', id, grain_balance, grain_frozen_balance FROM nodes
  ), outcomes AS (
    SELECT o.id, o.amount, matched.id AS reservation_id
    FROM grain_receipts o
    LEFT JOIN LATERAL (
      SELECT r.id FROM grain_receipts r
      WHERE r.kind = 'reserved'
        AND r.from_user_id IS NOT DISTINCT FROM o.from_user_id
        AND r.from_node_id IS NOT DISTINCT FROM o.from_node_id
        AND (r.subject_uri = o.subject_uri OR starts_with(o.subject_uri, r.subject_uri || '/'))
      ORDER BY length(r.subject_uri) DESC, r.id
      LIMIT 1
    ) matched ON TRUE
    WHERE o.kind IN ('settled', 'refunded')
  ), holds AS (
    SELECT r.id, r.subject_uri, r.amount AS original_amount,
      CASE WHEN r.from_node_id IS NULL THEN 'user' ELSE 'node' END AS owner_type,
      COALESCE(r.from_node_id, r.from_user_id) AS owner_id,
      r.amount - COALESCE(SUM(o.amount), 0) AS remaining
    FROM grain_receipts r LEFT JOIN outcomes o ON o.reservation_id = r.id
    WHERE r.kind = 'reserved'
    GROUP BY r.id
  )
  """

  @doc "Audits legacy supply and outstanding reservations in a single snapshot."
  @spec audit() :: map()
  def audit do
    sql =
      @snapshot <>
        """
        , frozen_by_account AS (
          SELECT owner_type, owner_id, SUM(remaining) AS remaining
          FROM holds WHERE remaining > 0 GROUP BY owner_type, owner_id
        ), mismatches AS (
          SELECT COALESCE(a.owner_type, h.owner_type) AS owner_type,
            COALESCE(a.id, h.owner_id) AS owner_id
          FROM accounts a FULL JOIN frozen_by_account h
            ON h.owner_type = a.owner_type AND h.owner_id = a.id
          WHERE COALESCE(a.frozen, 0) <> COALESCE(h.remaining, 0)
        )
        SELECT
          (SELECT COALESCE(SUM(available), 0) FROM accounts),
          (SELECT COALESCE(SUM(frozen), 0) FROM accounts),
          (SELECT COALESCE(SUM(amount), 0) FROM grain_transfers WHERE kind = 'grant'),
          (SELECT COUNT(*) FROM holds WHERE remaining > 0),
          (SELECT COUNT(*) FROM holds WHERE remaining < 0),
          (SELECT COUNT(*) FROM outcomes WHERE reservation_id IS NULL),
          (SELECT COUNT(*) FROM accounts WHERE available < 0 OR frozen < 0),
          (SELECT COALESCE(ARRAY_AGG(owner_type || ':' || owner_id ORDER BY owner_type, owner_id), ARRAY[]::text[]) FROM mismatches)
        """

    %{rows: [[available, frozen, granted, open, overdrawn, unmatched, negative, mismatches]]} =
      Repo.query!(sql)

    available = Decimal.to_integer(available)
    frozen = Decimal.to_integer(frozen)
    granted = Decimal.to_integer(granted)

    %{
      available: available,
      frozen: frozen,
      granted: granted,
      open_holds: open,
      overdrawn_holds: overdrawn,
      unmatched_outcomes: unmatched,
      negative_accounts: negative,
      mismatched_accounts: mismatches,
      ok?:
        available + frozen == granted and overdrawn == 0 and unmatched == 0 and negative == 0 and
          mismatches == []
    }
  end

  @doc """
  Imports opening balances and unfinished holds into a fresh, bootstrapped asset.
  Run during a write pause that spans import and cutover. The source ledger is retained.
  """
  @spec import_opening(String.t()) :: {:ok, map()} | {:error, atom()}
  def import_opening(point_id) do
    if is_binary(point_id) and Tsid.valid?(point_id) do
      Repo.transaction(
        fn ->
          Repo.query!("LOCK TABLE users, nodes, grain_transfers, grain_receipts IN SHARE MODE")

          point =
            Repo.one(from p in Point, where: p.id == ^point_id, lock: "FOR UPDATE") ||
              Repo.rollback(:point_not_found)

          issuer = Repo.get_by(Issuer, point_id: point_id) || Repo.rollback(:issuer_not_found)
          validate_target!(point, issuer)
          source = audit()
          unless source.ok?, do: Repo.rollback(:legacy_reconciliation_failed)

          if source.granted > (issuer.supply_cap || @max_amount),
            do: Repo.rollback(:supply_cap_exceeded)

          accounts = import_accounts!(point_id, issuer, source.available, source.granted)
          import_holds!(point_id, issuer.account_id, accounts)

          Repo.update!(Ecto.Changeset.change(issuer, issued: source.granted))
          Repo.update!(Ecto.Changeset.change(point, status: "active"))

          case Queries.reconcile(point_id) do
            {:ok, %{ok?: true} = reconciliation} -> reconciliation
            _ -> Repo.rollback(:point_reconciliation_failed)
          end
        end,
        timeout: :infinity
      )
    else
      {:error, :point_not_found}
    end
  end

  defp validate_target!(point, issuer) do
    treasury = Repo.get!(Account, issuer.account_id)
    balance = Repo.get_by!(Balance, account_id: treasury.id)

    if point.status != "draft" or issuer.issued != 0 or issuer.burned != 0 or
         treasury.owner_type != "system" or balance.available != 0 or balance.held != 0 or
         Repo.exists?(from a in Account, where: a.point_id == ^point.id and a.id != ^treasury.id) or
         Repo.exists?(from t in Transaction, where: t.point_id == ^point.id) do
      Repo.rollback(:point_not_empty)
    end
  end

  defp import_accounts!(point_id, issuer, available_total, granted) do
    rows = Repo.query!(@snapshot <> "SELECT owner_type, id, available, frozen FROM accounts").rows

    transaction =
      if available_total > 0 do
        tx =
          Repo.insert!(%Transaction{
            point_id: point_id,
            kind: "legacy_opening",
            reference_type: "legacy_ledger"
          })

        entry!(tx, issuer.account_id, "available", -available_total)
        tx
      end

    accounts =
      Map.new(rows, fn [type, owner_id, available, frozen] ->
        account = Repo.insert!(%Account{point_id: point_id, owner_type: type, owner_id: owner_id})

        Repo.insert!(%Balance{
          account_id: account.id,
          owner_type: type,
          available: available,
          held: frozen
        })

        if available > 0, do: entry!(transaction, account.id, "available", available)
        {{type, owner_id}, account.id}
      end)

    issuer_balance = Repo.get_by!(Balance, account_id: issuer.account_id)
    Repo.update!(Ecto.Changeset.change(issuer_balance, available: -granted))
    accounts
  end

  defp import_holds!(point_id, issuer_id, accounts) do
    rows =
      Repo.query!(
        @snapshot <>
          "SELECT id, subject_uri, original_amount, owner_type, owner_id, remaining FROM holds WHERE remaining > 0"
      ).rows

    for [receipt_id, uri, original, type, owner_id, remaining] <- rows do
      amount = Decimal.to_integer(remaining)
      account_id = Map.fetch!(accounts, {type, owner_id})

      tx =
        Repo.insert!(%Transaction{
          point_id: point_id,
          kind: "legacy_opening_hold",
          reference_type: "legacy_grain_receipt",
          reference_id: receipt_id,
          public_note: nil,
          private_note: uri
        })

      entry!(tx, issuer_id, "available", -amount)
      entry!(tx, account_id, "held", amount)

      Repo.insert!(%Hold{
        point_id: point_id,
        payer_account_id: account_id,
        reservation_transaction_id: tx.id,
        original_amount: original,
        remaining_amount: amount
      })
    end
  end

  defp entry!(tx, account_id, bucket, delta) do
    Repo.insert!(%Entry{
      point_id: tx.point_id,
      transaction_id: tx.id,
      account_id: account_id,
      bucket: bucket,
      delta: delta
    })
  end
end

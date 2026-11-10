defmodule Rice.Points.LegacyHolds do
  @moduledoc "Routes an unfinished legacy reservation to its imported Point hold."

  import Ecto.Query

  alias Rice.{Points, Repo}
  alias Rice.Grains.Receipt
  alias Rice.Points.{Account, Hold, Point, Transaction}

  @type owner :: String.t() | {:node, String.t()}
  @type request :: %{
          required(:reservation_uri) => String.t(),
          required(:outcome_uri) => String.t(),
          required(:actor_id) => String.t(),
          required(:amount) => pos_integer(),
          optional(:recipient) => owner() | nil
        }

  @doc "Opens a Point hold for a legacy business subject after ledger cutover."
  @spec reserve(String.t(), owner(), String.t(), pos_integer(), String.t()) ::
          {:ok, map()} | {:error, atom()}
  def reserve(point_id, payer, actor_id, amount, uri)
      when is_binary(uri) and byte_size(uri) in 1..255 do
    with {:ok, account} <- account(point_id, payer) do
      Repo.transaction(fn ->
        Repo.one!(from p in Point, where: p.id == ^point_id, lock: "FOR UPDATE")

        if Repo.exists?(from r in Receipt, where: r.subject_uri == ^uri and r.kind == "reserved"),
          do: Repo.rollback(:conflict)

        case find(point_id, uri) do
          {:ok, %Hold{payer_account_id: id, original_amount: original}}
          when id != account.id or original != amount ->
            Repo.rollback(:conflict)

          _ ->
            :ok
        end

        key = "business:" <> Base.url_encode64(:crypto.hash(:sha256, uri), padding: false)

        case Points.move_hold(:reserve, %{
               payer_account_id: account.id,
               actor_id: actor_id,
               idempotency_key: key,
               amount: amount,
               business_reference: uri
             }) do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  def reserve(_, _, _, _, _), do: {:error, :invalid_hold_request}

  @doc "Checks that a business payer owns the Point hold."
  @spec owned_by?(Hold.t(), owner()) :: boolean()
  def owned_by?(hold, payer) do
    case account(hold.point_id, payer) do
      {:ok, account} -> account.id == hold.payer_account_id
      _ -> false
    end
  end

  @doc "Settles or refunds an imported reservation using the original business URIs."
  @spec move(String.t(), :settle | :release, request()) ::
          {:ok, %{hold: Hold.t(), transaction: Transaction.t()}} | {:error, atom()}
  def move(
        point_id,
        action,
        %{
          reservation_uri: reservation_uri,
          outcome_uri: outcome_uri,
          actor_id: actor_id,
          amount: amount
        } = request
      )
      when action in [:settle, :release] and is_binary(reservation_uri) and is_binary(outcome_uri) do
    with {:ok, hold} <- find(point_id, reservation_uri),
         :ok <- ensure_outcome_scope(reservation_uri, outcome_uri),
         :ok <- ensure_outcome_unused(outcome_uri),
         {:ok, details} <- details(point_id, action, request) do
      key = "legacy:" <> Base.url_encode64(:crypto.hash(:sha256, outcome_uri), padding: false)

      Points.move_hold(
        action,
        Map.merge(details, %{
          payer_account_id: hold.payer_account_id,
          hold_id: hold.id,
          actor_id: actor_id,
          idempotency_key: key,
          business_reference: reservation_uri,
          exclusive_outcome: true,
          business_outcome_uri: outcome_uri,
          amount: amount
        })
      )
    end
  end

  def move(_, _, _), do: {:error, :invalid_hold_request}

  @doc "Resolves a legacy business URI to its imported hold."
  @spec find(String.t(), String.t()) :: {:ok, Hold.t()} | {:error, :grain_reservation_missing}
  def find(point_id, reservation_uri) do
    hold =
      Repo.one(
        from h in Hold,
          join: tx in Transaction,
          on: tx.id == h.reservation_transaction_id,
          left_join: receipt in Receipt,
          on: tx.reference_type == "legacy_grain_receipt" and receipt.id == tx.reference_id,
          where: h.point_id == ^point_id,
          where:
            (tx.kind == "legacy_opening_hold" and receipt.kind == "reserved" and
               receipt.subject_uri == ^reservation_uri) or
              (tx.kind == "hold_reserve" and tx.reference_type == "business_hold" and
                 tx.reference_id == ^reservation_uri)
      )

    case hold do
      %Hold{} -> {:ok, hold}
      nil -> {:error, :grain_reservation_missing}
    end
  end

  defp ensure_outcome_scope(uri, outcome) do
    if outcome == uri or String.starts_with?(outcome, uri <> "/"),
      do: :ok,
      else: {:error, :invalid_hold_request}
  end

  defp ensure_outcome_unused(uri) do
    if Repo.exists?(
         from r in Receipt, where: r.subject_uri == ^uri and r.kind in ["settled", "refunded"]
       ),
       do: {:error, :legacy_outcome_already_recorded},
       else: :ok
  end

  defp details(_, :release, request) when not is_map_key(request, :recipient), do: {:ok, %{}}
  defp details(_, :release, %{recipient: nil}), do: {:ok, %{}}

  defp details(point_id, :settle, %{recipient: recipient, amount: amount}) do
    with {:ok, account} <- Rice.Points.WalletAccounts.ensure_recipient(point_id, recipient) do
      {:ok, %{recipients: [%{account_id: account.id, amount: amount}]}}
    end
  end

  defp details(_, _, _), do: {:error, :invalid_hold_request}

  defp account(point_id, payer) do
    with {:ok, type, id} <- owner(payer),
         %Account{} = account <-
           Repo.get_by(Account, point_id: point_id, owner_type: type, owner_id: id) do
      {:ok, account}
    else
      _ -> {:error, :account_not_found}
    end
  end

  defp owner({:node, id}) when is_binary(id), do: {:ok, "node", id}
  defp owner(id) when is_binary(id), do: {:ok, "user", id}
  defp owner(_), do: :error
end

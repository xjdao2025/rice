defmodule Rice.Points do
  @moduledoc """
  Internal points ledger. Callers must authenticate and authorize spending before
  calling the ledger. Returned structs are internal, including private notes.
  """

  import Ecto.Query

  alias Rice.Points.{Account, Balance, Entry, Hold, Point, Recipient, Transaction}
  alias Rice.Points.{Issuance, IssuanceApproval, IssuancePolicy, IssuanceSigner, Issuer}
  alias Rice.Points.{SpendApproval, SpendPolicy, SpendProposal, SpendSigner}
  alias Rice.{Repo, Tsid}

  @max_amount 9_223_372_036_854_775_807
  @type recipient :: %{
          required(:account_id) => String.t(),
          required(:amount) => pos_integer(),
          optional(:note) => String.t() | nil
        }
  @type transfer_request :: %{
          required(:payer_account_id) => String.t(),
          required(:actor_id) => String.t(),
          required(:idempotency_key) => String.t(),
          required(:recipients) => [recipient()],
          optional(:public_note) => String.t() | nil,
          optional(:private_note) => String.t() | nil,
          optional(:reference_type) => String.t() | nil,
          optional(:reference_id) => String.t() | nil,
          optional(:action) => String.t(),
          optional(:business_reference) => String.t() | nil
        }

  @doc "Posts a balanced batch transfer, or returns the original transaction on an identical retry."
  @spec transfer(transfer_request()) :: {:ok, Transaction.t()} | {:error, atom()}
  def transfer(request) do
    with {:ok, batch} <- normalize(request) do
      Repo.transaction(fn -> post(batch) end)
    end
  end

  @doc "Installs a first treasury policy after the caller verifies governance authorization."
  @spec bootstrap_spend_policy(String.t(), String.t(), pos_integer(), [String.t()]) ::
          {:ok, SpendPolicy.t()} | {:error, atom()}
  def bootstrap_spend_policy(point_id, account_id, threshold, signers) do
    if valid_id?(point_id) and valid_id?(account_id) and is_list(signers) and
         is_integer(threshold) and threshold >= 2 and threshold <= length(signers) and
         Enum.uniq(signers) == signers and Enum.all?(signers, &valid_id?/1) do
      Repo.transaction(fn ->
        point = lock_point!(point_id)

        account =
          Repo.get_by(Account, id: account_id, point_id: point.id) ||
            Repo.rollback(:account_not_found)

        if account.owner_type != "node", do: Repo.rollback(:invalid_treasury_account)

        if Repo.exists?(from p in SpendPolicy, where: p.account_id == ^account.id),
          do: Repo.rollback(:spend_policy_exists)

        eligible =
          Repo.aggregate(
            from(u in Rice.Accounts.User,
              where: u.id in ^signers and is_nil(u.deleted_at) and is_nil(u.disabled_at)
            ),
            :count
          )

        if eligible != length(signers), do: Repo.rollback(:invalid_spend_signers)

        policy =
          Repo.insert!(%SpendPolicy{
            point_id: point.id,
            account_id: account.id,
            current: true,
            threshold: threshold,
            version: 1
          })

        for signer <- signers,
            do: Repo.insert!(%SpendSigner{policy_id: policy.id, user_id: signer})

        policy
      end)
    else
      {:error, :invalid_spend_policy}
    end
  end

  @doc "Stores an immutable treasury transfer or reservation under the current spend policy."
  @spec propose_spend(String.t(), transfer_request(), DateTime.t()) ::
          {:ok, SpendProposal.t()} | {:error, atom()}
  def propose_spend(point_id, request, %DateTime{} = expires_at) do
    action = Map.get(request, :action, "transfer")
    reference = Map.get(request, :business_reference)

    with true <- valid_id?(point_id),
         :ok <- validate_spend_action(action, reference),
         {:ok, batch} <- normalize(request) do
      Repo.transaction(fn ->
        point = lock_point!(point_id)
        policy = current_spend_policy!(point.id, batch.payer)
        spend_signer!(policy, batch.actor)

        hash =
          Base.encode16(
            :crypto.hash(
              :sha256,
              :erlang.term_to_binary({action, reference, batch.hash, expires_at})
            )
          )

        case Repo.get_by(SpendProposal,
               account_id: batch.payer,
               proposer_id: batch.actor,
               idempotency_key: batch.key
             ) do
          %SpendProposal{request_hash: ^hash} = proposal ->
            proposal

          %SpendProposal{} ->
            Repo.rollback(:idempotency_conflict)

          nil ->
            ensure_spend_unexpired!(expires_at)
            accounts = lock_accounts(batch)
            validate_accounts!(point, accounts, account_ids(batch))

            Repo.insert!(%SpendProposal{
              point_id: point.id,
              account_id: batch.payer,
              policy_id: policy.id,
              proposer_id: batch.actor,
              action: action,
              amount: batch.total,
              idempotency_key: batch.key,
              request_hash: hash,
              expires_at: expires_at,
              payload: %{
                "business_reference" => reference,
                "public_note" => batch.public_note,
                "private_note" => batch.private_note,
                "items" =>
                  Enum.map(batch.items, fn {id, amount, note} ->
                    %{"account_id" => id, "amount" => amount, "note" => note}
                  end)
              }
            })
        end
      end)
    else
      false -> {:error, :point_not_found}
      error -> error
    end
  end

  defp validate_spend_action("transfer", nil), do: :ok

  defp validate_spend_action("reserve", reference) do
    if is_binary(reference) and valid_note?(reference) and String.trim(reference) != "",
      do: :ok,
      else: {:error, :invalid_spend_proposal}
  end

  defp validate_spend_action(_, _), do: {:error, :invalid_spend_proposal}

  @doc "Proposes a treasury policy replacement under the current policy."
  @spec propose_spend_policy(String.t(), map()) :: {:ok, SpendProposal.t()} | {:error, atom()}
  def propose_spend_policy(point_id, %{
        payer_account_id: account_id,
        actor_id: actor,
        idempotency_key: key,
        expires_at: %DateTime{} = expires_at,
        threshold: threshold,
        signers: signers
      }) do
    if Enum.all?([point_id, account_id, actor], &valid_id?/1) and valid_key?(key) and
         valid_spend_policy_change?(threshold, signers) do
      payload = %{"threshold" => threshold, "signers" => Enum.sort(signers)}

      hash =
        Base.encode16(
          :crypto.hash(:sha256, :erlang.term_to_binary({"policy_change", payload, expires_at}))
        )

      Repo.transaction(fn ->
        point = lock_point!(point_id)
        policy = current_spend_policy!(point.id, account_id)
        spend_signer!(policy, actor)

        case Repo.get_by(SpendProposal,
               account_id: account_id,
               proposer_id: actor,
               idempotency_key: key
             ) do
          %SpendProposal{request_hash: ^hash} = proposal ->
            proposal

          %SpendProposal{} ->
            Repo.rollback(:idempotency_conflict)

          nil ->
            ensure_spend_unexpired!(expires_at)

            Repo.insert!(%SpendProposal{
              point_id: point.id,
              account_id: account_id,
              policy_id: policy.id,
              proposer_id: actor,
              action: "policy_change",
              amount: 0,
              payload: payload,
              request_hash: hash,
              idempotency_key: key,
              expires_at: expires_at
            })
        end
      end)
    else
      {:error, :invalid_spend_policy}
    end
  end

  def propose_spend_policy(_, _), do: {:error, :invalid_spend_policy}

  defp valid_spend_policy_change?(nil, []), do: true

  defp valid_spend_policy_change?(threshold, signers)
       when is_integer(threshold) and threshold >= 2 and is_list(signers) do
    threshold <= length(signers) and Enum.uniq(signers) == signers and
      Enum.all?(signers, &valid_id?/1)
  end

  defp valid_spend_policy_change?(_, _), do: false

  @doc "Checks that a current signer can request or submit a treasury approval."
  @spec authorize_spend_approval(String.t(), String.t(), String.t()) ::
          {:ok, :authorized} | {:error, atom()}
  def authorize_spend_approval(point_id, proposal_id, signer_id) do
    if Enum.all?([point_id, proposal_id, signer_id], &valid_id?/1) do
      Repo.transaction(fn ->
        lock_point!(point_id)
        {proposal, _, _} = authorized_spend!(point_id, proposal_id, signer_id)
        if proposal.transaction_id, do: Repo.rollback(:spend_already_executed)
        ensure_spend_unexpired!(proposal.expires_at)
        :authorized
      end)
    else
      {:error, :spend_proposal_not_found}
    end
  end

  @doc "Records a treasury approval after the caller verifies recent authentication."
  @spec approve_spend(String.t(), String.t(), String.t()) ::
          {:ok, SpendProposal.t()} | {:error, atom()}
  def approve_spend(point_id, proposal_id, signer_id) do
    Repo.transaction(fn ->
      lock_point!(point_id)
      {proposal, policy, signer} = authorized_spend!(point_id, proposal_id, signer_id)

      if is_nil(proposal.transaction_id) do
        ensure_spend_unexpired!(proposal.expires_at)

        Repo.insert!(
          %SpendApproval{policy_id: policy.id, proposal_id: proposal.id, signer_id: signer.id},
          on_conflict: :nothing,
          conflict_target: [:proposal_id, :signer_id]
        )
      end

      proposal
    end)
  end

  @doc "Executes a treasury transfer once, after checking the current policy and quorum."
  @spec execute_spend(String.t(), String.t(), String.t()) ::
          {:ok, SpendProposal.t()} | {:error, atom()}
  def execute_spend(point_id, proposal_id, signer_id) do
    result =
      Repo.transaction(fn ->
        point = lock_point!(point_id)
        {proposal, policy, _signer} = authorized_spend!(point_id, proposal_id, signer_id)

        if proposal.transaction_id do
          proposal
        else
          ensure_spend_unexpired!(proposal.expires_at)

          count =
            Repo.aggregate(
              from(a in SpendApproval,
                join: s in SpendSigner,
                on: s.id == a.signer_id,
                join: u in Rice.Accounts.User,
                on: u.id == s.user_id,
                where:
                  a.proposal_id == ^proposal.id and is_nil(u.disabled_at) and is_nil(u.deleted_at)
              ),
              :count
            )

          if count < policy.threshold, do: Repo.rollback(:approval_threshold_not_met)

          case proposal.action do
            "policy_change" -> replace_spend_policy!(point, proposal, policy, signer_id)
            _ -> execute_spend_transfer!(point, proposal, signer_id)
          end
        end
      end)

    case result do
      {:error, reason}
      when reason in [
             :insufficient_balance,
             :balance_overflow,
             :account_not_found,
             :inactive_account_or_point,
             :invalid_spend_signers
           ] ->
        Repo.update_all(
          from(p in SpendProposal,
            where: p.point_id == ^point_id and p.id == ^proposal_id and is_nil(p.transaction_id)
          ),
          set: [execution_error: Atom.to_string(reason), updated_at: DateTime.utc_now()]
        )

      _ ->
        :ok
    end

    result
  end

  defp replace_spend_policy!(point, proposal, policy, actor) do
    %{"threshold" => threshold, "signers" => signers} = proposal.payload

    eligible =
      Repo.aggregate(
        from(u in Rice.Accounts.User,
          where: u.id in ^signers and is_nil(u.deleted_at) and is_nil(u.disabled_at)
        ),
        :count
      )

    if eligible != length(signers), do: Repo.rollback(:invalid_spend_signers)

    Repo.update!(Ecto.Changeset.change(policy, current: false))

    if threshold do
      next =
        Repo.insert!(%SpendPolicy{
          point_id: point.id,
          account_id: policy.account_id,
          version: policy.version + 1,
          threshold: threshold,
          current: true
        })

      for signer <- signers, do: Repo.insert!(%SpendSigner{policy_id: next.id, user_id: signer})
    end

    tx =
      Repo.insert!(%Transaction{
        point_id: point.id,
        kind: "spend_policy_change",
        actor_id: actor,
        reference_type: "spend_proposal",
        reference_id: proposal.id
      })

    Repo.update!(Ecto.Changeset.change(proposal, transaction_id: tx.id, execution_error: nil))
  end

  defp execute_spend_transfer!(point, %SpendProposal{action: action} = proposal, actor)
       when action in ["transfer", "reserve"] do
    %{"items" => items, "public_note" => public_note, "private_note" => private_note} =
      proposal.payload

    recipients =
      Enum.map(items, fn %{"account_id" => id, "amount" => amount, "note" => note} ->
        %{account_id: id, amount: amount, note: note}
      end)

    batch =
      normalized!(%{
        payer_account_id: proposal.account_id,
        actor_id: actor,
        idempotency_key: proposal.id,
        recipients: recipients,
        public_note: public_note,
        private_note: private_note
      })

    if batch.total != proposal.amount, do: Repo.rollback(:invalid_spend_proposal)
    accounts = lock_accounts(batch)
    validate_accounts!(point, accounts, account_ids(batch))
    ensure_spend_unexpired!(proposal.expires_at)

    tx =
      case action do
        "transfer" ->
          book!(point.id, accounts, batch, "approved_transfer")

        "reserve" ->
          tx =
            Repo.insert!(%Transaction{
              point_id: point.id,
              kind: "approved_hold_reserve",
              actor_id: actor,
              reference_type: "spend_proposal",
              reference_id: proposal.id,
              public_note: public_note,
              private_note: private_note
            })

          apply_hold(:reserve, nil, tx, accounts, batch).transaction
      end

    Repo.update!(Ecto.Changeset.change(proposal, transaction_id: tx.id, execution_error: nil))
  end

  defp execute_spend_transfer!(_, _, _), do: Repo.rollback(:invalid_spend_proposal)

  defp authorized_spend!(point_id, proposal_id, user_id) do
    proposal =
      Repo.get_by(SpendProposal, point_id: point_id, id: proposal_id) ||
        Repo.rollback(:spend_proposal_not_found)

    policy =
      Repo.get_by(SpendPolicy, point_id: point_id, account_id: proposal.account_id, current: true)

    if is_nil(policy) or policy.id != proposal.policy_id, do: Repo.rollback(:stale_spend_policy)
    {proposal, policy, spend_signer!(policy, user_id)}
  end

  defp spend_signer!(policy, user_id) do
    Repo.one(
      from s in SpendSigner,
        join: u in Rice.Accounts.User,
        on: s.user_id == u.id,
        where:
          s.policy_id == ^policy.id and s.user_id == ^user_id and
            is_nil(u.deleted_at) and is_nil(u.disabled_at)
    ) || Repo.rollback(:forbidden)
  end

  defp current_spend_policy!(point_id, account_id) do
    Repo.get_by(SpendPolicy, point_id: point_id, account_id: account_id, current: true) ||
      Repo.rollback(:spend_policy_not_found)
  end

  defp ensure_spend_unexpired!(expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now()) != :gt,
      do: Repo.rollback(:spend_proposal_expired)
  end

  defp require_no_spend_policy!(account_id) do
    if Repo.exists?(from p in SpendPolicy, where: p.account_id == ^account_id and p.current),
      do: Repo.rollback(:spend_approval_required)
  end

  @doc """
  Reserves, settles or releases points. The caller authorizes the business action.
  Settlement takes a recipient list. Reservation and release take an amount.
  """
  @spec move_hold(:reserve | :settle | :release, map()) ::
          {:ok, %{hold: Hold.t(), transaction: Transaction.t()}} | {:error, atom()}
  def move_hold(
        action,
        %{payer_account_id: payer, actor_id: actor, idempotency_key: key} = request
      )
      when action in [:reserve, :settle, :release] do
    with true <- valid_id?(payer) and valid_id?(actor) and valid_key?(key),
         true <- action == :reserve or valid_id?(Map.get(request, :hold_id)),
         {:ok, items, total} <- hold_amount(action, request) do
      batch = %{payer: payer, actor: actor, key: key, items: Enum.sort(items), total: total}
      Repo.transaction(fn -> post_hold(action, request, batch) end)
    else
      _ -> {:error, :invalid_hold_request}
    end
  end

  def move_hold(_, _), do: {:error, :invalid_hold_request}

  defp hold_amount(:settle, %{recipients: [_ | _] = items, payer_account_id: payer}),
    do: normalize_recipients(items, payer)

  defp hold_amount(action, %{amount: amount})
       when action in [:reserve, :release] and is_integer(amount) and amount in 1..@max_amount,
       do: {:ok, [], amount}

  defp hold_amount(_, _), do: :error

  defp valid_id?(id), do: is_binary(id) and Tsid.valid?(id)

  defp valid_key?(key),
    do:
      is_binary(key) and byte_size(key) in 1..128 and String.valid?(key) and
        not String.contains?(key, <<0>>)

  defp post_hold(action, request, batch) do
    payer = Repo.get(Account, batch.payer) || Repo.rollback(:account_not_found)
    point = Repo.one!(from p in Point, where: p.id == ^payer.point_id, lock: "FOR SHARE")
    accounts = lock_accounts(batch)
    hold_id = Map.get(request, :hold_id)
    kind = "hold_" <> Atom.to_string(action)
    reference = Map.get(request, :business_reference)
    outcome_uri = Map.get(request, :business_outcome_uri)

    hash =
      Base.encode16(
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary({1, batch.actor, batch.items, batch.total, hold_id, reference})
        )
      )

    if Map.get(request, :exclusive_outcome) do
      other = if action == :settle, do: "hold_release", else: "hold_settle"

      if Repo.exists?(
           from t in Transaction,
             where:
               t.point_id == ^point.id and t.idempotency_scope == ^payer.id and
                 t.idempotency_key == ^batch.key and t.kind == ^other
         ),
         do: Repo.rollback(:idempotency_conflict)
    end

    case Repo.get_by(Transaction,
           point_id: point.id,
           kind: kind,
           idempotency_scope: payer.id,
           idempotency_key: batch.key
         ) do
      %Transaction{request_hash: ^hash} = tx ->
        hold =
          if action == :reserve,
            do: Repo.get_by!(Hold, reservation_transaction_id: tx.id),
            else: Repo.get!(Hold, hold_id)

        %{
          hold: hold,
          transaction: Repo.preload(tx, recipients: from(r in Recipient, order_by: r.id))
        }

      %Transaction{} ->
        Repo.rollback(:idempotency_conflict)

      nil ->
        validate_accounts!(point, accounts, account_ids(batch))

        if outcome_uri &&
             Repo.exists?(
               from t in Transaction,
                 where: t.point_id == ^point.id and t.business_outcome_uri == ^outcome_uri
             ),
           do: Repo.rollback(:idempotency_conflict)

        hold = if action != :reserve, do: lock_hold!(hold_id, payer, batch.total)

        case action do
          :reserve -> require_no_spend_policy!(payer.id)
          :settle -> authorize_hold_settlement!(hold, payer, batch.items, reference)
          :release -> :ok
        end

        tx =
          Repo.insert!(%Transaction{
            point_id: point.id,
            kind: kind,
            actor_id: batch.actor,
            reference_type: if(action == :reserve and is_binary(reference), do: "business_hold"),
            reference_id: if(action == :reserve, do: reference, else: hold_id),
            business_outcome_uri: outcome_uri,
            idempotency_scope: payer.id,
            idempotency_key: batch.key,
            request_hash: hash
          })

        apply_hold(action, hold, tx, accounts, batch)
    end
  end

  defp authorize_hold_settlement!(hold, payer, items, reference) do
    case Repo.get_by(SpendProposal,
           transaction_id: hold.reservation_transaction_id,
           action: "reserve"
         ) do
      nil ->
        require_no_spend_policy!(payer.id)

      %SpendProposal{payload: %{"business_reference" => ^reference, "items" => approved}} ->
        caps =
          Enum.reduce(approved, %{}, fn %{"account_id" => id, "amount" => amount}, acc ->
            Map.update(acc, id, amount, &(&1 + amount))
          end)

        requested =
          Enum.reduce(items, %{}, fn {id, amount, _}, acc ->
            Map.update(acc, id, amount, &(&1 + amount))
          end)

        prior =
          Repo.all(
            from e in Entry,
              join: t in Transaction,
              on: t.id == e.transaction_id,
              where:
                t.point_id == ^hold.point_id and t.kind == "hold_settle" and
                  t.reference_id == ^hold.id and e.delta > 0 and e.bucket == "available",
              group_by: e.account_id,
              select: {e.account_id, sum(e.delta)}
          )
          |> Map.new(fn {id, amount} -> {id, Decimal.to_integer(amount)} end)

        unless Enum.all?(requested, fn {id, amount} ->
                 amount + Map.get(prior, id, 0) <= Map.get(caps, id, 0)
               end),
               do: Repo.rollback(:hold_recipient_limit_exceeded)

      _ ->
        Repo.rollback(:hold_business_reference_mismatch)
    end
  end

  defp lock_hold!(id, payer, amount) do
    hold =
      Repo.one(
        from h in Hold, where: h.id == ^id and h.payer_account_id == ^payer.id, lock: "FOR UPDATE"
      ) ||
        Repo.rollback(:hold_not_found)

    if hold.remaining_amount < amount, do: Repo.rollback(:hold_amount_exceeded)
    hold
  end

  defp apply_hold(:reserve, _, tx, accounts, batch) do
    payer = accounts[batch.payer]
    move_buckets!(tx, payer, -batch.total, batch.total)

    hold =
      Repo.insert!(%Hold{
        point_id: tx.point_id,
        payer_account_id: payer.id,
        reservation_transaction_id: tx.id,
        original_amount: batch.total,
        remaining_amount: batch.total
      })

    %{hold: hold, transaction: %{tx | recipients: []}}
  end

  defp apply_hold(action, hold, tx, accounts, batch) when action in [:settle, :release] do
    available_delta = if action == :release, do: batch.total, else: 0
    move_buckets!(tx, accounts[batch.payer], available_delta, -batch.total)
    recipients = credit_recipients!(tx, accounts, batch.items)
    remaining = hold.remaining_amount - batch.total
    status = if remaining == 0, do: "closed", else: "active"
    hold = Repo.update!(Ecto.Changeset.change(hold, remaining_amount: remaining, status: status))
    %{hold: hold, transaction: %{tx | recipients: recipients}}
  end

  defp move_buckets!(tx, account, available, held) do
    change_balance!(account, available, held)
    if available != 0, do: write_entry!(tx, account.id, available)
    write_entry!(tx, account.id, held, "held")
  end

  @doc """
  Retires available points from an authorized account. Callers must verify
  both the issuer's authority to retire points and the payer's spend approval.
  """
  @spec burn(String.t(), String.t(), String.t(), pos_integer(), String.t()) ::
          {:ok, Transaction.t()} | {:error, atom()}
  def burn(point_id, payer_id, actor_id, amount, key)
      when is_integer(amount) and amount in 1..@max_amount do
    if valid_id?(point_id) and valid_id?(payer_id) and valid_id?(actor_id) and valid_key?(key) do
      hash = Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary({1, actor_id, amount})))

      Repo.transaction(fn ->
        point = lock_point!(point_id)

        case Repo.get_by(Transaction,
               point_id: point.id,
               kind: "burn",
               idempotency_scope: payer_id,
               idempotency_key: key
             ) do
          %Transaction{request_hash: ^hash} = tx -> tx
          %Transaction{} -> Repo.rollback(:idempotency_conflict)
          nil -> burn!(point, payer_id, actor_id, amount, key, hash)
        end
      end)
    else
      {:error, :invalid_burn}
    end
  end

  def burn(_, _, _, _, _), do: {:error, :invalid_burn}

  defp burn!(point, payer_id, actor_id, amount, key, hash) do
    if point.status != "active", do: Repo.rollback(:inactive_account_or_point)
    issuer = Repo.get_by(Issuer, point_id: point.id) || Repo.rollback(:issuer_not_found)
    batch = %{payer: payer_id, items: [{issuer.account_id, amount, nil}]}
    accounts = lock_accounts(batch)
    validate_account_scope!(point, accounts, account_ids(batch))
    payer = accounts[payer_id]
    treasury = accounts[issuer.account_id]

    if payer.owner_type == "system" or treasury.owner_type != "system",
      do: Repo.rollback(:invalid_issuance_account)

    require_no_spend_policy!(payer.id)
    change_balance!(payer, -amount)
    burned = issuer.burned + amount
    if burned > issuer.issued, do: Repo.rollback(:burn_exceeds_issued)
    change_balance!(treasury, amount)

    tx =
      Repo.insert!(%Transaction{
        point_id: point.id,
        kind: "burn",
        actor_id: actor_id,
        idempotency_scope: payer_id,
        idempotency_key: key,
        request_hash: hash
      })

    write_entry!(tx, payer.id, -amount)
    write_entry!(tx, treasury.id, amount)
    Repo.update!(Ecto.Changeset.change(issuer, burned: burned))
    tx
  end

  @doc "Stores an issuance proposal. The caller must authorize the proposer for this asset."
  @spec propose_issuance(String.t(), String.t(), String.t(), map(), DateTime.t()) ::
          {:ok, Issuance.t()} | {:error, atom()}
  def propose_issuance(point_id, kind, reason, request, %DateTime{} = expires_at)
      when kind in ["initial_allocation", "mint"] and is_binary(reason) do
    if valid_note?(reason) and String.trim(reason) != "" do
      Repo.transaction(fn ->
        point = lock_point!(point_id)
        issuer = Repo.get_by(Issuer, point_id: point.id) || Repo.rollback(:issuer_not_found)

        request =
          Map.merge(request, %{
            payer_account_id: issuer.account_id,
            private_note: reason,
            public_note: nil
          })

        batch = normalized!(request)

        hash =
          Base.encode16(
            :crypto.hash(:sha256, :erlang.term_to_binary({kind, batch.hash, expires_at}))
          )

        case Repo.get_by(Issuance,
               point_id: point.id,
               proposer_id: batch.actor,
               idempotency_key: batch.key
             ) do
          %Issuance{request_hash: ^hash} = proposal ->
            proposal

          %Issuance{} ->
            Repo.rollback(:idempotency_conflict)

          nil ->
            ensure_unexpired!(expires_at)
            ensure_issuance_status!(point, kind)
            policy = current_policy!(point.id)
            accounts = lock_accounts(batch)
            validate_issuance_accounts!(point, issuer, accounts, batch)

            Repo.insert!(%Issuance{
              point_id: point.id,
              policy_id: policy.id,
              proposer_id: batch.actor,
              kind: kind,
              reason: reason,
              total: batch.total,
              request_hash: hash,
              idempotency_key: batch.key,
              expires_at: expires_at,
              recipients: %{
                "items" =>
                  Enum.map(batch.items, fn {id, amount, note} ->
                    %{"account_id" => id, "amount" => amount, "note" => note}
                  end)
              }
            })
        end
      end)
    else
      {:error, :invalid_issuance}
    end
  end

  @doc "Proposes a replacement issuance policy for approval by the current policy."
  @spec propose_issuance_policy(String.t(), map()) :: {:ok, Issuance.t()} | {:error, atom()}
  def propose_issuance_policy(point_id, %{
        actor_id: actor,
        idempotency_key: key,
        reason: reason,
        expires_at: %DateTime{} = expires,
        signers: signers,
        threshold: threshold,
        supply_cap: cap
      })
      when is_list(signers) and is_integer(threshold) and is_binary(reason) do
    if valid_id?(point_id) and valid_id?(actor) and valid_key?(key) and valid_note?(reason) and
         String.trim(reason) != "" and threshold >= 2 and threshold <= length(signers) and
         Enum.all?(signers, &valid_id?/1) and Enum.uniq(signers) == signers and
         (is_nil(cap) or (is_integer(cap) and cap in 0..@max_amount)) do
      payload = %{"signers" => Enum.sort(signers), "threshold" => threshold, "supply_cap" => cap}

      hash =
        Base.encode16(
          :crypto.hash(
            :sha256,
            :erlang.term_to_binary({"policy_change", payload, reason, expires})
          )
        )

      Repo.transaction(fn ->
        point = lock_point!(point_id)
        policy = current_policy!(point.id)

        unless Repo.exists?(
                 from s in IssuanceSigner,
                   where: s.policy_id == ^policy.id and s.user_id == ^actor
               ),
               do: Repo.rollback(:forbidden)

        case Repo.get_by(Issuance, point_id: point.id, proposer_id: actor, idempotency_key: key) do
          %Issuance{request_hash: ^hash} = proposal ->
            proposal

          %Issuance{} ->
            Repo.rollback(:idempotency_conflict)

          nil ->
            ensure_unexpired!(expires)

            Repo.insert!(%Issuance{
              point_id: point.id,
              policy_id: policy.id,
              proposer_id: actor,
              kind: "policy_change",
              reason: reason,
              total: 0,
              recipients: payload,
              request_hash: hash,
              idempotency_key: key,
              expires_at: expires
            })
        end
      end)
    else
      {:error, :invalid_issuance_policy}
    end
  end

  def propose_issuance_policy(_, _), do: {:error, :invalid_issuance_policy}

  @doc "Checks whether the current signer can request an issuance approval challenge."
  @spec authorize_issuance_approval(String.t(), String.t(), String.t()) ::
          {:ok, :authorized} | {:error, atom()}
  def authorize_issuance_approval(point_id, issuance_id, signer_id) do
    if Enum.all?([point_id, issuance_id, signer_id], &valid_id?/1) do
      Repo.transaction(fn ->
        {proposal, _, _} = authorized_issuance!(point_id, issuance_id, signer_id)
        if proposal.transaction_id, do: Repo.rollback(:issuance_already_executed)
        ensure_unexpired!(proposal.expires_at)
        :authorized
      end)
    else
      {:error, :issuance_not_found}
    end
  end

  @doc "Records one approval per signer. The caller must verify recent authentication."
  @spec approve_issuance(String.t(), String.t(), String.t()) ::
          {:ok, Issuance.t()} | {:error, atom()}
  def approve_issuance(point_id, issuance_id, signer_id) do
    Repo.transaction(fn ->
      {proposal, signer, _policy} = authorized_issuance!(point_id, issuance_id, signer_id)

      if is_nil(proposal.transaction_id) do
        ensure_unexpired!(proposal.expires_at)

        Repo.insert!(
          %IssuanceApproval{
            policy_id: proposal.policy_id,
            issuance_id: proposal.id,
            signer_id: signer.id
          },
          on_conflict: :nothing,
          conflict_target: [:issuance_id, :signer_id]
        )
      end

      proposal
    end)
  end

  @doc "Executes an approved issuance under the current strategy and cumulative cap."
  @spec execute_issuance(String.t(), String.t(), String.t()) ::
          {:ok, Issuance.t()} | {:error, atom()}
  def execute_issuance(point_id, issuance_id, signer_id) do
    result =
      Repo.transaction(fn ->
        point = lock_point!(point_id)
        {proposal, _signer, policy} = authorized_issuance!(point_id, issuance_id, signer_id)

        if proposal.transaction_id do
          proposal
        else
          execute_issuance!(point, proposal, policy, signer_id)
        end
      end)

    case result do
      {:error, reason}
      when reason in [
             :supply_cap_exceeded,
             :invalid_issuance_status,
             :balance_overflow,
             :account_not_found,
             :asset_mismatch,
             :inactive_account_or_point,
             :invalid_issuance_account,
             :supply_cap_below_issued,
             :invalid_issuance_signers
           ] ->
        record_issuance_failure(point_id, issuance_id, reason)

      _ ->
        :ok
    end

    result
  end

  defp record_issuance_failure(point_id, issuance_id, reason) do
    now = DateTime.utc_now()
    code = Atom.to_string(reason)

    Repo.update_all(
      from(i in Issuance,
        where:
          i.id == ^issuance_id and i.point_id == ^point_id and
            is_nil(i.transaction_id)
      ),
      set: [execution_error: code, updated_at: now]
    )
  end

  defp execute_issuance!(point, proposal, policy, actor) do
    ensure_unexpired!(proposal.expires_at)

    count =
      Repo.aggregate(
        from(a in IssuanceApproval,
          join: s in IssuanceSigner,
          on: s.id == a.signer_id,
          join: u in Rice.Accounts.User,
          on: u.id == s.user_id,
          where: a.issuance_id == ^proposal.id and is_nil(u.disabled_at) and is_nil(u.deleted_at)
        ),
        :count
      )

    if count < policy.threshold, do: Repo.rollback(:approval_threshold_not_met)

    case proposal.kind do
      "policy_change" -> replace_issuance_policy!(point, proposal, policy, actor)
      _ -> mint_approved!(point, proposal, actor)
    end
  end

  defp replace_issuance_policy!(point, proposal, policy, actor) do
    %{"threshold" => threshold, "signers" => signers, "supply_cap" => cap} = proposal.recipients
    issuer = Repo.get_by(Issuer, point_id: point.id) || Repo.rollback(:issuer_not_found)
    if cap && cap < issuer.issued, do: Repo.rollback(:supply_cap_below_issued)

    eligible =
      Repo.aggregate(
        from(u in Rice.Accounts.User,
          where: u.id in ^signers and is_nil(u.deleted_at) and is_nil(u.disabled_at)
        ),
        :count
      )

    if eligible != length(signers), do: Repo.rollback(:invalid_issuance_signers)

    Repo.update!(Ecto.Changeset.change(policy, current: false))

    next =
      Repo.insert!(%IssuancePolicy{
        point_id: point.id,
        current: true,
        threshold: threshold,
        version: policy.version + 1
      })

    for signer <- signers, do: Repo.insert!(%IssuanceSigner{policy_id: next.id, user_id: signer})
    Repo.update!(Ecto.Changeset.change(issuer, supply_cap: cap))

    tx =
      Repo.insert!(%Transaction{
        point_id: point.id,
        kind: "policy_change",
        actor_id: actor,
        reference_id: proposal.id,
        private_note: proposal.reason
      })

    Repo.update!(Ecto.Changeset.change(proposal, transaction_id: tx.id, execution_error: nil))
  end

  @doc "Books a grant authorized by the existing Rice admin flow."
  @spec grant_legacy_rice(String.t(), map(), (-> :ok | {:error, atom()})) ::
          {:ok, Transaction.t(), :created | :replayed} | {:error, atom()}
  def grant_legacy_rice(point_id, request, authorize) do
    result =
      Repo.transaction(fn ->
        point = lock_point!(point_id)
        if Rice.Points.LegacyCutover.point_id() != point.id, do: Repo.rollback(:point_not_found)
        ensure_issuance_status!(point, "mint")
        issuer = Repo.get_by!(Issuer, point_id: point.id)
        batch = normalized!(Map.put(request, :payer_account_id, issuer.account_id))

        case Repo.get_by(Transaction, idempotency_scope: batch.payer, idempotency_key: batch.key) do
          %Transaction{kind: "mint", request_hash: hash} = tx when hash == batch.hash ->
            {:posted, tx, :replayed}

          %Transaction{} ->
            Repo.rollback(:conflict)

          nil ->
            accounts = lock_accounts(batch)
            validate_issuance_accounts!(point, issuer, accounts, batch)

            if Enum.any?(batch.items, fn {id, _, _} -> accounts[id].owner_type != "node" end),
              do: Repo.rollback(:invalid_issuance_account)

            issued = issuer.issued + batch.total
            if issued > (issuer.supply_cap || @max_amount), do: Repo.rollback(:invalid_amount)

            case authorize.() do
              :ok ->
                tx = book!(point.id, accounts, batch, "mint")
                Repo.update!(Ecto.Changeset.change(issuer, issued: issued))
                {:posted, tx, :created}

              {:error, reason} ->
                {:verification_error, reason}
            end
        end
      end)

    case result do
      {:ok, {:posted, tx, status}} -> {:ok, tx, status}
      {:ok, {:verification_error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mint_approved!(point, proposal, actor) do
    ensure_issuance_status!(point, proposal.kind)
    issuer = Repo.get_by(Issuer, point_id: point.id) || Repo.rollback(:issuer_not_found)
    issued = issuer.issued + proposal.total
    if issued > (issuer.supply_cap || @max_amount), do: Repo.rollback(:supply_cap_exceeded)

    recipients =
      Enum.map(proposal.recipients["items"], fn item ->
        %{account_id: item["account_id"], amount: item["amount"], note: item["note"]}
      end)

    batch =
      normalized!(%{
        payer_account_id: issuer.account_id,
        actor_id: actor,
        idempotency_key: proposal.id,
        recipients: recipients,
        private_note: proposal.reason
      })

    if batch.total != proposal.total, do: Repo.rollback(:invalid_issuance)
    accounts = lock_accounts(batch)
    validate_issuance_accounts!(point, issuer, accounts, batch)
    ensure_unexpired!(proposal.expires_at)
    transaction = book!(point.id, accounts, batch, proposal.kind)
    Repo.update!(Ecto.Changeset.change(issuer, issued: issued))

    if proposal.kind == "initial_allocation" do
      Repo.update!(Ecto.Changeset.change(point, status: "active"))
    end

    Repo.update!(
      Ecto.Changeset.change(proposal, transaction_id: transaction.id, execution_error: nil)
    )
  end

  defp authorized_issuance!(point_id, issuance_id, signer_id) do
    lock_point!(point_id)

    proposal =
      Repo.get_by(Issuance, id: issuance_id, point_id: point_id) ||
        Repo.rollback(:issuance_not_found)

    policy = current_policy!(point_id)
    if proposal.policy_id != policy.id, do: Repo.rollback(:stale_issuance_policy)

    signer =
      Repo.one(
        from s in IssuanceSigner,
          join: u in Rice.Accounts.User,
          on: u.id == s.user_id,
          where:
            s.policy_id == ^policy.id and s.user_id == ^signer_id and
              is_nil(u.disabled_at) and is_nil(u.deleted_at)
      ) ||
        Repo.rollback(:forbidden)

    {proposal, signer, policy}
  end

  defp current_policy!(point_id) do
    Repo.get_by(IssuancePolicy, point_id: point_id, current: true) ||
      Repo.rollback(:issuance_policy_not_found)
  end

  defp lock_point!(point_id) do
    Repo.one(from p in Point, where: p.id == ^point_id, lock: "FOR UPDATE") ||
      Repo.rollback(:point_not_found)
  end

  defp ensure_unexpired!(expires_at) do
    if DateTime.compare(expires_at, DateTime.utc_now()) != :gt,
      do: Repo.rollback(:issuance_expired)
  end

  defp ensure_issuance_status!(%Point{status: "draft"}, "initial_allocation"), do: :ok
  defp ensure_issuance_status!(%Point{status: "active"}, "mint"), do: :ok
  defp ensure_issuance_status!(_, _), do: Repo.rollback(:invalid_issuance_status)

  defp normalized!(request) do
    case normalize(request) do
      {:ok, batch} -> batch
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_issuance_accounts!(point, issuer, accounts, batch) do
    ids = account_ids(batch)
    validate_account_scope!(point, accounts, ids)

    if accounts[issuer.account_id].owner_type != "system" or
         Enum.any?(batch.items, fn {id, _, _} -> accounts[id].owner_type == "system" end),
       do: Repo.rollback(:invalid_issuance_account)
  end

  defp normalize(
         %{payer_account_id: payer, actor_id: actor, idempotency_key: key, recipients: recipients} =
           request
       )
       when is_binary(payer) and is_binary(actor) and is_binary(key) and is_list(recipients) do
    public_note = Map.get(request, :public_note)
    private_note = Map.get(request, :private_note)
    reference_type = Map.get(request, :reference_type)
    reference_id = Map.get(request, :reference_id)

    with true <- Tsid.valid?(payer) and Tsid.valid?(actor),
         true <-
           String.valid?(key) and byte_size(key) in 1..128 and not String.contains?(key, <<0>>),
         true <- valid_note?(public_note) and valid_note?(private_note),
         true <- valid_note?(reference_type) and valid_note?(reference_id),
         true <- recipients != [],
         {:ok, items, total} <- normalize_recipients(recipients, payer) do
      items = Enum.sort(items)

      payload = {1, actor, public_note, private_note, items}

      payload =
        if reference_type || reference_id,
          do: {payload, reference_type, reference_id},
          else: payload

      hash =
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary(payload)
        )

      {:ok,
       %{
         payer: payer,
         actor: actor,
         key: key,
         items: items,
         total: total,
         public_note: public_note,
         private_note: private_note,
         reference_type: reference_type,
         reference_id: reference_id,
         hash: Base.encode16(hash)
       }}
    else
      _ -> {:error, :invalid_transfer}
    end
  end

  defp normalize(_), do: {:error, :invalid_transfer}

  defp normalize_recipients(recipients, payer) do
    Enum.reduce_while(recipients, {:ok, [], 0}, fn
      %{account_id: account_id, amount: amount} = item, {:ok, items, total}
      when is_binary(account_id) and is_integer(amount) and amount > 0 and
             amount <= @max_amount - total ->
        note = Map.get(item, :note)

        if account_id != payer and Tsid.valid?(account_id) and valid_note?(note) do
          {:cont, {:ok, [{account_id, amount, note} | items], total + amount}}
        else
          {:halt, :error}
        end

      _, _ ->
        {:halt, :error}
    end)
  end

  defp valid_note?(nil), do: true

  defp valid_note?(note) when is_binary(note),
    do: byte_size(note) <= 4096 and String.valid?(note) and not String.contains?(note, <<0>>)

  defp valid_note?(_), do: false

  defp post(batch) do
    payer = Repo.get(Account, batch.payer) || Repo.rollback(:account_not_found)
    point = Repo.one(from p in Point, where: p.id == ^payer.point_id, lock: "FOR SHARE")
    accounts = lock_accounts(batch)

    case Repo.get_by(Transaction,
           point_id: point.id,
           kind: "transfer",
           idempotency_scope: batch.payer,
           idempotency_key: batch.key
         ) do
      %Transaction{request_hash: hash} = transaction when hash == batch.hash ->
        Repo.preload(transaction, recipients: from(r in Recipient, order_by: r.id))

      nil ->
        validate_accounts!(point, accounts, account_ids(batch))
        require_no_spend_policy!(batch.payer)
        book!(point.id, accounts, batch)

      _ ->
        Repo.rollback(:idempotency_conflict)
    end
  end

  defp account_ids(batch), do: Enum.uniq([batch.payer | Enum.map(batch.items, &elem(&1, 0))])

  defp lock_accounts(batch) do
    ids = account_ids(batch)

    Repo.all(from a in Account, where: a.id in ^ids, order_by: a.id, lock: "FOR UPDATE")
    |> Map.new(&{&1.id, &1})
  end

  defp validate_accounts!(point, accounts, ids) do
    validate_account_scope!(point, accounts, ids)
    if point.status != "active", do: Repo.rollback(:inactive_account_or_point)

    if Enum.any?(accounts, fn {_, a} -> a.owner_type == "system" end),
      do: Repo.rollback(:system_account)
  end

  defp validate_account_scope!(point, accounts, ids) do
    cond do
      map_size(accounts) != length(ids) ->
        Repo.rollback(:account_not_found)

      Enum.any?(accounts, fn {_, a} -> a.point_id != point.id end) ->
        Repo.rollback(:asset_mismatch)

      Enum.any?(accounts, fn {_, a} -> a.status != "active" end) ->
        Repo.rollback(:inactive_account_or_point)

      true ->
        :ok
    end
  end

  defp book!(point_id, accounts, batch, kind \\ "transfer") do
    change_balance!(accounts[batch.payer], -batch.total)

    transaction =
      Repo.insert!(%Transaction{
        point_id: point_id,
        kind: kind,
        actor_id: batch.actor,
        idempotency_scope: batch.payer,
        idempotency_key: batch.key,
        request_hash: batch.hash,
        public_note: batch.public_note,
        private_note: batch.private_note,
        reference_type: Map.get(batch, :reference_type),
        reference_id: Map.get(batch, :reference_id)
      })

    write_entry!(transaction, batch.payer, -batch.total)

    %{transaction | recipients: credit_recipients!(transaction, accounts, batch.items)}
  end

  defp credit_recipients!(transaction, accounts, items) do
    items
    |> Enum.map(fn {account_id, amount, note} ->
      change_balance!(accounts[account_id], amount)
      write_entry!(transaction, account_id, amount)

      Repo.insert!(%Recipient{
        point_id: transaction.point_id,
        transaction_id: transaction.id,
        account_id: account_id,
        amount: amount,
        note: note
      })
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp change_balance!(account, delta, held_delta \\ 0) do
    balance =
      Repo.one(from b in Balance, where: b.account_id == ^account.id, lock: "FOR UPDATE") ||
        %Balance{account_id: account.id, owner_type: account.owner_type}

    available = balance.available + delta
    held = balance.held + held_delta

    cond do
      available < 0 and account.owner_type != "system" ->
        Repo.rollback(:insufficient_balance)

      available > @max_amount or available < -@max_amount - 1 or held > @max_amount ->
        Repo.rollback(:balance_overflow)

      held < 0 ->
        Repo.rollback(:insufficient_held_balance)

      true ->
        balance
        |> Ecto.Changeset.change(available: available, held: held)
        |> Repo.insert_or_update!()
    end
  end

  defp write_entry!(transaction, account_id, delta, bucket \\ "available") do
    Repo.insert!(%Entry{
      point_id: transaction.point_id,
      transaction_id: transaction.id,
      account_id: account_id,
      bucket: bucket,
      delta: delta
    })
  end
end

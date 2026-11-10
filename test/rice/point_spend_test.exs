defmodule Rice.PointSpendTest do
  use Rice.DataCase, async: true

  alias Rice.{Points, Tsid}
  alias Rice.Points.{Account, Balance, Point, Transaction}

  test "a treasury batch requires distinct current signers and executes exactly once" do
    [first, second, outsider] = for _ <- 1..3, do: user_fixture().id
    point = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "rice"})

    payer =
      Repo.insert!(%Account{point_id: point.id, owner_type: "node", owner_id: Tsid.generate()})

    recipient = Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: outsider})
    Repo.insert!(%Balance{account_id: payer.id, owner_type: "node", available: 100})
    assert {:ok, _} = Points.bootstrap_spend_policy(point.id, payer.id, 2, [first, second])

    request = %{
      payer_account_id: payer.id,
      actor_id: first,
      idempotency_key: "payroll",
      public_note: "Payroll",
      private_note: "Internal",
      recipients: [%{account_id: recipient.id, amount: 40, note: "January"}]
    }

    assert {:error, :spend_approval_required} = Points.transfer(request)

    assert {:error, :spend_approval_required} =
             Points.move_hold(:reserve, Map.put(request, :amount, 40))

    assert {:ok, proposal} =
             Points.propose_spend(point.id, request, DateTime.add(DateTime.utc_now(), 60))

    assert {:error, :forbidden} = Points.approve_spend(point.id, proposal.id, outsider)
    assert {:ok, _} = Points.approve_spend(point.id, proposal.id, first)
    assert {:ok, _} = Points.approve_spend(point.id, proposal.id, first)

    assert {:error, :approval_threshold_not_met} =
             Points.execute_spend(point.id, proposal.id, first)

    assert {:ok, _} = Points.approve_spend(point.id, proposal.id, second)

    expired =
      Repo.update!(
        Ecto.Changeset.change(proposal, expires_at: DateTime.add(DateTime.utc_now(), -1))
      )

    assert {:error, :spend_proposal_expired} = Points.execute_spend(point.id, expired.id, second)
    assert Repo.aggregate(Transaction, :count) == 0
    assert Repo.get_by!(Balance, account_id: payer.id).available == 100
    Repo.update!(Ecto.Changeset.change(expired, expires_at: proposal.expires_at))

    balance = Repo.get_by!(Balance, account_id: payer.id)
    balance = Repo.update!(Ecto.Changeset.change(balance, available: 30))
    assert {:error, :insufficient_balance} = Points.execute_spend(point.id, proposal.id, second)
    assert Repo.get!(Points.SpendProposal, proposal.id).execution_error == "insufficient_balance"
    assert Repo.aggregate(Transaction, :count) == 0
    Repo.update!(Ecto.Changeset.change(balance, available: 100))
    assert {:ok, posted} = Points.execute_spend(point.id, proposal.id, second)
    assert is_nil(posted.execution_error)
    assert posted.transaction_id
    assert {:ok, ^posted} = Points.execute_spend(point.id, proposal.id, first)
    assert Repo.aggregate(Transaction, :count) == 1
    assert Repo.get_by!(Balance, account_id: payer.id).available == 60
    assert Repo.get_by!(Balance, account_id: recipient.id).available == 40
  end

  test "an approved hold enforces business and cumulative recipient limits" do
    [first, second, outsider] = for _ <- 1..3, do: user_fixture().id
    point = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "rice"})

    payer =
      Repo.insert!(%Account{point_id: point.id, owner_type: "node", owner_id: Tsid.generate()})

    [a, b] =
      for owner <- [first, outsider],
          do: Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: owner})

    Repo.insert!(%Balance{account_id: payer.id, owner_type: "node", available: 100})
    {:ok, _} = Points.bootstrap_spend_policy(point.id, payer.id, 2, [first, second])

    request = %{
      payer_account_id: payer.id,
      actor_id: first,
      idempotency_key: "reserve",
      action: "reserve",
      business_reference: "task:1",
      recipients: [%{account_id: a.id, amount: 40}, %{account_id: b.id, amount: 60}]
    }

    {:ok, proposal} =
      Points.propose_spend(point.id, request, DateTime.add(DateTime.utc_now(), 60))

    for signer <- [first, second],
        do: assert({:ok, _} = Points.approve_spend(point.id, proposal.id, signer))

    assert {:ok, posted} = Points.execute_spend(point.id, proposal.id, second)
    hold = Repo.get_by!(Points.Hold, reservation_transaction_id: posted.transaction_id)

    settle = %{
      payer_account_id: payer.id,
      actor_id: first,
      hold_id: hold.id,
      idempotency_key: "settle",
      business_reference: "task:1",
      recipients: [%{account_id: a.id, amount: 30}]
    }

    assert {:error, :hold_business_reference_mismatch} =
             Points.move_hold(:settle, %{settle | business_reference: "task:2"})

    assert {:ok, _} = Points.move_hold(:settle, settle)

    assert {:error, :hold_recipient_limit_exceeded} =
             Points.move_hold(:settle, %{
               settle
               | idempotency_key: "overshoot",
                 recipients: [%{account_id: a.id, amount: 11}]
             })

    assert Repo.get_by!(Balance, account_id: a.id).available == 30
    assert Repo.get!(Points.Hold, hold.id).remaining_amount == 70
  end

  test "the current quorum must approve a replacement and pending old proposals become stale" do
    [first, second, replacement] = for _ <- 1..3, do: user_fixture().id
    point = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "rice"})

    payer =
      Repo.insert!(%Account{point_id: point.id, owner_type: "node", owner_id: Tsid.generate()})

    recipient =
      Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: replacement})

    {:ok, _} = Points.bootstrap_spend_policy(point.id, payer.id, 2, [first, second])
    expires = DateTime.add(DateTime.utc_now(), 60)

    request = %{
      payer_account_id: payer.id,
      actor_id: first,
      idempotency_key: "payment",
      recipients: [%{account_id: recipient.id, amount: 10}]
    }

    {:ok, pending} = Points.propose_spend(point.id, request, expires)

    change = %{
      payer_account_id: payer.id,
      actor_id: first,
      idempotency_key: "change",
      expires_at: expires,
      threshold: 2,
      signers: [first, replacement]
    }

    {:ok, proposal} = Points.propose_spend_policy(point.id, change)
    assert {:error, :forbidden} = Points.approve_spend(point.id, proposal.id, replacement)
    assert {:ok, _} = Points.approve_spend(point.id, proposal.id, first)

    assert {:error, :approval_threshold_not_met} =
             Points.execute_spend(point.id, proposal.id, first)

    assert {:ok, _} = Points.approve_spend(point.id, proposal.id, second)
    assert {:ok, %{transaction_id: tx}} = Points.execute_spend(point.id, proposal.id, second)
    assert is_binary(tx)
    assert Repo.get_by!(Points.SpendPolicy, account_id: payer.id, current: true).version == 2
    assert {:error, :stale_spend_policy} = Points.approve_spend(point.id, pending.id, first)

    {:ok, next} = Points.propose_spend(point.id, %{request | idempotency_key: "next"}, expires)
    assert {:error, :forbidden} = Points.approve_spend(point.id, next.id, second)
    assert {:ok, _} = Points.approve_spend(point.id, next.id, replacement)

    stop = %{change | threshold: nil, signers: [], idempotency_key: "stop"}
    assert {:ok, stopping} = Points.propose_spend_policy(point.id, stop)
    assert {:ok, _} = Points.approve_spend(point.id, stopping.id, first)

    assert {:error, :approval_threshold_not_met} =
             Points.execute_spend(point.id, stopping.id, first)

    assert {:ok, _} = Points.approve_spend(point.id, stopping.id, replacement)
    assert {:ok, %{transaction_id: stop_tx}} = Points.execute_spend(point.id, stopping.id, first)
    assert is_binary(stop_tx)
    refute Repo.get_by(Points.SpendPolicy, account_id: payer.id, current: true)
    assert {:error, :stale_spend_policy} = Points.approve_spend(point.id, next.id, replacement)
  end
end

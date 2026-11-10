defmodule Rice.PointIssuersTest do
  use Rice.DataCase, async: true

  alias Rice.Tsid
  alias Rice.Points.{Account, Balance, IssuancePolicy, Issuer, Issuers, Point}

  test "bootstrap creates a draft, a zero balance issuer and a versioned policy" do
    signers = for _ <- 1..3, do: user_fixture().id
    community = Tsid.generate()
    assert {:ok, point} = Issuers.bootstrap(community, "rice", 100, 2, signers)
    assert point.status == "draft"
    issuer = Repo.get_by!(Issuer, point_id: point.id)
    assert issuer.supply_cap == 100
    assert issuer.issued == 0
    assert Repo.get!(Account, issuer.account_id).owner_type == "system"
    assert Repo.get_by!(Balance, account_id: issuer.account_id).available == 0

    policy = Repo.get_by!(IssuancePolicy, point_id: point.id, current: true)
    assert policy.version == 1
    assert policy.threshold == 2

    assert Enum.sort(Enum.map(Repo.preload(policy, :signers).signers, & &1.user_id)) ==
             Enum.sort(signers)

    assert {:error, %Ecto.Changeset{}} = Issuers.bootstrap(community, "rice", 100, 2, signers)
    assert Repo.aggregate(Point, :count) == 1
  end

  test "initial allocation activates the asset and later mint respects the cumulative cap" do
    alias Rice.Points

    [first, second, outsider] = for _ <- 1..3, do: user_fixture().id
    assert {:ok, point} = Issuers.bootstrap(Tsid.generate(), "rice", 100, 2, [first, second])
    recipient = Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: first})
    expires = DateTime.add(DateTime.utc_now(), 300)

    request = %{
      actor_id: first,
      idempotency_key: "initial",
      recipients: [%{account_id: recipient.id, amount: 80}]
    }

    assert {:ok, proposal} =
             Points.propose_issuance(point.id, "initial_allocation", "启动", request, expires)

    alias Rice.Points.Queries

    assert {:ok, %{status: "pending", approvals: 0, total: "80"}} =
             Queries.issuance_for_user(point.id, proposal.id, second)

    assert {:error, :not_found} = Queries.issuance_for_user(point.id, proposal.id, outsider)
    assert {:error, :not_found} = Queries.issuance_for_user(Tsid.generate(), proposal.id, first)
    assert {:error, :forbidden} = Points.approve_issuance(point.id, proposal.id, outsider)
    assert {:ok, _} = Points.approve_issuance(point.id, proposal.id, first)
    assert {:ok, _} = Points.approve_issuance(point.id, proposal.id, first)

    assert {:error, :approval_threshold_not_met} =
             Points.execute_issuance(point.id, proposal.id, first)

    assert {:ok, _} = Points.approve_issuance(point.id, proposal.id, second)
    signer = Repo.get!(Rice.Accounts.User, second)
    signer = Repo.update!(Ecto.Changeset.change(signer, disabled_at: DateTime.utc_now()))
    assert {:error, :forbidden} = Points.approve_issuance(point.id, proposal.id, second)

    assert {:error, :approval_threshold_not_met} =
             Points.execute_issuance(point.id, proposal.id, first)

    assert {:ok, %{status: "pending", approvals: 1}} =
             Queries.issuance_for_user(point.id, proposal.id, first)

    Repo.update!(Ecto.Changeset.change(signer, disabled_at: nil))

    assert {:ok, posted} = Points.execute_issuance(point.id, proposal.id, second)
    assert posted.transaction_id
    assert {:ok, ^posted} = Points.execute_issuance(point.id, proposal.id, second)
    assert Repo.get!(Point, point.id).status == "active"

    assert {:error, :invalid_issuance_status} =
             Points.propose_issuance(
               point.id,
               "initial_allocation",
               "再次启动",
               %{request | idempotency_key: "other"},
               expires
             )

    request = %{
      request
      | idempotency_key: "mint",
        recipients: [%{account_id: recipient.id, amount: 21}]
    }

    assert {:ok, mint} = Points.propose_issuance(point.id, "mint", "增发", request, expires)

    for signer <- [first, second],
        do: assert({:ok, _} = Points.approve_issuance(point.id, mint.id, signer))

    assert {:error, :supply_cap_exceeded} = Points.execute_issuance(point.id, mint.id, first)

    assert {:ok, %{status: "approved", execution_error: "supply_cap_exceeded"}} =
             Queries.issuance_for_user(point.id, mint.id, first)

    issuer = Repo.get_by!(Issuer, point_id: point.id)
    assert issuer.issued == 80
    assert Repo.get_by!(Balance, account_id: issuer.account_id).available == -80
    assert Repo.get_by!(Balance, account_id: recipient.id).available == 80

    assert {:ok, %{issued: 80, circulating: 80, ok?: true}} =
             Rice.Points.Queries.reconcile(point.id)

    assert {:error, :insufficient_balance} =
             Points.burn(point.id, recipient.id, first, 81, "too-much")

    assert {:ok, burn} = Points.burn(point.id, recipient.id, first, 10, "burn")
    assert {:ok, %{id: id}} = Points.burn(point.id, recipient.id, first, 10, "burn")
    assert id == burn.id

    assert {:error, :idempotency_conflict} =
             Points.burn(point.id, recipient.id, first, 11, "burn")

    assert {:error, :supply_cap_exceeded} = Points.execute_issuance(point.id, mint.id, first)

    assert {:ok, %{issued: 80, burned: 10, circulating: 70, ok?: true}} =
             Rice.Points.Queries.reconcile(point.id)

    balance = Repo.get_by!(Balance, account_id: recipient.id)
    Repo.update!(Ecto.Changeset.change(balance, available: 81))

    assert {:ok, %{ok?: false, mismatched_accounts: [id]}} =
             Rice.Points.Queries.reconcile(point.id)

    assert id == recipient.id
  end

  test "a policy replacement requires the old quorum and invalidates old pending proposals" do
    alias Rice.Points
    [first, second, replacement] = for _ <- 1..3, do: user_fixture().id
    {:ok, point} = Issuers.bootstrap(Tsid.generate(), "rice", 100, 2, [first, second])
    recipient = Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: first})
    expires = DateTime.add(DateTime.utc_now(), 60)

    {:ok, pending} =
      Points.propose_issuance(
        point.id,
        "initial_allocation",
        "Start",
        %{
          actor_id: first,
          idempotency_key: "start",
          recipients: [%{account_id: recipient.id, amount: 50}]
        },
        expires
      )

    change = %{
      actor_id: first,
      idempotency_key: "policy",
      reason: "Rotate signer",
      expires_at: expires,
      signers: [first, replacement],
      threshold: 2,
      supply_cap: 150
    }

    assert {:ok, proposal} = Points.propose_issuance_policy(point.id, change)
    assert {:error, :forbidden} = Points.approve_issuance(point.id, proposal.id, replacement)
    assert {:ok, _} = Points.approve_issuance(point.id, proposal.id, first)

    assert {:error, :approval_threshold_not_met} =
             Points.execute_issuance(point.id, proposal.id, first)

    assert {:ok, _} = Points.approve_issuance(point.id, proposal.id, second)
    assert {:ok, %{transaction_id: tx}} = Points.execute_issuance(point.id, proposal.id, second)
    assert is_binary(tx)
    assert Repo.get_by!(IssuancePolicy, point_id: point.id, current: true).version == 2
    assert Repo.get_by!(Issuer, point_id: point.id).supply_cap == 150
    assert {:error, :stale_issuance_policy} = Points.approve_issuance(point.id, pending.id, first)

    assert {:ok, %{status: "stale"}} =
             Points.Queries.issuance_for_user(point.id, pending.id, replacement)
  end

  test "an unknown signer rolls the entire bootstrap back" do
    assert {:error, %Ecto.Changeset{}} =
             Issuers.bootstrap(Tsid.generate(), "rice", nil, 2, [
               user_fixture().id,
               Tsid.generate()
             ])

    assert Repo.aggregate(Point, :count) == 0
    assert Repo.aggregate(Account, :count) == 0
    assert Repo.aggregate(Issuer, :count) == 0
  end
end

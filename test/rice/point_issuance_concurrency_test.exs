defmodule Rice.PointIssuanceConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Rice.Fixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Rice.{Points, Repo, Tsid}
  alias Rice.Points.{Account, Balance, Issuers, PaymentApp, PaymentIntent, Payments, Queries}

  test "independent connections cannot both consume the same issuance capacity" do
    supervisor = start_supervised!(Task.Supervisor)

    Sandbox.unboxed_run(Repo, fn ->
      signers = for _ <- 1..2, do: user_fixture().id
      [actor | _] = signers
      {:ok, point} = Issuers.bootstrap(Tsid.generate(), "race", 100, 2, signers)

      try do
        recipient =
          Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: actor})

        initial =
          propose_and_approve(point.id, recipient.id, signers, "initial_allocation", "start", 80)

        assert {:ok, _} = Points.execute_issuance(point.id, initial.id, actor)

        proposals =
          for key <- ["mint-a", "mint-b"],
              do: propose_and_approve(point.id, recipient.id, signers, "mint", key, 15)

        results =
          race(
            supervisor,
            Enum.map(proposals, fn proposal ->
              fn -> Points.execute_issuance(point.id, proposal.id, actor) end
            end)
          )

        assert Enum.count(results, &match?({:ok, %{transaction_id: id}} when is_binary(id), &1)) ==
                 1

        assert Enum.count(results, &(&1 == {:error, :supply_cap_exceeded})) == 1
        assert {:ok, %{issued: 95, circulating: 95, ok?: true}} = Queries.reconcile(point.id)
      after
        cleanup(point.id, signers)
      end
    end)
  end

  test "independent transfers deduplicate identical retries and cannot overspend" do
    supervisor = start_supervised!(Task.Supervisor)

    Sandbox.unboxed_run(Repo, fn ->
      [actor, other] = signers = for _ <- 1..2, do: user_fixture().id
      {:ok, point} = Issuers.bootstrap(Tsid.generate(), "race", 100, 2, signers)

      try do
        [payer, recipient] =
          for user <- [actor, other],
              do: Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: user})

        initial =
          propose_and_approve(point.id, payer.id, signers, "initial_allocation", "start", 100)

        assert {:ok, _} = Points.execute_issuance(point.id, initial.id, actor)

        request = %{
          payer_account_id: payer.id,
          actor_id: actor,
          idempotency_key: "retry",
          recipients: [%{account_id: recipient.id, amount: 30}]
        }

        assert [{:ok, first}, {:ok, second}] =
                 race(supervisor, List.duplicate(fn -> Points.transfer(request) end, 2))

        assert first.id == second.id

        actions =
          for key <- ["a", "b"] do
            fn ->
              Points.transfer(%{
                request
                | idempotency_key: key,
                  recipients: [%{account_id: recipient.id, amount: 50}]
              })
            end
          end

        results = race(supervisor, actions)
        assert Enum.count(results, &match?({:ok, _}, &1)) == 1
        assert Enum.count(results, &(&1 == {:error, :insufficient_balance})) == 1
        assert Repo.get_by!(Points.Balance, account_id: payer.id).available == 20
        assert Repo.get_by!(Points.Balance, account_id: recipient.id).available == 80
        assert {:ok, %{circulating: 100, ok?: true}} = Queries.reconcile(point.id)
      after
        cleanup(point.id, signers)
      end
    end)
  end

  test "concurrent checkout confirmations by different payers debit only one wallet" do
    supervisor = start_supervised!(Task.Supervisor)

    Sandbox.unboxed_run(Repo, fn ->
      [first, second] = signers = for _ <- 1..2, do: user_fixture().id
      {:ok, point} = Issuers.bootstrap(Tsid.generate(), "checkout-race", 100, 2, signers)

      try do
        [payer_a, payer_b, payee] =
          for owner <- [first, second, Tsid.generate()],
              do: Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: owner})

        request = %{
          actor_id: first,
          idempotency_key: "start",
          recipients: Enum.map([payer_a, payer_b], &%{account_id: &1.id, amount: 50})
        }

        {:ok, allocation} =
          Points.propose_issuance(
            point.id,
            "initial_allocation",
            "fund payers",
            request,
            DateTime.add(DateTime.utc_now(), 60)
          )

        for signer <- signers,
            do: assert({:ok, _} = Points.approve_issuance(point.id, allocation.id, signer))

        assert {:ok, _} = Points.execute_issuance(point.id, allocation.id, first)

        assert {:ok, app} =
                 Payments.register_app("Store", payee.id, "https://store.example/return")

        assert {:ok, order} = Payments.create(app.credential, "checkout-race", 30)

        assert [{:ok, paid_a}, {:ok, paid_b}] =
                 race(supervisor, [
                   fn -> Payments.confirm(order.id, first) end,
                   fn -> Payments.confirm(order.id, second) end
                 ])

        assert paid_a.transaction_id == paid_b.transaction_id

        assert {:ok, %{status: "succeeded", transaction_id: tx}} =
                 Payments.lookup(app.credential, order.id)

        assert tx == paid_a.transaction_id

        balances =
          for payer <- [payer_a, payer_b],
              do: Repo.get_by!(Balance, account_id: payer.id).available

        assert Enum.sort(balances) == [20, 50]
        assert Repo.get_by!(Balance, account_id: payee.id).available == 30
        assert {:ok, %{issued: 100, circulating: 100, ok?: true}} = Queries.reconcile(point.id)
      after
        Repo.delete_all(from i in PaymentIntent, where: i.point_id == ^point.id)
        Repo.delete_all(from a in PaymentApp, where: a.point_id == ^point.id)
        cleanup(point.id, signers)
      end
    end)
  end

  test "independent treasury approvals and executions post a batch only once" do
    supervisor = start_supervised!(Task.Supervisor)

    Sandbox.unboxed_run(Repo, fn ->
      [first, _second] = signers = for _ <- 1..2, do: user_fixture().id
      {:ok, point} = Issuers.bootstrap(Tsid.generate(), "treasury-race", 100, 2, signers)

      try do
        payer =
          Repo.insert!(%Account{
            point_id: point.id,
            owner_type: "node",
            owner_id: Tsid.generate()
          })

        payee = Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: first})

        initial =
          propose_and_approve(point.id, payer.id, signers, "initial_allocation", "start", 100)

        assert {:ok, _} = Points.execute_issuance(point.id, initial.id, first)
        assert {:ok, _} = Points.bootstrap_spend_policy(point.id, payer.id, 2, signers)

        request = %{
          payer_account_id: payer.id,
          actor_id: first,
          idempotency_key: "payroll",
          recipients: [%{account_id: payee.id, amount: 40}]
        }

        {:ok, proposal} =
          Points.propose_spend(point.id, request, DateTime.add(DateTime.utc_now(), 60))

        approvals =
          for signer <- signers, do: fn -> Points.approve_spend(point.id, proposal.id, signer) end

        assert Enum.all?(race(supervisor, approvals), &match?({:ok, _}, &1))

        executions =
          for signer <- signers, do: fn -> Points.execute_spend(point.id, proposal.id, signer) end

        assert [{:ok, %{transaction_id: tx}}, {:ok, %{transaction_id: tx_again}}] =
                 race(supervisor, executions)

        assert is_binary(tx) and tx == tx_again
        assert Repo.get_by!(Balance, account_id: payer.id).available == 60
        assert Repo.get_by!(Balance, account_id: payee.id).available == 40
        assert {:ok, %{ok?: true}} = Queries.reconcile(point.id)
      after
        cleanup(point.id, signers)
      end
    end)
  end

  defp race(supervisor, actions) do
    parent = self()

    tasks =
      for action <- actions do
        Task.Supervisor.async_nolink(supervisor, fn ->
          Sandbox.unboxed_run(Repo, fn ->
            send(parent, {:ready, self()})

            receive do
              :run -> action.()
            after
              5_000 -> raise "ledger concurrency barrier timed out"
            end
          end)
        end)
      end

    workers =
      for _ <- tasks do
        assert_receive {:ready, worker}, 5_000
        worker
      end

    Enum.each(workers, &send(&1, :run))
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp propose_and_approve(point_id, account_id, [actor | _] = signers, kind, key, amount) do
    request = %{
      actor_id: actor,
      idempotency_key: key,
      recipients: [%{account_id: account_id, amount: amount}]
    }

    assert {:ok, proposal} =
             Points.propose_issuance(
               point_id,
               kind,
               "concurrency test",
               request,
               DateTime.add(DateTime.utc_now(), 60)
             )

    for signer <- signers,
        do: assert({:ok, _} = Points.approve_issuance(point_id, proposal.id, signer))

    proposal
  end

  defp cleanup(id, signers) do
    Repo.query!(
      "DELETE FROM point_spend_approvals WHERE proposal_id IN (SELECT id FROM point_spend_proposals WHERE point_id = $1)",
      [id]
    )

    Repo.query!(
      "DELETE FROM point_spend_policy_signers WHERE policy_id IN (SELECT id FROM point_spend_policies WHERE point_id = $1)",
      [id]
    )

    Repo.query!(
      "DELETE FROM point_issuance_approvals WHERE issuance_id IN (SELECT id FROM point_issuances WHERE point_id = $1)",
      [id]
    )

    Repo.query!(
      "DELETE FROM point_issuance_signers WHERE policy_id IN (SELECT id FROM point_issuance_policies WHERE point_id = $1)",
      [id]
    )

    Repo.query!(
      "DELETE FROM point_balances WHERE account_id IN (SELECT id FROM point_accounts WHERE point_id = $1)",
      [id]
    )

    for table <- [
          "point_spend_proposals",
          "point_spend_policies",
          "point_issuances",
          "point_issuance_policies",
          "point_recipients",
          "point_entries",
          "point_transactions",
          "point_issuers",
          "point_accounts"
        ] do
      Repo.delete_all(from(row in table, where: field(row, :point_id) == ^id))
    end

    Repo.delete!(Repo.get!(Points.Point, id))
    Repo.delete_all(from(u in Rice.Accounts.User, where: u.id in ^signers))
  end
end

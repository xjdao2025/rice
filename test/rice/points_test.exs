defmodule Rice.PointsTest do
  use Rice.DataCase, async: true

  alias Rice.{Points, Tsid}
  alias Rice.Points.{Account, Balance, Entry, Point, Recipient, Transaction}

  setup do
    point = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "rice"})

    [payer, a, b] =
      for _ <- 1..3 do
        Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: Tsid.generate()})
      end

    Repo.insert!(%Balance{account_id: payer.id, owner_type: "user", available: 150, held: 20})

    request = %{
      payer_account_id: payer.id,
      actor_id: payer.owner_id,
      idempotency_key: "payroll-1",
      public_note: "工资",
      private_note: "内部备注",
      recipients: [
        %{account_id: a.id, amount: 100, note: "一月份工资"},
        %{account_id: b.id, amount: 40, note: "兼职补贴"}
      ]
    }

    %{request: request, payer: payer, a: a, b: b}
  end

  test "books distinct recipient amounts and notes, and retries without writing again", ctx do
    assert {:ok, transaction} = Points.transfer(ctx.request)
    assert transaction.public_note == "工资"
    assert transaction.private_note == "内部备注"

    assert Enum.sort(Enum.map(transaction.recipients, &{&1.account_id, &1.amount, &1.note})) ==
             Enum.sort([{ctx.a.id, 100, "一月份工资"}, {ctx.b.id, 40, "兼职补贴"}])

    alias Rice.Points.Queries
    assert {:ok, view} = Queries.transaction_for_user(transaction.id, ctx.a.owner_id)
    assert view.public_note == "工资"
    refute Map.has_key?(view, :private_note)
    assert view.recipients == [%{account_id: ctx.a.id, amount: 100, note: "一月份工资"}]
    assert {:ok, payer_view} = Queries.transaction_for_user(transaction.id, ctx.payer.owner_id)
    assert payer_view.private_note == "内部备注"
    assert length(payer_view.recipients) == 2
    assert {:error, :not_found} = Queries.transaction_for_user(transaction.id, Tsid.generate())

    assert balance(ctx.payer).available == 10
    assert balance(ctx.payer).held == 20
    assert balance(ctx.a).available == 100
    assert balance(ctx.b).available == 40

    entries = Repo.all(from e in Entry, where: e.transaction_id == ^transaction.id)
    assert Enum.sort(Enum.map(entries, & &1.delta)) == [-140, 40, 100]

    assert {:ok, retry} =
             Points.transfer(%{ctx.request | recipients: Enum.reverse(ctx.request.recipients)})

    assert retry.id == transaction.id
    assert retry.recipients == transaction.recipients
    assert {:error, :idempotency_conflict} = Points.transfer(%{ctx.request | private_note: "改动"})
    assert Repo.aggregate(Transaction, :count) == 1
    assert Repo.aggregate(Entry, :count) == 3
    assert Repo.aggregate(Recipient, :count) == 2
    assert balance(ctx.payer).available == 10
  end

  test "insufficient available funds leave balances and ledger untouched", ctx do
    request =
      update_in(
        ctx.request,
        [:recipients],
        &List.update_at(&1, 0, fn row -> %{row | amount: 111} end)
      )

    assert {:error, :insufficient_balance} = Points.transfer(request)
    assert_untouched(ctx)
  end

  test "a recipient overflow rolls back a debit and an earlier credit", ctx do
    [first, last] = Enum.sort_by([ctx.a, ctx.b], & &1.id)

    Repo.insert!(%Balance{
      account_id: last.id,
      owner_type: "user",
      available: 9_223_372_036_854_775_807
    })

    assert {:error, :balance_overflow} = Points.transfer(ctx.request)
    assert balance(ctx.payer).available == 150
    refute balance(first)
    assert balance(last).available == 9_223_372_036_854_775_807
    assert_empty_ledger()
  end

  test "reserves, partially settles, and releases only the remaining amount", ctx do
    base = Map.take(ctx.request, [:payer_account_id, :actor_id])
    reserve = Map.merge(base, %{amount: 100, idempotency_key: "reserve"})
    assert {:ok, %{hold: hold}} = Points.move_hold(:reserve, reserve)
    assert balance(ctx.payer).available == 50
    assert balance(ctx.payer).held == 120

    settle =
      Map.merge(base, %{
        hold_id: hold.id,
        idempotency_key: "settle",
        recipients: [%{account_id: ctx.a.id, amount: 60, note: "first payment"}]
      })

    assert {:ok, %{hold: %{remaining_amount: 40}, transaction: tx}} =
             Points.move_hold(:settle, settle)

    assert {:ok, %{transaction: %{id: id}}} = Points.move_hold(:settle, settle)
    assert id == tx.id
    assert balance(ctx.a).available == 60

    release = Map.merge(base, %{hold_id: hold.id, amount: 41, idempotency_key: "release"})
    assert {:error, :hold_amount_exceeded} = Points.move_hold(:release, release)

    assert {:ok, %{hold: %{status: "closed", remaining_amount: 0}}} =
             Points.move_hold(:release, %{release | amount: 40})

    assert balance(ctx.payer).available == 90
    assert balance(ctx.payer).held == 20
    assert Repo.aggregate(Transaction, :count) == 3
    assert Repo.aggregate(Entry, :sum, :delta) == Decimal.new(0)
  end

  defp assert_untouched(ctx) do
    assert balance(ctx.payer).available == 150
    assert balance(ctx.payer).held == 20
    refute balance(ctx.a)
    refute balance(ctx.b)
    assert_empty_ledger()
  end

  defp assert_empty_ledger do
    assert Repo.aggregate(Transaction, :count) == 0
    assert Repo.aggregate(Entry, :count) == 0
    assert Repo.aggregate(Recipient, :count) == 0
  end

  defp balance(account), do: Repo.get_by(Balance, account_id: account.id)
end

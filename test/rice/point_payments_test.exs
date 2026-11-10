defmodule Rice.PointPaymentsTest do
  use Rice.DataCase, async: true

  alias Rice.Tsid
  alias Rice.Points.{Account, Balance, Payments, Point, Transaction}

  test "order isolation, retry, failed payment and confirmation use one ledger transaction" do
    point = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "rice"})

    [payer, payee] =
      for _ <- 1..2,
          do:
            Repo.insert!(%Account{
              point_id: point.id,
              owner_type: "user",
              owner_id: Tsid.generate()
            })

    Repo.insert!(%Balance{account_id: payer.id, owner_type: "user", available: 25})
    assert {:ok, first} = Payments.register_app("Store", payee.id, "https://store.example/return")

    assert {:ok, second} =
             Payments.register_app("Other", payee.id, "https://other.example/return")

    assert {:ok, order} = Payments.create(first.credential, "invoice-1", 20)
    assert {:ok, %{id: id}} = Payments.create(first.credential, "invoice-1", 20)
    assert id == order.id
    assert {:error, :idempotency_conflict} = Payments.create(first.credential, "invoice-1", 21)
    assert {:error, :not_found} = Payments.lookup(second.credential, order.id)
    assert {:error, :invalid_app_credential} = Payments.lookup("invalid", order.id)

    assert {:ok, too_big} = Payments.create(first.credential, "invoice-2", 26)
    assert {:error, :insufficient_balance} = Payments.confirm(too_big.id, payer.owner_id)

    assert {:ok, %{status: "pending", transaction_id: nil}} =
             Payments.lookup(first.credential, too_big.id)

    assert Repo.aggregate(Transaction, :count) == 0

    assert {:ok, %{status: "succeeded", transaction_id: tx}} =
             Payments.confirm(order.id, payer.owner_id)

    assert {:ok, %{transaction_id: ^tx}} = Payments.confirm(order.id, payer.owner_id)
    assert {:ok, %{transaction_id: ^tx}} = Payments.lookup(first.credential, order.id)
    assert Repo.aggregate(Transaction, :count) == 1
    assert Repo.get_by!(Balance, account_id: payer.id).available == 5
    assert Repo.get_by!(Balance, account_id: payee.id).available == 20
  end

  test "rotation revokes the old credential and disabled or expired orders cannot debit" do
    point = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "rice"})

    [payer, payee] =
      for _ <- 1..2,
          do:
            Repo.insert!(%Account{
              point_id: point.id,
              owner_type: "user",
              owner_id: Tsid.generate()
            })

    Repo.insert!(%Balance{account_id: payer.id, owner_type: "user", available: 25})

    {:ok, %{app: app, credential: old}} =
      Payments.register_app("Store", payee.id, "https://store.example/return")

    {:ok, order} = Payments.create(old, "before-rotation", 20)
    {:ok, current} = Payments.rotate_credential(app.id)
    assert old != current
    assert {:error, :invalid_app_credential} = Payments.lookup(old, order.id)
    assert {:ok, %{id: id}} = Payments.lookup(current, order.id)
    assert id == order.id

    assert {:ok, _} = Payments.set_active(app.id, false)
    assert {:error, :invalid_app_credential} = Payments.create(current, "disabled", 10)
    assert {:error, :app_disabled} = Payments.confirm(order.id, payer.owner_id)
    assert {:ok, _} = Payments.set_active(app.id, true)

    Repo.update!(change(order, expires_at: DateTime.add(DateTime.utc_now(), -1)))
    assert {:error, :order_expired} = Payments.confirm(order.id, payer.owner_id)
    assert {:ok, expired} = Payments.lookup(current, order.id)
    assert Payments.status(expired) == "expired"
    assert Repo.aggregate(Transaction, :count) == 0
    assert Repo.get_by!(Balance, account_id: payer.id).available == 25
  end
end

defmodule Rice.MinimalFundsTest do
  use Rice.DataCase, async: true

  alias Rice.Grains

  test "同一冻结重试不重复扣款，另一笔不能使用已冻结余额" do
    payer = user_fixture()
    {:ok, _} = Grains.grant(payer, 100)
    uri = "rice://tasks/#{Rice.Tsid.generate()}"
    other_uri = "rice://tasks/#{Rice.Tsid.generate()}"

    assert {:ok, first} = transact(fn -> Grains.reserve_business(Repo, payer.id, 60, uri) end)
    assert {:ok, repeated} = transact(fn -> Grains.reserve_business(Repo, payer.id, 60, uri) end)
    assert repeated.id == first.id

    assert {:error, :conflict} =
             transact(fn -> Grains.reserve_business(Repo, payer.id, 50, uri) end)

    assert {:error, :insufficient_balance} =
             transact(fn -> Grains.reserve_business(Repo, payer.id, 50, other_uri) end)

    assert %{balance: 40, frozen: 60, earned: 100} = Grains.wallet(payer)
    assert Repo.aggregate(Rice.Grains.Receipt, :count) == 1
    assert Grains.reconcile().ok?
  end

  test "每笔冻结只能退款或结算一次，退款不增加累计获得" do
    payer = user_fixture()
    recipient = user_fixture()
    {:ok, _} = Grains.grant(payer, 100)
    refunded_uri = "rice://tasks/#{Rice.Tsid.generate()}"
    settled_uri = "rice://tasks/#{Rice.Tsid.generate()}"

    assert {:ok, _} =
             transact(fn -> Grains.reserve_business(Repo, payer.id, 60, refunded_uri) end)

    assert {:ok, refunded} =
             transact(fn -> Grains.refund_business(Repo, payer.id, 60, refunded_uri) end)

    assert {:ok, repeated_refund} =
             transact(fn -> Grains.refund_business(Repo, payer.id, 60, refunded_uri) end)

    assert repeated_refund.id == refunded.id

    assert {:error, :conflict} =
             transact(fn ->
               Grains.settle_business(Repo, payer.id, recipient.id, 60, refunded_uri)
             end)

    assert %{balance: 100, frozen: 0, earned: 100} = Grains.wallet(payer)
    assert %{balance: 0, frozen: 0, earned: 0} = Grains.wallet(recipient)

    assert {:ok, _} = transact(fn -> Grains.reserve_business(Repo, payer.id, 40, settled_uri) end)

    assert {:ok, settled} =
             transact(fn ->
               Grains.settle_business(Repo, payer.id, recipient.id, 40, settled_uri)
             end)

    assert {:ok, repeated_settlement} =
             transact(fn ->
               Grains.settle_business(Repo, payer.id, recipient.id, 40, settled_uri)
             end)

    assert repeated_settlement.id == settled.id

    assert {:error, :conflict} =
             transact(fn -> Grains.refund_business(Repo, payer.id, 40, settled_uri) end)

    assert %{balance: 60, frozen: 0, earned: 100} = Grains.wallet(payer)
    assert %{balance: 40, frozen: 0, earned: 40} = Grains.wallet(recipient)
    assert Repo.aggregate(Rice.Grains.Receipt, :count) == 4
    assert Repo.aggregate(Rice.Grains.Transfer, :count) == 2
    assert Grains.reconcile().ok?
  end

  test "钱包游标合并转账和冻结凭证，不丢失或重复较早记录" do
    payer = user_fixture()
    {:ok, grant} = Grains.grant(payer, 100)
    uri = "rice://tasks/#{Rice.Tsid.generate()}"
    {:ok, reserved} = transact(fn -> Grains.reserve_business(Repo, payer.id, 40, uri) end)
    {:ok, refunded} = transact(fn -> Grains.refund_business(Repo, payer.id, 40, uri) end)

    first = Grains.wallet(payer, %{"limit" => "2"})
    assert Enum.map(first.entries, & &1.id) == [refunded.id, reserved.id]
    assert first.next_cursor == reserved.id
    last = Grains.wallet(payer, %{"limit" => "2", "before" => first.next_cursor})
    assert Enum.map(last.entries, & &1.id) == [grant.id]
    assert last.next_cursor == nil
    assert last.earned == 100
    assert Grains.wallet(user_fixture()).entries == []
  end

  defp transact(operation) do
    Repo.transaction(fn ->
      case operation.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end

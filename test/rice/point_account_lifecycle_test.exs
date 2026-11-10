defmodule Rice.PointAccountLifecycleTest do
  use Rice.DataCase, async: true

  alias Rice.{Accounts, Points, Tsid}
  alias Rice.Points.{Account, Balance, Point}

  test "account deletion preserves Point funds and disables empty wallets" do
    funded = user_fixture()
    empty = user_fixture()
    point = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "lifecycle"})

    [payer, recipient] =
      for user <- [funded, empty] do
        Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: user.id})
      end

    Repo.insert!(%Balance{account_id: payer.id, owner_type: "user", held: 10})
    assert {:error, :account_has_balance} = Accounts.delete_user(funded)
    assert {:ok, _} = Accounts.delete_user(empty)
    assert Repo.get!(Account, recipient.id).status == "disabled"

    assert {:error, :inactive_account_or_point} =
             Points.transfer(%{
               payer_account_id: payer.id,
               actor_id: funded.id,
               idempotency_key: "retired",
               recipients: [%{account_id: recipient.id, amount: 1}]
             })
  end
end

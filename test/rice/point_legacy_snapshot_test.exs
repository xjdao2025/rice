defmodule Rice.PointLegacySnapshotTest do
  use Rice.DataCase, async: false

  alias Rice.{Grains, Points.LegacySnapshot}

  test "preflight ties partial outcomes to the reservation and identifies frozen balance drift" do
    payer = user_fixture()
    payee = user_fixture()
    {:ok, _} = Grains.grant(payer, 100)
    uri = "task:example"
    assert {:ok, _} = Grains.reserve_business(Repo, payer.id, 60, uri)

    assert {:ok, _} =
             Grains.draw_reservation(
               Repo,
               payer.id,
               payee.id,
               20,
               uri,
               uri <> "/award",
               "settled"
             )

    assert %{available: 60, frozen: 40, granted: 100, open_holds: 1, ok?: true} =
             LegacySnapshot.audit()

    payer = Repo.reload!(payer)

    Repo.update!(
      change(payer,
        grain_balance: payer.grain_balance + 1,
        grain_frozen_balance: payer.grain_frozen_balance - 1
      )
    )

    assert %{ok?: false, mismatched_accounts: [account]} = LegacySnapshot.audit()
    assert account == "user:" <> payer.id
  end

  test "opening import preserves balances and the remaining amount of a partially settled hold" do
    alias Rice.{Points, Tsid}
    alias Rice.Points.{Account, Balance, Hold, Issuers, LegacyHolds, Transaction}

    payer = user_fixture()
    payee = user_fixture()
    {:ok, _} = Grains.grant(payer, 100)
    uri = "task:import"
    {:ok, receipt} = Grains.reserve_business(Repo, payer.id, 60, uri)

    {:ok, _} =
      Grains.draw_reservation(Repo, payer.id, payee.id, 20, uri, uri <> "/award", "settled")

    {:ok, point} = Issuers.bootstrap(Tsid.generate(), "legacy-rice", nil, 2, [payer.id, payee.id])

    assert {:ok, %{issued: 100, circulating: 100, ok?: true}} =
             LegacySnapshot.import_opening(point.id)

    assert {:error, :point_not_empty} = LegacySnapshot.import_opening(point.id)
    account = Repo.get_by!(Account, point_id: point.id, owner_id: payer.id, owner_type: "user")
    assert %{available: 40, held: 40} = Repo.get_by!(Balance, account_id: account.id)
    opening = Repo.get_by!(Transaction, point_id: point.id, reference_id: receipt.id)
    hold = Repo.get_by!(Hold, reservation_transaction_id: opening.id)
    assert hold.original_amount == 60
    assert hold.remaining_amount == 40

    request = %{
      reservation_uri: uri,
      outcome_uri: uri <> "/award",
      actor_id: payer.id,
      amount: 10,
      recipient: payee.id
    }

    assert {:error, :legacy_outcome_already_recorded} =
             LegacyHolds.move(point.id, :settle, request)

    next = %{request | outcome_uri: uri <> "/award-2"}

    assert {:ok, %{hold: %{remaining_amount: 30}, transaction: tx}} =
             LegacyHolds.move(point.id, :settle, next)

    assert {:ok, %{transaction: %{id: tx_id}}} = LegacyHolds.move(point.id, :settle, next)
    assert tx_id == tx.id

    refund = Map.delete(next, :recipient)
    assert {:error, :idempotency_conflict} = LegacyHolds.move(point.id, :release, refund)

    previous = Application.fetch_env(:rice, :point_legacy_hold_asset)
    Application.put_env(:rice, :point_legacy_hold_asset, point.id)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:rice, :point_legacy_hold_asset, value)
        :error -> Application.delete_env(:rice, :point_legacy_hold_asset)
      end
    end)

    assert {:ok, %{hold: %{status: "closed"}}} =
             Grains.draw_reservation(Repo, payer.id, nil, 30, uri, uri <> "/refund", "refunded")

    assert Repo.reload!(payer).grain_frozen_balance == 40

    assert %{available: 70, held: 0} = Repo.get_by!(Balance, account_id: account.id)
    new_uri = "task:after-cutover"

    assert {:ok, %{hold: %{remaining_amount: 25}, transaction: reserve}} =
             Grains.reserve_business(Repo, payer.id, 25, new_uri)

    assert {:ok, %{transaction: %{id: same_id}}} =
             Grains.reserve_business(Repo, payer.id, 25, new_uri)

    assert same_id == reserve.id
    assert {:error, :conflict} = Grains.reserve_business(Repo, payer.id, 24, new_uri)

    assert {:ok, %{hold: %{remaining_amount: 10}}} =
             Grains.draw_reservation(
               Repo,
               payer.id,
               payee.id,
               15,
               new_uri,
               new_uri <> "/award",
               "settled"
             )

    assert {:ok, %{hold: %{status: "closed"}}} =
             Grains.draw_reservation(
               Repo,
               payer.id,
               nil,
               10,
               new_uri,
               new_uri <> "/refund",
               "refunded"
             )

    assert %{available: 55, held: 0} = Repo.get_by!(Balance, account_id: account.id)
    refute Repo.get_by(Rice.Grains.Receipt, subject_uri: new_uri)
    assert %{balance: 55, frozen: 0} = Grains.wallet(payer)
    assert {55, 0} = Grains.balances(Repo.reload!(payer))
    assert {45, 0} = Grains.balances(Repo.reload!(payee))
    assert {:ok, gift} = Grains.transfer(payer, payee, 5, request_id: "after-cutover")
    assert {:ok, %{id: gift_id}} = Grains.transfer(payer, payee, 5, request_id: "after-cutover")
    assert gift_id == gift.id
    assert {:error, :conflict} = Grains.transfer(payer, payee, 6, request_id: "after-cutover")
    assert {50, 0} = Grains.balances(Repo.reload!(payer))
    assert {50, 0} = Grains.balances(Repo.reload!(payee))
    assert {:error, :point_issuance_required} = Grains.grant(payee, 1)

    assert {:error, :unprocessable_entity} =
             Rice.Admin.Grants.grant_nodes(%Rice.Admin.AdminUser{}, [], 1, "old-grant", nil)

    refute Repo.get_by(Rice.Grains.Transfer, request_id: "after-cutover")
    assert %{earned: 50, entries: entries} = Grains.wallet(payee)
    assert Enum.any?(entries, &(&1.id == gift.id and &1.kind == "gift" and &1.amount == 5))
    assert Enum.sum(Enum.map(entries, & &1.amount)) == 50

    assert %{entries: [%{id: latest}], next_cursor: cursor} =
             Grains.wallet(payee, %{"limit" => 1})

    assert latest == gift.id
    assert cursor == gift.id
    assert %{entries: older} = Grains.wallet(payee, %{"before" => cursor})
    refute Enum.any?(older, &(&1.id == gift.id))

    assert {:ok, %{ok?: true}} = Points.Queries.reconcile(point.id)
  end

  test "migrated Rice keeps administrator verification, atomic mint and idempotency" do
    alias Rice.Points.{Issuers, LegacyCutover, Queries, WalletAccounts}
    node = node_fixture()
    admin = user_fixture()
    {:ok, point} = Issuers.prepare_legacy_rice("test-rice")
    {:ok, _} = LegacyCutover.activate(point.id)
    {:ok, wallet} = WalletAccounts.ensure_recipient(point.id, {:node, node.id})

    request = %{
      actor_id: admin.id,
      idempotency_key: "verified-rice-grant",
      recipients: [%{account_id: wallet.id, amount: 5}]
    }

    assert {:error, :invalid_code} =
             Rice.Points.grant_legacy_rice(point.id, request, fn -> {:error, :invalid_code} end)

    assert {:ok, %{issued: 0, ok?: true}} = Queries.reconcile(point.id)
    assert {:ok, tx, :created} = Rice.Points.grant_legacy_rice(point.id, request, fn -> :ok end)

    assert {:ok, %{id: id}, :replayed} =
             Rice.Points.grant_legacy_rice(point.id, request, fn ->
               flunk("retry verified again")
             end)

    assert id == tx.id
    assert {5, 0} = Grains.balances(node)
    assert {:ok, %{issued: 5, ok?: true}} = Queries.reconcile(point.id)
  end

  test "database cutover guards old writers and only permits rollback before new postings" do
    alias Rice.Tsid
    alias Rice.Points.{Issuers, LegacyCutover, Point}
    payer = user_fixture()
    payee = user_fixture()
    {:ok, _} = Grains.grant(payer, 100)
    {:ok, first} = Issuers.bootstrap(Tsid.generate(), "first", nil, 2, [payer.id, payee.id])
    assert {:ok, %{ok?: true}} = LegacyCutover.activate(first.id)
    assert LegacyCutover.point_id() == first.id

    assert {:ok, %{account_deltas: [], transactions: [], can_rollback_directly?: true}} =
             LegacyCutover.rollback_report(first.id)

    Repo.query!("""
    DO $$
    BEGIN
      BEGIN
        UPDATE users SET grain_balance = grain_balance + 1;
        RAISE EXCEPTION 'legacy update unexpectedly succeeded';
      EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
      END;
      BEGIN
        DELETE FROM grain_transfers;
        RAISE EXCEPTION 'legacy ledger deletion unexpectedly succeeded';
      EXCEPTION WHEN SQLSTATE '55000' THEN NULL;
      END;
    END
    $$
    """)

    assert {:ok, :rolled_back} = LegacyCutover.rollback_before_writes(first.id)
    assert is_nil(LegacyCutover.point_id())
    assert Repo.get!(Point, first.id).status == "disabled"
    assert {:ok, _} = Grains.grant(payer, 10)

    {:ok, second} = Issuers.bootstrap(Tsid.generate(), "second", nil, 2, [payer.id, payee.id])
    assert {:ok, %{issued: 110}} = LegacyCutover.activate(second.id)
    new_user = user_fixture()
    refute Repo.get_by(Rice.Points.Account, point_id: second.id, owner_id: new_user.id)
    assert {:ok, _} = Grains.transfer(payer, new_user, 2, request_id: "new-user")
    assert Grains.balances(new_user) == {2, 0}
    assert {:ok, _} = Grains.transfer(new_user, payer, 2, request_id: "return-new-user")
    assert {:ok, _} = Grains.transfer(payer, payee, 5, request_id: "posted-after-cutover")
    assert {:error, :point_ledger_has_writes} = LegacyCutover.rollback_before_writes(second.id)
    assert LegacyCutover.point_id() == second.id
    assert Grains.balances(payer) == {105, 0}
    assert {:ok, report} = LegacyCutover.rollback_report(second.id)
    refute report.can_rollback_directly?
    assert report.point.ok? and report.legacy.ok?
    assert Enum.map(report.transactions, & &1.kind) == ["transfer", "transfer", "transfer"]

    assert Enum.sort(
             Enum.map(report.account_deltas, &{&1.owner_id, &1.available_delta, &1.held_delta})
           ) ==
             Enum.sort([{payer.id, -5, 0}, {payee.id, 5, 0}])

    assert {:error, :rollback_report_stale} = LegacyCutover.rollback_with_replay(second.id, [])
    reviewed = Enum.map(report.transactions, & &1.id)
    replay_id = List.last(reviewed)
    assert {:ok, :rolled_back} = LegacyCutover.rollback_with_replay(second.id, reviewed)
    assert is_nil(LegacyCutover.point_id())
    assert Repo.reload!(payer).grain_balance == 105
    assert Repo.reload!(payee).grain_balance == 5

    assert {:ok, %{id: ^replay_id}} =
             Grains.transfer(payer, payee, 5, request_id: "posted-after-cutover")

    assert Repo.reload!(payer).grain_balance == 105
    assert LegacySnapshot.audit().ok?
  end

  test "tasks can award and activity applicants can withdraw across cutover" do
    alias Rice.{Events, Tasks, Tsid}
    alias Rice.Points.{Issuers, LegacyCutover, Queries}

    publisher = task_publisher_fixture()
    worker = user_fixture()
    node = funded_node_fixture(publisher, 300)
    {:ok, _} = Grains.grant(worker, 100)

    assert {:ok, task} =
             Tasks.create_task(publisher, %{
               organizer_contact: "社区服务台",
               title: "迁移前创建",
               description: "迁移后发奖",
               reward_amount: 120
             })

    assert {:ok, application} = Tasks.apply(worker, task, %{contact: "测试联系方式"})
    assert {:ok, task} = Tasks.appoint(publisher, task, application.id)
    assert {:ok, task} = Tasks.submit_result(worker, task, %{body: "已完成"})
    submission = Enum.find(task.submissions, &is_nil(&1.review_reason))

    now = DateTime.utc_now()

    assert {:ok, event} =
             Events.create_event(publisher, %{
               organizer_contact: "社区服务台",
               node_id: node.id,
               client_request_id: "cutover-event",
               title: "迁移前活动",
               description: "迁移后退款",
               location: "活动室",
               fee_amount: 20,
               capacity: 1,
               application_deadline: DateTime.add(now, 1800),
               starts_at: DateTime.add(now, 3600),
               ends_at: DateTime.add(now, 7200)
             })

    assert {:ok, applied} = Events.apply(worker, event, %{contact: "测试联系方式"})
    event_application = Enum.find(applied.applications, &(&1.user_id == worker.id))

    assert {180, 120} = Grains.balances(Repo.reload!(node))
    assert {80, 20} = Grains.balances(Repo.reload!(worker))

    {:ok, point} =
      Issuers.bootstrap(Tsid.generate(), "business-cutover", nil, 2, [publisher.id, worker.id])

    assert {:ok, %{issued: 400, ok?: true}} = LegacyCutover.activate(point.id)

    assert {:ok, %{reward_status: "settled"}} =
             Tasks.approve_result(publisher, task, submission.id)

    assert {:ok, withdrawn} = Events.withdraw_application(worker, applied, event_application.id)

    assert Enum.find(withdrawn.applications, &(&1.id == event_application.id)).payment_status ==
             "refunded"

    assert {180, 0} = Grains.balances(node)
    assert {220, 0} = Grains.balances(worker)
    assert Repo.reload!(node).grain_frozen_balance == 120
    assert Repo.reload!(worker).grain_frozen_balance == 20
    assert {:ok, %{issued: 400, circulating: 400, ok?: true}} = Queries.reconcile(point.id)
    assert {:ok, report} = LegacyCutover.rollback_report(point.id)

    assert [
             %{kind: "hold_settle", business_outcome_uri: task_uri},
             %{kind: "hold_release", business_outcome_uri: event_uri}
           ] = report.transactions

    assert task_uri =~ task.id
    assert event_uri =~ event_application.id

    assert {:ok, :rolled_back} =
             LegacyCutover.rollback_with_replay(point.id, Enum.map(report.transactions, & &1.id))

    assert is_nil(LegacyCutover.point_id())
    assert {180, 0} = Grains.balances(Repo.reload!(node))
    assert {220, 0} = Grains.balances(Repo.reload!(worker))
    assert Repo.get_by!(Rice.Grains.Receipt, subject_uri: task_uri, kind: "settled").amount == 120

    assert Repo.get_by!(Rice.Grains.Receipt, subject_uri: event_uri, kind: "refunded").amount ==
             20

    assert LegacySnapshot.audit().ok?
  end

  test "unsupported replay rolls back earlier writes and keeps the cutover active" do
    alias Rice.Tsid
    alias Rice.Points.{Issuers, LegacyCutover, Transaction}

    payer = user_fixture()
    payee = user_fixture()
    {:ok, _} = Grains.grant(payer, 100)

    {:ok, point} =
      Issuers.bootstrap(Tsid.generate(), "unsupported-replay", nil, 2, [payer.id, payee.id])

    assert {:ok, _} = LegacyCutover.activate(point.id)
    assert {:ok, gift} = Grains.transfer(payer, payee, 5, request_id: "replay-before-unsupported")
    policy_change = Repo.insert!(%Transaction{point_id: point.id, kind: "spend_policy_change"})

    assert {:error, :unsupported_rollback_transaction} =
             LegacyCutover.rollback_with_replay(point.id, [gift.id, policy_change.id])

    assert LegacyCutover.point_id() == point.id
    refute Repo.get(Rice.Grains.Transfer, gift.id)
    assert Repo.reload!(payer).grain_balance == 100
    assert Grains.balances(payer) == {95, 0}
    assert Grains.balances(payee) == {5, 0}
  end
end

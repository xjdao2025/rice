defmodule RiceWeb.Api.PointWalletTransferControllerTest do
  use RiceWeb.ConnCase, async: true
  alias Rice.{Repo, Tsid}
  alias Rice.Points.{Account, Balance, Entry, Point}

  test "personal transfers are authenticated, atomic and idempotent, with scoped history" do
    {payer, token} = user_with_token()
    {payee, payee_token} = user_with_token()
    {outsider, outsider_token} = user_with_token()
    point = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "DEMO"})
    wallet = Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: payer.id})
    Repo.insert!(%Balance{account_id: wallet.id, owner_type: "user", available: 30})
    path = "/api/point-wallets/#{point.id}/transfers"
    history = "/api/point-wallets/#{point.id}/transactions"
    body = %{to: payee.handle, amount: "10", client_request_id: "same", note: "公开备注"}

    assert build_conn() |> post(path, body) |> response(401)
    send = fn input -> build_conn() |> auth(token) |> post(path, input) end
    assert %{"data" => %{"id" => id}} = send.(body) |> json_response(200)
    assert %{"data" => %{"id" => ^id}} = send.(body) |> json_response(200)
    assert send.(%{body | amount: "11"}) |> response(409)
    assert send.(%{body | amount: "31", client_request_id: "too-much"}) |> response(422)
    assert Repo.get_by!(Balance, account_id: wallet.id).available == 20

    recipient = Repo.get_by!(Account, point_id: point.id, owner_type: "user", owner_id: payee.id)
    assert Repo.get_by!(Balance, account_id: recipient.id).available == 10

    result = build_conn() |> auth(payee_token) |> get(history) |> json_response(200)

    assert [%{"id" => ^id, "public_note" => "公开备注", "available_delta" => "10"} = entry] =
             result["data"]

    refute Map.has_key?(entry, "private_note")
    assert Enum.all?(entry["recipients"], &(&1["account_id"] == recipient.id))
    assert build_conn() |> auth(outsider_token) |> get(history) |> response(404)

    # Failed requests provision no recipient wallet and leave no entries.
    assert send.(%{body | to: outsider.handle, amount: "31", client_request_id: "failed-new"})
           |> response(422)

    refute Repo.get_by(Account, point_id: point.id, owner_type: "user", owner_id: outsider.id)
    assert Repo.aggregate(Entry, :count) == 2
  end

  test "imported opening entries without recipients can be read" do
    {user, token} = user_with_token()
    point = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "RICE"})
    account = Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: user.id})
    tx = Repo.insert!(%Rice.Points.Transaction{point_id: point.id, kind: "legacy_opening"})

    Repo.insert!(%Entry{
      point_id: point.id,
      transaction_id: tx.id,
      account_id: account.id,
      bucket: "available",
      delta: 666
    })

    result =
      build_conn()
      |> auth(token)
      |> get("/api/point-wallets/#{point.id}/transactions")
      |> json_response(200)

    assert [%{"available_delta" => "666", "recipients" => []}] = result["data"]
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end

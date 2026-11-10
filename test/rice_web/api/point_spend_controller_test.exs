defmodule RiceWeb.Api.PointSpendControllerTest do
  use RiceWeb.ConnCase, async: true

  alias Rice.{Points, Repo, Tsid}
  alias Rice.Accounts.VerificationCode
  alias Rice.Points.{Account, Balance, Point}

  test "treasury HTTP approval requires a proposal-specific code from each signer" do
    {first, token_a} = user_with_token(%{email: "treasury-a@example.test"})
    {second, token_b} = user_with_token(%{email: "treasury-b@example.test"})
    {outsider, outsider_token} = user_with_token()
    point = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "treasury"})

    payer =
      Repo.insert!(%Account{point_id: point.id, owner_type: "node", owner_id: Tsid.generate()})

    payee = Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: outsider.id})
    Repo.insert!(%Balance{account_id: payer.id, owner_type: "node", available: 50})
    {:ok, _} = Points.bootstrap_spend_policy(point.id, payer.id, 2, [first.id, second.id])

    assert %{"data" => %{"id" => id, "status" => "pending"}} =
             build_conn()
             |> authed(token_a)
             |> put_req_header("idempotency-key", "treasury-pay")
             |> post(~p"/v1/points/#{point.id}/spend-proposals", %{
               action: "transfer",
               account_id: payer.id,
               expires_at: DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601(),
               recipients: [%{account_id: payee.id, amount: "20"}]
             })
             |> json_response(201)

    path = ~p"/v1/points/#{point.id}/spend-proposals/#{id}"

    approve = fn token ->
      build_conn()
      |> authed(token)
      |> post(path <> "/approvals", %{channel: "email", code: "123456"})
    end

    assert build_conn() |> authed(outsider_token) |> get(path) |> response(404)
    assert approve.(outsider_token) |> response(403)
    Repo.insert!(VerificationCode.build("email", first.email, "pi:" <> id, "123456"))
    assert approve.(token_a) |> response(422)

    for user <- [first, second],
        do: Repo.insert!(VerificationCode.build("email", user.email, "ps:" <> id, "123456"))

    assert %{"data" => %{"status" => "pending", "approvals" => 1}} =
             approve.(token_a) |> json_response(200)

    assert %{"data" => %{"status" => "succeeded", "transaction_id" => tx}} =
             approve.(token_b) |> json_response(200)

    assert is_binary(tx)
    assert Repo.get_by!(Balance, account_id: payee.id).available == 20
  end
end

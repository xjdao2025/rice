defmodule RiceWeb.Api.PointIssuanceControllerTest do
  use RiceWeb.ConnCase, async: false

  alias Rice.{Points, Repo, Tsid}
  alias Rice.Points.{Account, Issuers}

  test "creation is asset scoped and idempotent" do
    {proposer, token} = user_with_token()
    {signer, signer_token} = user_with_token()
    {:ok, point} = Issuers.bootstrap(Tsid.generate(), "rice", 100, 2, [proposer.id, signer.id])

    recipient =
      Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: proposer.id})

    previous = Application.get_env(:rice, :point_issuance_proposers)
    Application.put_env(:rice, :point_issuance_proposers, %{point.id => [proposer.id]})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:rice, :point_issuance_proposers, previous),
        else: Application.delete_env(:rice, :point_issuance_proposers)
    end)

    body = %{
      kind: "initial_allocation",
      reason: "Initial allocation",
      expires_at: DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601(),
      recipients: [%{account_id: recipient.id, amount: "20"}]
    }

    submit = fn auth, payload ->
      build_conn()
      |> authed(auth)
      |> put_req_header("idempotency-key", "first")
      |> post(~p"/v1/points/#{point.id}/issuances", payload)
    end

    assert submit.(signer_token, body) |> response(403)

    assert %{"data" => %{"id" => id, "total" => "20"}} =
             submit.(token, body) |> json_response(201)

    assert %{"data" => %{"id" => ^id}} = submit.(token, body) |> json_response(201)
    assert submit.(token, %{body | reason: "changed"}) |> response(409)
  end

  test "approval consumes an issuance-specific code and posts at threshold" do
    {first, first_token} = user_with_token(%{email: "issuer-first@example.test"})
    {second, second_token} = user_with_token(%{email: "issuer-second@example.test"})
    {:ok, point} = Issuers.bootstrap(Tsid.generate(), "rice", 100, 2, [first.id, second.id])
    recipient = Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: first.id})

    request = %{
      actor_id: first.id,
      idempotency_key: "start",
      recipients: [%{account_id: recipient.id, amount: 20}]
    }

    {:ok, issuance} =
      Points.propose_issuance(
        point.id,
        "initial_allocation",
        "Start",
        request,
        DateTime.add(DateTime.utc_now(), 60)
      )

    path = ~p"/v1/points/#{point.id}/issuances/#{issuance.id}/approvals"

    submit = fn token ->
      build_conn() |> authed(token) |> post(path, %{channel: "email", code: "123456"})
    end

    alias Rice.Accounts.VerificationCode
    Repo.insert!(VerificationCode.build("email", first.email, "pi:" <> Tsid.generate(), "123456"))
    assert submit.(first_token) |> response(422)

    for user <- [first, second],
        do:
          Repo.insert!(
            VerificationCode.build("email", user.email, "pi:" <> issuance.id, "123456")
          )

    assert %{"data" => %{"status" => "pending", "approvals" => 1}} =
             submit.(first_token) |> json_response(200)

    assert submit.(first_token) |> response(422)

    assert %{"data" => %{"status" => "succeeded", "transaction_id" => tx}} =
             submit.(second_token) |> json_response(200)

    assert is_binary(tx)
  end

  test "policy change can be approved by a signer being removed" do
    {first, first_token} = user_with_token(%{email: "policy-first@example.test"})
    {second, second_token} = user_with_token(%{email: "policy-second@example.test"})
    {next, next_token} = user_with_token()
    {:ok, point} = Issuers.bootstrap(Tsid.generate(), "rice", 100, 2, [first.id, second.id])

    body = %{
      kind: "policy_change",
      reason: "Rotate",
      signers: [first.id, next.id],
      threshold: 2,
      supply_cap: "150",
      expires_at: DateTime.utc_now() |> DateTime.add(60) |> DateTime.to_iso8601()
    }

    create = fn token ->
      build_conn()
      |> authed(token)
      |> put_req_header("idempotency-key", "rotate")
      |> post(~p"/v1/points/#{point.id}/issuances", body)
    end

    assert create.(next_token) |> response(403)

    assert %{"data" => %{"id" => id, "status" => "pending"}} =
             create.(first_token) |> json_response(201)

    path = ~p"/v1/points/#{point.id}/issuances/#{id}/approvals"

    approve = fn token ->
      build_conn() |> authed(token) |> post(path, %{channel: "email", code: "123456"})
    end

    assert approve.(next_token) |> response(403)

    for user <- [first, second] do
      Repo.insert!(
        Rice.Accounts.VerificationCode.build("email", user.email, "pi:" <> id, "123456")
      )
    end

    assert %{"data" => %{"status" => "pending"}} = approve.(first_token) |> json_response(200)

    assert %{"data" => %{"id" => ^id, "status" => "succeeded"}} =
             approve.(second_token) |> json_response(200)

    assert build_conn()
           |> authed(second_token)
           |> get(~p"/v1/points/#{point.id}/issuances/#{id}")
           |> response(404)
  end

  test "only the proposer and current signers may read issuance details" do
    {proposer, proposer_token} = user_with_token()
    {signer, signer_token} = user_with_token()
    {_, outsider_token} = user_with_token()
    {:ok, point} = Issuers.bootstrap(Tsid.generate(), "rice", 100, 2, [proposer.id, signer.id])

    recipient =
      Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: proposer.id})

    {:ok, issuance} =
      Points.propose_issuance(
        point.id,
        "initial_allocation",
        "Initial allocation",
        %{
          actor_id: proposer.id,
          idempotency_key: "start",
          recipients: [%{account_id: recipient.id, amount: 20}]
        },
        DateTime.add(DateTime.utc_now(), 60)
      )

    path = ~p"/v1/points/#{point.id}/issuances/#{issuance.id}"

    for token <- [proposer_token, signer_token] do
      assert %{"data" => %{"status" => "pending", "total" => "20"}} =
               build_conn() |> authed(token) |> get(path) |> json_response(200)
    end

    assert build_conn() |> authed(outsider_token) |> get(path) |> response(404)
    assert build_conn() |> get(path) |> response(401)
  end
end

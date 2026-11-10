defmodule RiceWeb.Api.PointPaymentControllerTest do
  use RiceWeb.ConnCase, async: true

  alias Rice.{Repo, Tsid}
  alias Rice.Points.{Account, Payments, Point}
  alias RiceWeb.Api.PointPaymentController

  test "application credentials create signed checkout links and isolate order lookups" do
    point = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "rice"})

    payee =
      Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: Tsid.generate()})

    {:ok, store} = Payments.register_app("Store", payee.id, "https://store.example/return")
    {:ok, other} = Payments.register_app("Other", payee.id, "https://other.example/return")

    body = %{external_order_id: "invoice", amount: "20"}

    create = fn credential, params ->
      build_conn() |> authed(credential) |> post(~p"/v1/payment-intents", params)
    end

    assert %{"data" => %{"id" => id, "checkout_url" => url, "amount" => "20"}} =
             create.(store.credential, body) |> json_response(201)

    token = URI.parse(url).path |> String.replace_prefix("/point-checkout/", "")
    assert {:ok, ^id} = PointPaymentController.verify_checkout_token(token)
    assert {:error, :not_found} = PointPaymentController.verify_checkout_token(token <> "x")

    assert %{"data" => %{"id" => ^id}} = create.(store.credential, body) |> json_response(201)
    assert create.(store.credential, %{body | amount: "21"}) |> response(409)
    assert create.(store.credential, %{body | amount: "020"}) |> response(422)
    assert create.("invalid", body) |> response(401)

    assert %{"data" => %{"id" => ^id, "status" => "pending"}} =
             build_conn()
             |> authed(store.credential)
             |> get(~p"/v1/payment-intents/#{id}")
             |> json_response(200)

    assert build_conn()
           |> authed(other.credential)
           |> get(~p"/v1/payment-intents/#{id}")
           |> response(404)
  end

  test "the signed checkout confirms with a user session and the merchant can recover the result" do
    {user, session} = user_with_token()
    point = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "rice"})
    payer = Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: user.id})

    payee =
      Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: Tsid.generate()})

    Repo.insert!(%Rice.Points.Balance{account_id: payer.id, owner_type: "user", available: 30})
    {:ok, app} = Payments.register_app("Store", payee.id, "https://store.example/return?ref=one")

    assert %{"data" => %{"id" => id, "checkout_url" => url}} =
             build_conn()
             |> authed(app.credential)
             |> post(~p"/v1/payment-intents", %{external_order_id: "checkout", amount: "20"})
             |> json_response(201)

    token = URI.parse(url).path |> String.replace_prefix("/point-checkout/", "")
    path = ~p"/api/point-checkout/#{token}"

    assert build_conn() |> post(path) |> response(401)

    assert %{"data" => %{"status" => "pending", "app_name" => "Store", "amount" => "20"}} =
             build_conn() |> authed(session) |> get(path) |> json_response(200)

    assert %{"data" => %{"status" => "succeeded", "return_url" => target}} =
             build_conn() |> authed(session) |> post(path) |> json_response(200)

    assert target == "https://store.example/return?ref=one&rice_order_id=" <> id

    assert %{"data" => %{"status" => "succeeded", "transaction_id" => tx}} =
             build_conn()
             |> authed(app.credential)
             |> get(~p"/v1/payment-intents/#{id}")
             |> json_response(200)

    assert is_binary(tx)
  end
end

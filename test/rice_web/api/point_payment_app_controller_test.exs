defmodule RiceWeb.Api.PointPaymentAppControllerTest do
  use RiceWeb.ConnCase, async: true

  alias Rice.{Repo, Tsid, Vault}
  alias Rice.Points.{Account, PaymentApp, Payments, Point}

  test "owners register, reveal repeatedly and rotate, while other users cannot read secrets" do
    {user, token} = user_with_token()
    {other, other_token} = user_with_token()
    point = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "DEMO"})
    account = Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: user.id})
    body = %{point_id: point.id, name: "My app", return_url: "https://shop.example/return"}

    assert build_conn() |> post("/api/payment-apps", body) |> response(401)
    assert build_conn() |> auth(other_token) |> post("/api/payment-apps", body) |> response(404)

    created = build_conn() |> auth(token) |> post("/api/payment-apps", body)

    assert %{"data" => %{"id" => id, "payee_account_id" => wallet_id} = metadata} =
             json_response(created, 201)

    assert wallet_id == account.id
    refute Map.has_key?(metadata, "credential")
    refute Map.has_key?(metadata, "credential_digest")
    refute Map.has_key?(metadata, "credential_ciphertext")
    assert get_resp_header(created, "cache-control") == ["no-store"]

    reveal = fn session ->
      build_conn() |> auth(session) |> post("/api/payment-apps/#{id}/credential")
    end

    revealed = reveal.(token)
    assert %{"data" => %{"credential" => key}} = json_response(revealed, 200)
    assert get_resp_header(revealed, "cache-control") == ["no-store"]
    assert %{"data" => %{"credential" => ^key}} = reveal.(token) |> json_response(200)
    app = Repo.get!(PaymentApp, id)
    assert app.owner_user_id == user.id
    assert app.credential_ciphertext != key
    assert {:ok, ^key} = Vault.decrypt(app.credential_ciphertext)
    assert {:ok, _} = Payments.create(key, "order", 10)

    assert reveal.(other_token) |> response(404)

    assert build_conn()
           |> auth(other_token)
           |> post("/api/payment-apps/#{id}/rotate-credential")
           |> response(404)

    assert %{"data" => []} =
             build_conn() |> auth(other_token) |> get("/api/payment-apps") |> json_response(200)

    assert %{"data" => [listed]} =
             build_conn() |> auth(token) |> get("/api/payment-apps") |> json_response(200)

    refute Map.has_key?(listed, "credential")
    refute Map.has_key?(listed, "credential_ciphertext")

    assert %{"data" => %{"credential" => replacement}} =
             build_conn()
             |> auth(token)
             |> post("/api/payment-apps/#{id}/rotate-credential")
             |> json_response(200)

    assert replacement != key
    assert {:error, :invalid_app_credential} = Payments.lookup(key, "missing")
    assert %{"data" => %{"credential" => ^replacement}} = reveal.(token) |> json_response(200)
    assert {:ok, _} = Payments.create(replacement, "order2", 10)
    assert is_binary(other.id)
  end

  test "legacy digests require explicit rotation and invalid registrations persist nothing" do
    {user, token} = user_with_token()
    point = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "RICE"})
    account = Repo.insert!(%Account{point_id: point.id, owner_type: "user", owner_id: user.id})

    {:ok, %{app: app, credential: key}} =
      Payments.register_app("Legacy", account.id, "https://shop.example/return")

    Repo.update!(Ecto.Changeset.change(app, credential_ciphertext: nil))

    assert %{"error" => "credential_unavailable"} =
             build_conn()
             |> auth(token)
             |> post("/api/payment-apps/#{app.id}/credential")
             |> json_response(409)

    assert {:ok, _} = Payments.create(key, "still-works", 1)

    for url <- [
          "http://shop.example",
          "https://user:password@shop.example",
          "https://shop.example/#fragment"
        ] do
      assert build_conn()
             |> auth(token)
             |> post("/api/payment-apps", %{point_id: point.id, name: "Bad", return_url: url})
             |> response(422)
    end

    assert Repo.aggregate(PaymentApp, :count) == 1
  end

  defp auth(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end

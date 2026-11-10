defmodule RiceWeb.Api.PointWalletControllerTest do
  use RiceWeb.ConnCase, async: true

  alias Rice.{Repo, Tsid}
  alias Rice.Points.{Account, Balance, Point}

  test "only returns the authenticated user's wallets and preserves bigint amounts", %{conn: conn} do
    {user, token} = user_with_token()
    other = user_fixture()
    demo = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "DEMO"})
    empty = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "EMPTY"})
    hidden = Repo.insert!(%Point{issuer_community_id: Tsid.generate(), code: "HIDDEN"})
    wallet = Repo.insert!(%Account{point_id: demo.id, owner_type: "user", owner_id: user.id})
    Repo.insert!(%Account{point_id: empty.id, owner_type: "user", owner_id: user.id})
    Repo.insert!(%Account{point_id: hidden.id, owner_type: "user", owner_id: other.id})

    Repo.insert!(%Balance{
      account_id: wallet.id,
      owner_type: "user",
      available: 9_007_199_254_740_993,
      held: 7
    })

    assert response(get(conn, ~p"/api/point-wallets"), 401)

    result =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> get(~p"/api/point-wallets")

    assert get_resp_header(result, "cache-control") == ["no-store"]

    assert %{
             "data" => [
               %{"code" => "DEMO", "available" => "9007199254740993", "held" => "7"},
               %{"code" => "EMPTY", "available" => "0", "held" => "0"}
             ]
           } = json_response(result, 200)
  end
end

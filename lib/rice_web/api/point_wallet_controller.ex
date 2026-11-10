defmodule RiceWeb.Api.PointWalletController do
  use RiceWeb, :controller

  import Ecto.Query
  alias Rice.Points.{Account, Balance, LegacyCutover, Point}
  alias Rice.Repo

  def index(conn, _params) do
    user_id = conn.assigns.current_user.id
    rice_id = LegacyCutover.point_id()

    wallets =
      Repo.all(
        from a in Account,
          join: p in Point,
          on: p.id == a.point_id,
          left_join: b in Balance,
          on: b.account_id == a.id,
          where: a.owner_type == "user" and a.owner_id == ^user_id,
          order_by: [asc: p.code, asc: p.id],
          select:
            {p.id, p.code, p.status, a.status, coalesce(b.available, 0), coalesce(b.held, 0)}
      )

    data =
      Enum.map(wallets, fn {point_id, code, status, wallet_status, available, held} ->
        %{
          point_id: point_id,
          code: code,
          name: if(point_id == rice_id, do: "稻米", else: code),
          status: status,
          wallet_status: wallet_status,
          available: Integer.to_string(available),
          held: Integer.to_string(held)
        }
      end)

    conn |> put_resp_header("cache-control", "no-store") |> json(%{data: data})
  end
end

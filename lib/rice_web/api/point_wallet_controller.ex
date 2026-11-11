defmodule RiceWeb.Api.PointWalletController do
  use RiceWeb, :controller

  import Ecto.Query
  alias Rice.Points.{Account, Balance, Entry, LegacyCutover, Point, Transaction}
  alias Rice.Repo

  def index(conn, _params) do
    user_id = conn.assigns.current_user.id
    rice_id = LegacyCutover.point_id()

    earned =
      Repo.all(
        from e in Entry,
          join: a in Account,
          on: a.id == e.account_id,
          join: t in Transaction,
          on: t.id == e.transaction_id,
          where:
            a.owner_type == "user" and a.owner_id == ^user_id and
              e.bucket == "available" and e.delta > 0 and
              t.kind not in ["legacy_opening", "legacy_opening_hold", "hold_release"],
          group_by: a.point_id,
          select: {a.point_id, fragment("sum(?)::text", e.delta)}
      )
      |> Map.new(fn {id, amount} -> {id, String.to_integer(amount)} end)

    legacy_earned =
      if rice_id do
        Repo.one(
          from t in Rice.Grains.Transfer,
            where: t.to_user_id == ^user_id,
            select: fragment("coalesce(sum(?), 0)::text", t.amount)
        )
        |> String.to_integer()
      else
        0
      end

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
          is_rice: point_id == rice_id,
          name: if(point_id == rice_id, do: "稻米", else: code),
          status: status,
          wallet_status: wallet_status,
          available: Integer.to_string(available),
          held: Integer.to_string(held),
          earned:
            Integer.to_string(
              Map.get(earned, point_id, 0) + if(point_id == rice_id, do: legacy_earned, else: 0)
            )
        }
      end)

    conn |> put_resp_header("cache-control", "no-store") |> json(%{data: data})
  end
end

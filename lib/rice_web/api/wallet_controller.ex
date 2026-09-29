defmodule RiceWeb.Api.WalletController do
  use RiceWeb, :controller

  def show(conn, params),
    do: json(conn, %{data: Rice.Grains.wallet(conn.assigns.current_user, params)})
end

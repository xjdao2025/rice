defmodule RiceWeb.Api.InboxController do
  use RiceWeb, :controller
  def index(conn, params), do: json(conn, Rice.Inbox.list_page(conn.assigns.current_user, params))

  def read(conn, _) do
    Rice.Inbox.mark_read(conn.assigns.current_user)
    send_resp(conn, :no_content, "")
  end
end

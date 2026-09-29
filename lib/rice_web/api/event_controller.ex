defmodule RiceWeb.Api.EventController do
  use RiceWeb, :controller
  alias Rice.Events
  action_fallback RiceWeb.Api.FallbackController

  def index(conn, params),
    do:
      render(conn, :index,
        page: Events.list_events(conn.assigns[:current_user], params),
        current_user: conn.assigns[:current_user]
      )

  def show(conn, %{"id" => id}) do
    with {:ok, event} <- Events.fetch_event(id, conn.assigns[:current_user]),
         do: render(conn, :show, event: event, current_user: conn.assigns[:current_user])
  end

  def create(conn, params) do
    with {:ok, event} <- Events.create_event(conn.assigns.current_user, params),
         do:
           conn
           |> put_status(:created)
           |> render(:show, event: event, current_user: conn.assigns.current_user)
  end

  def update(conn, %{"event_id" => id} = params),
    do: change(conn, id, &Events.update_event(&1, &2, params))

  def publish(conn, %{"event_id" => id}), do: change(conn, id, &Events.publish_draft/2)
  def cancel(conn, %{"event_id" => id}), do: change(conn, id, &Events.cancel/2)
  def finish(conn, %{"event_id" => id}), do: change(conn, id, &Events.finish/2)

  def apply(conn, %{"event_id" => id} = params),
    do: change(conn, id, &Events.apply(&1, &2, params))

  def approve(conn, %{"event_id" => id, "application_id" => application_id}),
    do: change(conn, id, &Events.approve_application(&1, &2, application_id))

  def reject(conn, %{"event_id" => id, "application_id" => application_id}),
    do: change(conn, id, &Events.reject_application(&1, &2, application_id))

  def remove(conn, %{"event_id" => id, "application_id" => application_id}),
    do: change(conn, id, &Events.remove_application(&1, &2, application_id))

  def withdraw(conn, %{"event_id" => id, "application_id" => application_id}),
    do: change(conn, id, &Events.withdraw_application(&1, &2, application_id))

  defp change(conn, id, action) do
    user = conn.assigns.current_user

    with {:ok, event} <- Events.fetch_event(id, user),
         {:ok, event} <- action.(user, event),
         do: render(conn, :show, event: event, current_user: user)
  end
end

defmodule RiceWeb.Api.TaskController do
  @moduledoc "Task V1 的列表、详情和状态动作。"
  use RiceWeb, :controller

  alias Rice.Tasks

  action_fallback(RiceWeb.Api.FallbackController)

  def index(conn, params) do
    render(conn, :index,
      page: Tasks.list_tasks(conn.assigns[:current_user], params),
      current_user: conn.assigns[:current_user]
    )
  end

  def show(conn, %{"id" => id}) do
    with {:ok, task} <- Tasks.fetch_task(id, conn.assigns[:current_user]) do
      render(conn, :show, task: task, current_user: conn.assigns[:current_user])
    end
  end

  def create(conn, params) do
    key = params["client_request_id"]

    with true <- is_binary(key) and byte_size(key) in 1..128,
         {:ok, task} <- Tasks.create_task(conn.assigns.current_user, params) do
      conn
      |> put_status(:created)
      |> render(:show, task: task, current_user: conn.assigns.current_user)
    else
      false -> {:error, :missing_request_id}
      error -> error
    end
  end

  def update(conn, %{"task_id" => task_id} = params),
    do: change(conn, task_id, &Tasks.update_task(&1, &2, params))

  def apply(conn, %{"task_id" => task_id} = params) do
    with {:ok, task} <- Tasks.fetch_task(task_id, conn.assigns.current_user),
         {:ok, _application} <- Tasks.apply(conn.assigns.current_user, task, params),
         {:ok, task} <- Tasks.fetch_task(task.id, conn.assigns.current_user) do
      conn
      |> put_status(:created)
      |> render(:show, task: task, current_user: conn.assigns.current_user)
    end
  end

  def publish(conn, %{"task_id" => task_id}), do: change(conn, task_id, &Tasks.publish_draft/2)

  def cancel(conn, %{"task_id" => task_id}), do: change(conn, task_id, &Tasks.cancel/2)

  def appoint(conn, %{"task_id" => task_id, "application_id" => application_id}),
    do: change(conn, task_id, &Tasks.appoint(&1, &2, application_id, conn.params))

  def submit(conn, %{"task_id" => task_id} = params) do
    with {:ok, task} <- Tasks.fetch_task(task_id, conn.assigns.current_user),
         {:ok, task} <- Tasks.submit_result(conn.assigns.current_user, task, params) do
      conn
      |> put_status(:created)
      |> render(:show, task: task, current_user: conn.assigns.current_user)
    end
  end

  def reject_application(conn, %{"task_id" => task_id, "application_id" => application_id}),
    do: change(conn, task_id, &Tasks.reject_application(&1, &2, application_id))

  def approve(conn, %{"task_id" => task_id, "submission_id" => submission_id}),
    do: change(conn, task_id, &Tasks.approve_result(&1, &2, submission_id))

  def request_changes(
        conn,
        %{"task_id" => task_id, "submission_id" => submission_id} = params
      ),
      do:
        change(
          conn,
          task_id,
          &Tasks.request_changes(&1, &2, submission_id, params["reason"] || "")
        )

  defp change(conn, task_id, action) do
    user = conn.assigns.current_user

    with {:ok, task} <- Tasks.fetch_task(task_id, user),
         {:ok, task} <- action.(user, task),
         do: render(conn, :show, task: task, current_user: user)
  end

  def notifications(conn, _params) do
    render(conn, :notifications,
      notifications: Tasks.list_notifications(conn.assigns.current_user)
    )
  end

  def read_notifications(conn, _params) do
    Tasks.mark_notifications_read(conn.assigns.current_user)
    send_resp(conn, :no_content, "")
  end
end

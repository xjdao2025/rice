defmodule RiceWeb.Api.PointPaymentAppController do
  use RiceWeb, :controller
  alias Rice.Points.Payments

  def index(conn, _params) do
    apps = Payments.apps_for_user(conn.assigns.current_user.id)
    respond(conn, %{data: Enum.map(apps, &metadata/1)})
  end

  def create(conn, %{"point_id" => point_id, "name" => name, "return_url" => return_url})
      when is_binary(point_id) and is_binary(name) and is_binary(return_url) do
    case Payments.register_for_user(conn.assigns.current_user.id, point_id, name, return_url) do
      {:ok, %{app: app}} ->
        conn
        |> put_status(:created)
        |> respond(%{data: metadata(app)})

      {:error, reason} ->
        error(conn, reason)
    end
  end

  def create(conn, _params), do: error(conn, :invalid_registration)

  def credential(conn, %{"id" => id}) do
    case Payments.credential_for_user(id, conn.assigns.current_user.id) do
      {:ok, value} -> respond(conn, %{data: %{credential: value}})
      {:error, reason} -> error(conn, reason)
    end
  end

  def rotate(conn, %{"id" => id}) do
    case Payments.rotate_for_user(id, conn.assigns.current_user.id) do
      {:ok, value} -> respond(conn, %{data: %{credential: value}})
      {:error, reason} -> error(conn, reason)
    end
  end

  defp metadata(app) do
    %{
      id: app.id,
      name: app.name,
      point_id: app.point_id,
      payee_account_id: app.payee_account_id,
      return_url: app.return_url,
      active: app.active,
      credential_stored: is_binary(app.credential_ciphertext)
    }
  end

  defp respond(conn, body) do
    conn |> put_resp_header("cache-control", "no-store") |> json(body)
  end

  defp error(conn, reason) do
    {status, code} =
      case reason do
        :not_found ->
          {:not_found, "not_found"}

        :credential_unavailable ->
          {:conflict, "credential_unavailable"}

        :credential_storage_unavailable ->
          {:service_unavailable, "credential_storage_unavailable"}

        _ ->
          {:unprocessable_entity, "invalid_registration"}
      end

    conn |> put_status(status) |> respond(%{error: code})
  end
end

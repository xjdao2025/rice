defmodule RiceWeb.Api.PointPaymentController do
  use RiceWeb, :controller

  alias Rice.Repo
  alias Rice.Points.{Account, LegacyCutover, PaymentIntent, Payments, Point}
  alias RiceWeb.Endpoint

  @checkout_salt "point-checkout-v1"

  def create(conn, %{"external_order_id" => id, "amount" => value}) do
    with {:ok, credential} <- credential(conn),
         {:ok, amount} <- amount(value),
         {:ok, order} <- Payments.create(credential, id, amount) do
      token = Phoenix.Token.sign(Endpoint, @checkout_salt, order.id)
      origin = Application.get_env(:rice, :point_checkout_origin) || Endpoint.url()
      url = String.trim_trailing(origin, "/") <> "/point-checkout/" <> token

      conn
      |> put_status(:created)
      |> json(%{data: Map.put(order_data(order), :checkout_url, url)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def create(conn, _), do: error(conn, :invalid_order)

  def show(conn, %{"id" => id}) do
    with {:ok, credential} <- credential(conn),
         {:ok, order} <- Payments.lookup(credential, id) do
      json(conn, %{data: order_data(order)})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def checkout(conn, %{"token" => token}) do
    with {:ok, id} <- verify_checkout_token(token),
         %PaymentIntent{} = order <- Repo.get(PaymentIntent, id) do
      point = Repo.get!(Point, order.point_id)
      payee = Repo.get!(Account, order.payee_account_id)

      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{
        data: %{
          id: order.id,
          status: Payments.status(order),
          app_name: order.app_name,
          payee_name: payee_name(payee),
          point_code: point.code,
          point_name: if(LegacyCutover.point_id() == point.id, do: "稻米", else: point.code),
          amount: Integer.to_string(order.amount),
          return_url: return_url(order)
        }
      })
    else
      _ -> error(conn, :not_found)
    end
  end

  def confirm(conn, %{"token" => token}) do
    with {:ok, id} <- verify_checkout_token(token),
         {:ok, order} <- Payments.confirm(id, conn.assigns.current_user.id) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> json(%{
        data: %{id: order.id, status: Payments.status(order), return_url: return_url(order)}
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp return_url(order) do
    order.return_url
    |> URI.parse()
    |> URI.append_query(URI.encode_query(%{"rice_order_id" => order.id}))
    |> URI.to_string()
  end

  defp payee_name(%Account{owner_type: "user", owner_id: id}) do
    case Repo.get(Rice.Accounts.User, id) do
      %{handle: handle, nickname: name} when is_binary(handle) ->
        if name in [nil, ""], do: "@" <> handle, else: name <> " (@" <> handle <> ")"

      _ ->
        id
    end
  end

  defp payee_name(%Account{owner_type: "node", owner_id: id}) do
    case Repo.get(Rice.Community.Node, id) do
      %{name: name} -> name
      _ -> id
    end
  end

  defp payee_name(account), do: account.id

  @doc false
  @spec verify_checkout_token(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def verify_checkout_token(token) do
    case Phoenix.Token.verify(Endpoint, @checkout_salt, token, max_age: 86_400) do
      {:ok, id} when is_binary(id) -> {:ok, id}
      _ -> {:error, :not_found}
    end
  end

  defp order_data(order) do
    data = %{
      id: order.id,
      external_order_id: order.external_order_id,
      status: Payments.status(order),
      point_id: order.point_id,
      amount: Integer.to_string(order.amount),
      expires_at: order.expires_at
    }

    if order.transaction_id, do: Map.put(data, :transaction_id, order.transaction_id), else: data
  end

  defp credential(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _ -> {:error, :invalid_app_credential}
    end
  end

  defp amount(value) when is_binary(value) and byte_size(value) in 1..19 do
    case Integer.parse(value) do
      {number, ""} when number > 0 ->
        if Integer.to_string(number) == value, do: {:ok, number}, else: {:error, :invalid_order}

      _ ->
        {:error, :invalid_order}
    end
  end

  defp amount(_), do: {:error, :invalid_order}

  defp error(conn, reason) do
    status =
      case reason do
        :invalid_app_credential -> :unauthorized
        :not_found -> :not_found
        :idempotency_conflict -> :conflict
        _ -> :unprocessable_entity
      end

    conn |> put_status(status) |> json(%{error: Atom.to_string(reason)})
  end
end

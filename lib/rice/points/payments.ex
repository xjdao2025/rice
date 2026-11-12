defmodule Rice.Points.Payments do
  @moduledoc "Third-party orders and atomic confirmation from an authenticated personal wallet."

  import Ecto.Query
  import Ecto.Changeset

  alias Rice.{Points, Repo, Tsid, Vault}
  alias Rice.Points.{Account, PaymentApp, PaymentIntent, Point}

  @max_amount 9_223_372_036_854_775_807
  @order_ttl_seconds 30 * 60

  @doc "Registers an application, storing the credential encrypted for its owner."
  @spec register_app(String.t(), String.t(), String.t()) ::
          {:ok, %{app: PaymentApp.t(), credential: String.t()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def register_app(name, account_id, return_url) do
    with true <- valid_return_url?(return_url) and valid_id?(account_id),
         %Account{status: "active", owner_type: type} = account when type != "system" <-
           Repo.get(Account, account_id),
         {:ok, credential, ciphertext} <- generate_stored_credential() do
      %PaymentApp{
        point_id: account.point_id,
        payee_account_id: account.id,
        credential_digest: digest(credential),
        credential_ciphertext: ciphertext,
        owner_user_id: personal_owner(account),
        return_url: return_url
      }
      |> cast(%{name: name}, [:name])
      |> update_change(:name, &String.trim/1)
      |> validate_required([:name])
      |> validate_length(:name, max: 255)
      |> Repo.insert()
      |> case do
        {:ok, app} -> {:ok, %{app: app, credential: credential}}
        error -> error
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_registration}
    end
  end

  @doc "Rotates an app credential and stores its encrypted replacement."
  @spec rotate_credential(String.t()) ::
          {:ok, String.t()} | {:error, :not_found | :credential_storage_unavailable}
  def rotate_credential(app_id) do
    with {:ok, credential, ciphertext} <- generate_stored_credential(),
         {:ok, _} <-
           update_app(app_id,
             credential_digest: digest(credential),
             credential_ciphertext: ciphertext
           ) do
      {:ok, credential}
    end
  end

  @doc "Registers a personal collection app for the authenticated wallet owner."
  @spec register_for_user(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{app: PaymentApp.t(), credential: String.t()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def register_for_user(user_id, point_id, name, return_url) do
    if valid_id?(user_id) and valid_id?(point_id) do
      Repo.transaction(fn ->
        account =
          Repo.one(
            from a in Account,
              join: p in Point,
              on: p.id == a.point_id,
              where:
                a.point_id == ^point_id and a.owner_type == "user" and
                  a.owner_id == ^user_id and a.status == "active" and p.status == "active",
              lock: "FOR SHARE"
          ) || Repo.rollback(:not_found)

        case register_app(name, account.id, return_url) do
          {:ok, result} -> result
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    else
      {:error, :not_found}
    end
  end

  @doc "Lists app metadata for the authenticated owner, without secret fields."
  @spec apps_for_user(String.t()) :: [PaymentApp.t()]
  def apps_for_user(user_id) do
    Repo.all(from a in PaymentApp, where: a.owner_user_id == ^user_id, order_by: [desc: a.id])
  end

  @doc "Reveals a stored app credential only to its personal collection wallet owner."
  @spec credential_for_user(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def credential_for_user(app_id, user_id) do
    with {:ok, app} <- owned_app(app_id, user_id),
         true <- is_binary(app.credential_ciphertext),
         {:ok, credential} <- Vault.decrypt(app.credential_ciphertext),
         true <- Plug.Crypto.secure_compare(digest(credential), app.credential_digest) do
      {:ok, credential}
    else
      {:error, :not_found} -> {:error, :not_found}
      _ -> {:error, :credential_unavailable}
    end
  end

  @doc "Rotates a personal app credential after owner authorization."
  @spec rotate_for_user(String.t(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def rotate_for_user(app_id, user_id) do
    Repo.transaction(fn ->
      with {:ok, _app} <- owned_app(app_id, user_id),
           {:ok, credential} <- rotate_credential(app_id) do
        credential
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp owned_app(app_id, user_id) do
    if valid_id?(app_id) and valid_id?(user_id) do
      case Repo.one(
             from app in PaymentApp,
               join: a in Account,
               on: a.id == app.payee_account_id,
               where:
                 app.id == ^app_id and app.owner_user_id == ^user_id and
                   a.owner_type == "user" and a.owner_id == ^user_id
           ) do
        nil -> {:error, :not_found}
        app -> {:ok, app}
      end
    else
      {:error, :not_found}
    end
  end

  defp personal_owner(%Account{owner_type: "user", owner_id: id}) do
    if valid_id?(id) and Repo.get(Rice.Accounts.User, id), do: id
  end

  defp personal_owner(_), do: nil

  defp generate_stored_credential do
    credential = new_credential()
    {:ok, credential, Vault.encrypt(credential)}
  rescue
    _ -> {:error, :credential_storage_unavailable}
  end

  @doc "Enables or disables payment access for a registered app."
  @spec set_active(String.t(), boolean()) :: {:ok, PaymentApp.t()} | {:error, :not_found}
  def set_active(app_id, active) when is_boolean(active), do: update_app(app_id, active: active)

  defp update_app(app_id, attrs) do
    if valid_id?(app_id) do
      Repo.transaction(fn ->
        app =
          Repo.one(from a in PaymentApp, where: a.id == ^app_id, lock: "FOR UPDATE") ||
            Repo.rollback(:not_found)

        Repo.update!(change(app, attrs))
      end)
    else
      {:error, :not_found}
    end
  end

  @doc "Creates or replays an order using an application's private credential."
  @spec create(String.t(), String.t(), pos_integer()) ::
          {:ok, PaymentIntent.t()} | {:error, atom()}
  def create(credential, external_order_id, amount)
      when is_binary(external_order_id) and byte_size(external_order_id) in 1..255 and
             is_integer(amount) and amount in 1..@max_amount do
    if String.valid?(external_order_id) and not String.contains?(external_order_id, <<0>>) and
         String.trim(external_order_id) != "" do
      Repo.transaction(fn ->
        app = authenticate!(credential, "FOR UPDATE")

        case Repo.get_by(PaymentIntent, app_id: app.id, external_order_id: external_order_id) do
          %PaymentIntent{amount: ^amount} = order -> order
          %PaymentIntent{} -> Repo.rollback(:idempotency_conflict)
          nil -> create_order!(app, external_order_id, amount)
        end
      end)
    else
      {:error, :invalid_order}
    end
  end

  def create(_, _, _), do: {:error, :invalid_order}

  @doc "Looks up only orders belonging to the authenticated application."
  @spec lookup(String.t(), String.t()) :: {:ok, PaymentIntent.t()} | {:error, atom()}
  def lookup(credential, id) do
    Repo.transaction(fn ->
      app = authenticate!(credential, "FOR SHARE")
      if not valid_id?(id), do: Repo.rollback(:not_found)
      Repo.get_by(PaymentIntent, app_id: app.id, id: id) || Repo.rollback(:not_found)
    end)
  end

  @doc "Confirms an order after the browser's checkout token and session are verified."
  @spec confirm(String.t(), String.t()) :: {:ok, PaymentIntent.t()} | {:error, atom()}
  def confirm(id, user_id) do
    if valid_id?(id) and valid_id?(user_id) do
      Repo.transaction(fn ->
        order = Repo.get(PaymentIntent, id) || Repo.rollback(:not_found)
        app = Repo.one!(from a in PaymentApp, where: a.id == ^order.app_id, lock: "FOR SHARE")
        order = Repo.one!(from i in PaymentIntent, where: i.id == ^id, lock: "FOR UPDATE")

        case status(order) do
          "succeeded" -> order
          "pending" when app.active -> pay!(order, user_id)
          "pending" -> Repo.rollback(:app_disabled)
          "expired" -> Repo.rollback(:order_expired)
          _ -> Repo.rollback(:order_closed)
        end
      end)
    else
      {:error, :not_found}
    end
  end

  @doc "Computes the effective status consistently for reads and writes."
  @spec status(PaymentIntent.t()) :: String.t()
  def status(%PaymentIntent{status: "pending", expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt, do: "pending", else: "expired"
  end

  def status(%PaymentIntent{status: status}), do: status

  defp pay!(order, user_id) do
    payer =
      Repo.get_by(Account, point_id: order.point_id, owner_type: "user", owner_id: user_id) ||
        Repo.rollback(:wallet_not_found)

    if payer.id == order.payee_account_id, do: Repo.rollback(:self_payment)

    result =
      Points.transfer(%{
        payer_account_id: payer.id,
        actor_id: user_id,
        idempotency_key: order.id,
        recipients: [%{account_id: order.payee_account_id, amount: order.amount}]
      })

    case result do
      {:ok, tx} ->
        if status(order) == "expired", do: Repo.rollback(:order_expired)

        Repo.update!(change(order, status: "succeeded", transaction_id: tx.id))

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp create_order!(app, external_order_id, amount) do
    unless Repo.exists?(
             from a in Account,
               join: p in Point,
               on: p.id == a.point_id,
               where:
                 a.id == ^app.payee_account_id and a.point_id == ^app.point_id and
                   a.status == "active" and a.owner_type != "system" and p.status == "active"
           ),
           do: Repo.rollback(:payee_unavailable)

    Repo.insert!(%PaymentIntent{
      app_id: app.id,
      app_name: app.name,
      return_url: app.return_url,
      external_order_id: external_order_id,
      point_id: app.point_id,
      payee_account_id: app.payee_account_id,
      amount: amount,
      expires_at: DateTime.add(DateTime.utc_now(), @order_ttl_seconds)
    })
  end

  defp authenticate!(credential, lock)
       when is_binary(credential) and byte_size(credential) == 52 do
    value = digest(credential)

    query = from a in PaymentApp, where: a.credential_digest == ^value and a.active

    locked =
      case lock do
        "FOR UPDATE" -> from a in query, lock: "FOR UPDATE"
        "FOR SHARE" -> from a in query, lock: "FOR SHARE"
      end

    Repo.one(locked) || Repo.rollback(:invalid_app_credential)
  end

  defp authenticate!(_, _), do: Repo.rollback(:invalid_app_credential)

  defp new_credential do
    "rice_pay_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  defp digest(credential), do: :crypto.hash(:sha256, credential)

  defp valid_id?(id), do: is_binary(id) and Tsid.valid?(id)

  defp valid_return_url?(url) when is_binary(url) and byte_size(url) <= 2048 do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, fragment: nil}} ->
        is_binary(host) and host != "" and not String.contains?(url, ["\\", "\r", "\n", "\t"])

      _ ->
        false
    end
  end

  defp valid_return_url?(_), do: false
end

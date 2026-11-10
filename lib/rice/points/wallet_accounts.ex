defmodule Rice.Points.WalletAccounts do
  @moduledoc "Looks up and provisions owner wallets for the migrated Rice asset."

  import Ecto.Query

  alias Rice.Accounts.User
  alias Rice.Community.Node
  alias Rice.Points.Account
  alias Rice.{Repo, Tsid}

  @type owner :: String.t() | {:node, String.t()}

  @doc "Finds an existing owner wallet."
  @spec fetch(String.t(), owner()) :: {:ok, Account.t()} | {:error, :account_not_found}
  def fetch(point_id, owner) do
    {type, id} = owner_key(owner)

    case Repo.get_by(Account, point_id: point_id, owner_type: type, owner_id: id) do
      nil -> {:error, :account_not_found}
      account -> {:ok, account}
    end
  end

  @doc "Creates a zero-balance wallet for an existing eligible owner on first receipt."
  @spec ensure_recipient(String.t(), owner()) ::
          {:ok, Account.t()} | {:error, :recipient_not_found}
  def ensure_recipient(point_id, owner) do
    {type, id} = owner_key(owner)

    if is_binary(id) and Tsid.valid?(id) and eligible?(type, id) do
      Repo.insert!(%Account{point_id: point_id, owner_type: type, owner_id: id},
        on_conflict: :nothing,
        conflict_target: [:point_id, :owner_type, :owner_id]
      )

      case fetch(point_id, owner) do
        {:ok, account} -> {:ok, account}
        _ -> {:error, :recipient_not_found}
      end
    else
      {:error, :recipient_not_found}
    end
  end

  defp eligible?("user", id),
    do:
      Repo.exists?(
        from u in User, where: u.id == ^id and is_nil(u.disabled_at) and is_nil(u.deleted_at)
      )

  defp eligible?("node", id), do: Repo.exists?(from n in Node, where: n.id == ^id)

  defp owner_key({:node, id}), do: {"node", id}
  defp owner_key(id), do: {"user", id}
end

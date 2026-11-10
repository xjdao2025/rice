defmodule Rice.Points.Issuers do
  @moduledoc """
  Asset issuance administration. Bootstrap is internal and requires prior
  authorization by the issuing community's governance.
  """

  import Ecto.Changeset

  alias Rice.{Repo, Tsid}
  alias Rice.Points.{Account, Balance, IssuancePolicy, IssuanceSigner, Issuer, Point}

  @max_amount 9_223_372_036_854_775_807

  @doc "Creates a draft asset, its issuance account and its first policy atomically."
  @spec bootstrap(String.t(), String.t(), non_neg_integer() | nil, pos_integer(), [String.t()]) ::
          {:ok, Point.t()} | {:error, Ecto.Changeset.t() | :invalid_issuance_policy}
  def bootstrap(community_id, code, cap, threshold, signers) do
    if valid_policy?(cap, threshold, signers) do
      Repo.transaction(fn ->
        point = create_draft!(community_id, code, cap)

        policy =
          insert!(%IssuancePolicy{
            point_id: point.id,
            version: 1,
            threshold: threshold,
            current: true
          })

        Enum.each(signers, fn user_id ->
          %IssuanceSigner{policy_id: policy.id, user_id: user_id}
          |> change()
          |> foreign_key_constraint(:user_id)
          |> insert!()
        end)

        point
      end)
    else
      {:error, :invalid_issuance_policy}
    end
  end

  @doc "Prepares a draft for the existing Rice ledger without changing other assets' issuance policies."
  @spec prepare_legacy_rice(String.t()) :: {:ok, Point.t()} | {:error, Ecto.Changeset.t()}
  def prepare_legacy_rice(community_id) do
    Repo.transaction(fn -> create_draft!(community_id, "RICE", nil) end)
  end

  defp create_draft!(community_id, code, cap) do
    point =
      %Point{status: "draft"}
      |> cast(%{issuer_community_id: community_id, code: code}, [:issuer_community_id, :code])
      |> update_change(:code, &String.trim/1)
      |> validate_required([:issuer_community_id, :code])
      |> validate_length(:issuer_community_id, max: 255)
      |> validate_length(:code, max: 255)
      |> unique_constraint([:issuer_community_id, :code])
      |> check_constraint(:code, name: :point_asset_valid)
      |> insert!()

    account = insert!(%Account{point_id: point.id, owner_type: "system", owner_id: "issuer"})
    insert!(%Balance{account_id: account.id, owner_type: "system"})
    insert!(%Issuer{point_id: point.id, account_id: account.id, supply_cap: cap})
    point
  end

  defp valid_policy?(cap, threshold, signers)
       when is_integer(threshold) and threshold >= 2 and is_list(signers) do
    (is_nil(cap) or (is_integer(cap) and cap in 0..@max_amount)) and
      threshold <= length(signers) and length(signers) == length(Enum.uniq(signers)) and
      Enum.all?(signers, &(is_binary(&1) and Tsid.valid?(&1)))
  end

  defp valid_policy?(_, _, _), do: false

  defp insert!(value) do
    case Repo.insert(value) do
      {:ok, inserted} -> inserted
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end
end

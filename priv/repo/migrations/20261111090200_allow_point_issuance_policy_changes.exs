defmodule Rice.Repo.Migrations.AllowPointIssuancePolicyChanges do
  use Ecto.Migration

  def up do
    drop constraint(:point_issuances, :valid_point_issuance)

    create constraint(:point_issuances, :valid_point_issuance,
             check:
               "btrim(reason) <> '' AND ((kind IN ('initial_allocation', 'mint') AND total > 0) OR (kind = 'policy_change' AND total = 0))"
           )
  end

  def down do
    drop constraint(:point_issuances, :valid_point_issuance)

    create constraint(:point_issuances, :valid_point_issuance,
             check: "kind IN ('initial_allocation', 'mint') AND total > 0 AND btrim(reason) <> ''"
           )
  end
end

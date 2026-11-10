defmodule Rice.Repo.Migrations.AddPointIssuance do
  use Ecto.Migration

  def up do
    drop constraint(:points, :point_asset_valid)

    create constraint(:points, :point_asset_valid,
             check:
               "status IN ('draft', 'active', 'disabled') AND btrim(code) <> '' AND btrim(issuer_community_id) <> ''"
           )

    create table(:point_issuers, primary_key: false) do
      add :id, :string, primary_key: true
      add :point_id, references(:points, type: :string, on_delete: :restrict), null: false

      add :account_id,
          references(:point_accounts,
            type: :string,
            with: [point_id: :point_id],
            on_delete: :restrict
          ),
          null: false

      add :supply_cap, :bigint
      add :issued, :bigint, null: false, default: 0
      add :burned, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:point_issuers, [:point_id])
    create unique_index(:point_issuers, [:account_id])

    create constraint(:point_issuers, :point_issuer_supply_valid,
             check:
               "issued >= 0 AND burned BETWEEN 0 AND issued AND (supply_cap IS NULL OR (supply_cap >= 0 AND issued <= supply_cap))"
           )
  end

  def down do
    drop table(:point_issuers)
    drop constraint(:points, :point_asset_valid)

    create constraint(:points, :point_asset_valid,
             check:
               "status IN ('active', 'disabled') AND btrim(code) <> '' AND btrim(issuer_community_id) <> ''"
           )
  end
end

defmodule Rice.Repo.Migrations.RecordPointBusinessOutcomes do
  use Ecto.Migration

  def change do
    alter table(:point_transactions) do
      add :business_outcome_uri, :text
    end

    create unique_index(:point_transactions, [:point_id, :business_outcome_uri],
             where: "business_outcome_uri IS NOT NULL"
           )
  end
end

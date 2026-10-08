defmodule Rice.Repo.Migrations.AddNodeGrantRequestIndex do
  use Ecto.Migration

  def change do
    create unique_index(:grain_transfers, [:subject_uri],
             where: "kind = 'grant' AND to_node_id IS NOT NULL AND subject_uri IS NOT NULL",
             name: :grain_transfers_node_grant_request
           )
  end
end

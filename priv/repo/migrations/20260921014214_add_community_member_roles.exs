defmodule Rice.Repo.Migrations.AddCommunityMemberRoles do
  use Ecto.Migration

  def change do
    alter table(:node_memberships) do
      add :role, :string, null: false, default: "member"
    end

    create constraint(:node_memberships, :node_memberships_role,
             check: "role IN ('member', 'admin')"
           )
  end
end

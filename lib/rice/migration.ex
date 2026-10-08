defmodule Rice.Migration do
  @moduledoc """
  迁移里声明 TSID 列的小助手。

  底层是一个 Postgres domain(见 `priv/repo/migrations/*_create_tsid_domain.exs`):

      CREATE DOMAIN tsid AS varchar(13)

  用 domain 而不是每处手写 `varchar(13)`,是为了让主键和外键的类型**精确相同** ——
  Ecto 的 `references(..., type: :string)` 会生成 `varchar(255)`,宽度对不上,
  而 domain 让两边都是同一个类型,外键约束干净,宽度也不会写错。

      defmodule Rice.Repo.Migrations.CreateUsers do
        use Ecto.Migration
        import Rice.Migration

        def change do
          create table(:users, primary_key: false) do
            tsid_primary_key()
            add :avatar_id, tsid_references(:attachments)
            add :legacy_id, :string, size: 36
            timestamps(type: :utc_datetime_usec)
          end

          create unique_index(:users, [:legacy_id], where: "legacy_id is not null")
        end
      end
  """

  @doc "主键列。必须配合 `table(..., primary_key: false)` 使用。"
  defmacro tsid_primary_key(name \\ :id) do
    quote do
      add(unquote(name), :tsid, primary_key: true)
    end
  end

  @doc "指向另一张表的外键列。`opts` 透传给 `Ecto.Migration.references/2`。"
  defmacro tsid_references(table, opts \\ []) do
    quote do
      references(unquote(table), Keyword.merge([type: :tsid, column: :id], unquote(opts)))
    end
  end
end

defmodule Rice.Repo.Migrations.GuardLegacyGrainCutover do
  use Ecto.Migration

  def up do
    create table(:point_legacy_cutover, primary_key: false) do
      add :singleton, :boolean, primary_key: true, default: true
      add :point_id, references(:points, type: :string, on_delete: :restrict), null: false
    end

    create constraint(:point_legacy_cutover, :point_cutover_singleton, check: "singleton")

    execute """
    CREATE FUNCTION rice_reject_legacy_grain_write() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF EXISTS (SELECT 1 FROM point_legacy_cutover WHERE singleton) THEN
        RAISE EXCEPTION 'Legacy grain ledger is read-only after Point cutover' USING ERRCODE = '55000';
      END IF;
      RETURN NULL;
    END;
    $$
    """

    for table <- ~w(grain_transfers grain_receipts) do
      execute """
      CREATE TRIGGER rice_legacy_grain_write_guard
      BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON #{table}
      FOR EACH STATEMENT EXECUTE FUNCTION rice_reject_legacy_grain_write()
      """
    end

    for table <- ~w(users nodes) do
      execute """
      CREATE TRIGGER rice_legacy_grain_write_guard
      BEFORE UPDATE OF grain_balance, grain_frozen_balance ON #{table}
      FOR EACH STATEMENT EXECUTE FUNCTION rice_reject_legacy_grain_write()
      """
    end
  end

  def down do
    for table <- ~w(users nodes grain_transfers grain_receipts) do
      execute "DROP TRIGGER rice_legacy_grain_write_guard ON #{table}"
    end

    execute "DROP FUNCTION rice_reject_legacy_grain_write()"
    drop table(:point_legacy_cutover)
  end
end

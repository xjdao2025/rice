defmodule Rice.Repo.Migrations.EnablePaymentAppSelfService do
  use Ecto.Migration

  def up do
    alter table(:point_payment_apps) do
      add :owner_user_id, references(:users, type: :string, on_delete: :restrict)
      add :credential_ciphertext, :binary
    end

    create index(:point_payment_apps, [:owner_user_id])

    execute """
    UPDATE point_payment_apps AS app
    SET owner_user_id = u.id
    FROM point_accounts AS a JOIN users AS u ON a.owner_id = u.id
    WHERE app.payee_account_id = a.id AND a.owner_type = 'user'
    """
  end

  def down do
    drop index(:point_payment_apps, [:owner_user_id])

    alter table(:point_payment_apps) do
      remove :credential_ciphertext
      remove :owner_user_id
    end
  end
end

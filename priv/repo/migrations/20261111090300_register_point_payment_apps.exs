defmodule Rice.Repo.Migrations.RegisterPointPaymentApps do
  use Ecto.Migration

  def change do
    create table(:point_payment_apps, primary_key: false) do
      add :id, :string, primary_key: true
      add :name, :string, null: false
      add :credential_digest, :binary, null: false
      add :point_id, :string, null: false

      add :payee_account_id,
          references(:point_accounts,
            type: :string,
            with: [point_id: :point_id],
            on_delete: :restrict
          ),
          null: false

      add :return_url, :text, null: false
      add :active, :boolean, null: false, default: true
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:point_payment_apps, [:credential_digest])

    create constraint(:point_payment_apps, :payment_app_registration_valid,
             check:
               "btrim(name) <> '' AND octet_length(credential_digest) = 32 AND return_url LIKE 'https://%'"
           )

    alter table(:point_payment_intents) do
      modify :app_id, references(:point_payment_apps, type: :string, on_delete: :restrict),
        from: :string,
        null: false

      add :app_name, :string, null: false
      add :return_url, :text, null: false
    end
  end
end

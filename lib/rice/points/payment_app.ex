defmodule Rice.Points.PaymentApp do
  use Rice.Schema

  schema "point_payment_apps" do
    field :name, :string
    belongs_to :owner_user, Rice.Accounts.User
    field :credential_ciphertext, :binary, redact: true
    field :credential_digest, :binary, redact: true
    belongs_to :point, Rice.Points.Point
    belongs_to :payee_account, Rice.Points.Account
    field :return_url, :string
    field :active, :boolean, default: true
    timestamps()
  end
end

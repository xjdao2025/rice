defmodule Rice.Points.PaymentIntent do
  use Rice.Schema

  schema "point_payment_intents" do
    belongs_to :app, Rice.Points.PaymentApp
    field :app_name, :string
    field :return_url, :string
    field :external_order_id, :string
    belongs_to :point, Rice.Points.Point
    belongs_to :payee_account, Rice.Points.Account
    field :amount, :integer
    field :status, :string, default: "pending"
    field :expires_at, :utc_datetime_usec
    belongs_to :transaction, Rice.Points.Transaction
    timestamps()
  end
end

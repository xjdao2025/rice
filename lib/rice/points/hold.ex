defmodule Rice.Points.Hold do
  use Rice.Schema

  schema "point_holds" do
    belongs_to :point, Rice.Points.Point
    belongs_to :payer_account, Rice.Points.Account
    belongs_to :reservation_transaction, Rice.Points.Transaction
    field :original_amount, :integer
    field :remaining_amount, :integer
    field :status, :string, default: "active"
    field :expires_at, :utc_datetime_usec
    timestamps()
  end
end

defmodule Rice.Repo.Migrations.AllowEventApplicationWithdrawal do
  use Ecto.Migration

  def up do
    drop constraint(:event_applications, :event_applications_status)
    drop constraint(:event_applications, :event_applications_payment)

    create constraint(:event_applications, :event_applications_status,
             check:
               "status in ('pending','approved','rejected','removed','withdrawn','not_selected','cancelled')"
           )

    create constraint(:event_applications, :event_applications_payment,
             check:
               "(fee_amount = 0 and payment_status = 'none') or " <>
                 "(fee_amount > 0 and payment_status = 'reserved' and status in ('pending','approved')) or " <>
                 "(fee_amount > 0 and payment_status = 'refunded' and status in ('rejected','removed','withdrawn','not_selected','cancelled')) or " <>
                 "(fee_amount > 0 and payment_status = 'settled' and status = 'approved')"
           )
  end

  def down do
    drop constraint(:event_applications, :event_applications_status)
    drop constraint(:event_applications, :event_applications_payment)

    create constraint(:event_applications, :event_applications_status,
             check:
               "status in ('pending','approved','rejected','removed','not_selected','cancelled')"
           )

    create constraint(:event_applications, :event_applications_payment,
             check:
               "(fee_amount = 0 and payment_status = 'none') or " <>
                 "(fee_amount > 0 and payment_status = 'reserved' and status in ('pending','approved')) or " <>
                 "(fee_amount > 0 and payment_status = 'refunded' and status in ('rejected','removed','not_selected','cancelled')) or " <>
                 "(fee_amount > 0 and payment_status = 'settled' and status = 'approved')"
           )
  end
end

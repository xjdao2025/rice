defmodule Rice.Repo.Migrations.AddFeedAndListQueryIndexes do
  use Ecto.Migration

  # Build without blocking business writes. Run only one migrator at a time;
  # concurrent index creation cannot run inside a DDL transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:grain_receipts, [:from_user_id, :id], concurrently: true)

    create index(:verification_codes, [:channel, "lower(target)", :inserted_at],
             name: :verification_codes_channel_lower_target_inserted_at_index,
             concurrently: true
           )

    # The previous full event/round/user index became partial when reapplication
    # was introduced; list counts must include rejected and withdrawn records too.
    create index(:event_applications, [:event_id, :round, :user_id, :id], concurrently: true)

    create index(:task_submissions, [:task_id, :round],
             name: :task_submissions_pending_review_index,
             where: "review_reason IS NULL AND final_status IS NULL",
             concurrently: true
           )
  end
end

defmodule Rice.Repo.Migrations.AddBusinessSchema do
  @moduledoc """
  任务、活动、社区成员、社区稻米账户与回执 —— 一次建到最终形态。

  这是开发期 20 个增量迁移（20260901145837 … 20260929133300）合并的结果：
  中间那些「先建约束、再 DROP 重建」「先 4 张图、再放宽到 9 张」「先建唯一索引、
  再换成带 round 的」的来回都已折叠掉。对一个停在 20260811120000 的库，
  跑完本迁移得到的结构与逐个跑完那 20 个迁移**完全一致**（用 pg_dump -s 逐项
  对比过：列、类型、默认值、约束、索引、外键）。

  回填语句（task_events 起始记录、reserved 回执、event_applications 的
  settlement_node_id）一并省掉：它们只作用于这些迁移自己新建的表，而新建的表
  必然是空的。

  ⚠️ 已经跑过旧的 20 个迁移中任何一个的库（本机开发库、demo 环境）不能直接
  接上本迁移 —— `schema_migrations` 里留着旧版本号，而表已经存在，本迁移会因
  「relation already exists」失败。这类库要重建，或先删掉这 20 个版本号对应的
  对象与记录。
  """
  use Ecto.Migration
  import Rice.Migration

  def up do
    # ── 已有表的改动 ────────────────────────────────────────────────

    alter table(:users) do
      add :can_publish_tasks, :boolean, null: false, default: false
      add :grain_frozen_balance, :bigint, null: false, default: 0
    end

    create constraint(:users, :users_grain_frozen_balance_non_negative,
             check: "grain_frozen_balance >= 0"
           )

    alter table(:nodes) do
      add :grain_balance, :bigint, null: false, default: 0
      add :grain_frozen_balance, :bigint, null: false, default: 0
    end

    create constraint(:nodes, :nodes_grain_non_negative,
             check: "grain_balance >= 0 AND grain_frozen_balance >= 0"
           )

    alter table(:attachments) do
      add :user_id, tsid_references(:users, on_delete: :nilify_all)
    end

    create index(:attachments, [:user_id])

    # ── 任务 ────────────────────────────────────────────────────────

    create table(:tasks, primary_key: false) do
      tsid_primary_key()
      add :creator_id, tsid_references(:users), null: false
      add :assignee_id, tsid_references(:users, on_delete: :nilify_all)
      add :title, :string, size: 128, null: false
      add :description, :text, null: false
      add :status, :string, size: 24, null: false, default: "open"
      timestamps(type: :utc_datetime_usec)
      add :application_deadline, :utc_datetime_usec
      add :appointed_at, :utc_datetime_usec
      add :appointment_reason, :string, size: 512
      add :reward_amount, :bigint, null: false, default: 0
      add :reward_status, :string, size: 16, null: false, default: "none"
      add :node_id, tsid_references(:nodes)
      add :requirement, :text, null: false, default: ""
      add :execution_deadline, :utc_datetime_usec
      add :client_request_id, :string, size: 128
      add :organizer_contact, :string, size: 256
      add :funding_node_id, tsid_references(:nodes)
      add :reward_subject_uri, :string
      add :round, :integer, null: false, default: 1
    end

    create index(:tasks, [:status, :id])
    create index(:tasks, [:creator_id, :id])
    create index(:tasks, [:assignee_id, :id])
    create index(:tasks, [:node_id, :id])

    create unique_index(:tasks, [:creator_id, :client_request_id],
             where: "client_request_id IS NOT NULL"
           )

    create unique_index(:tasks, [:creator_id],
             where: "status = 'draft'",
             name: :tasks_one_draft_per_creator
           )

    create constraint(:tasks, :tasks_status,
             check:
               "status in ('draft', 'open', 'in_progress', 'overdue', 'under_review', 'completed', 'expired', 'cancelled')"
           )

    create constraint(:tasks, :tasks_assignee_matches_status,
             check:
               "(status in ('draft', 'open', 'expired', 'cancelled') and assignee_id is null and appointed_at is null) or " <>
                 "(status in ('in_progress', 'overdue', 'under_review', 'completed') and assignee_id is not null and appointed_at is not null)"
           )

    create constraint(:tasks, :tasks_reward_amount_non_negative, check: "reward_amount >= 0")

    create constraint(:tasks, :tasks_reward_status,
             check: "reward_status in ('none', 'reserved', 'settled', 'refunded')"
           )

    create constraint(:tasks, :tasks_reward_matches_status,
             check:
               "(reward_status = 'none' and (reward_amount = 0 or status in ('draft', 'completed', 'expired', 'cancelled'))) or " <>
                 "(reward_status = 'reserved' and reward_amount > 0 and status in ('open', 'in_progress', 'overdue', 'under_review')) or " <>
                 "(reward_status = 'settled' and status = 'completed') or " <>
                 "(reward_status = 'refunded' and status in ('expired', 'cancelled'))"
           )

    create constraint(:tasks, :tasks_round_positive, check: "round > 0")

    create table(:task_applications, primary_key: false) do
      tsid_primary_key()
      add :task_id, tsid_references(:tasks, on_delete: :delete_all), null: false
      add :user_id, tsid_references(:users), null: false
      add :reason, :string, size: 512, null: false, default: ""
      timestamps(type: :utc_datetime_usec)
      add :rejected_at, :utc_datetime_usec
      add :contact, :string, size: 256
      add :round, :integer, null: false, default: 1
      add :final_status, :string
    end

    create unique_index(:task_applications, [:task_id, :round, :user_id])
    create constraint(:task_applications, :task_applications_round_positive, check: "round > 0")

    create table(:task_submissions, primary_key: false) do
      tsid_primary_key()
      add :task_id, tsid_references(:tasks, on_delete: :delete_all), null: false
      add :user_id, tsid_references(:users), null: false
      add :body, :text, null: false
      add :review_reason, :string, size: 512
      timestamps(type: :utc_datetime_usec)
      add :round, :integer, null: false, default: 1
      add :final_status, :string
    end

    create index(:task_submissions, [:task_id, :id])

    create constraint(:task_submissions, :task_submissions_review_reason,
             check: "review_reason is null or length(btrim(review_reason)) > 0"
           )

    create constraint(:task_submissions, :task_submissions_round_positive, check: "round > 0")

    # event 上没有 CHECK：旧迁移里这条约束被 DROP 后再也没重建，保持最终状态。
    create table(:task_notifications, primary_key: false) do
      tsid_primary_key()
      add :task_id, tsid_references(:tasks, on_delete: :delete_all)
      add :recipient_id, tsid_references(:users, on_delete: :delete_all), null: false
      add :actor_id, tsid_references(:users), null: false
      add :event, :string, size: 32, null: false
      add :detail, :string, size: 512
      add :read_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
      add :subject_type, :string
      add :subject_id, :string
    end

    create index(:task_notifications, [:recipient_id, :id])

    create table(:task_events, primary_key: false) do
      tsid_primary_key()
      add :task_id, tsid_references(:tasks, on_delete: :delete_all), null: false
      add :actor_id, tsid_references(:users, on_delete: :nilify_all)
      add :from_status, :string, size: 24
      add :to_status, :string, size: 24, null: false
      add :detail, :string, size: 512
      timestamps(type: :utc_datetime_usec, updated_at: false)
      add :before, :map
      add :after, :map
    end

    create index(:task_events, [:task_id, :id])

    create constraint(:task_events, :task_events_statuses,
             check:
               "(from_status is null or from_status in ('draft', 'open', 'in_progress', 'overdue', 'under_review', 'completed', 'expired', 'cancelled')) and " <>
                 "to_status in ('draft', 'open', 'in_progress', 'overdue', 'under_review', 'completed', 'expired', 'cancelled')"
           )

    create table(:task_images, primary_key: false) do
      tsid_primary_key()
      add :task_id, tsid_references(:tasks, on_delete: :delete_all), null: false
      add :attachment_id, tsid_references(:attachments), null: false
      add :position, :integer, null: false
    end

    create unique_index(:task_images, [:task_id, :attachment_id])
    create constraint(:task_images, :task_image_position, check: "position >= 0 AND position < 9")

    # ── 活动 ────────────────────────────────────────────────────────

    create table(:events, primary_key: false) do
      tsid_primary_key()
      add :creator_id, tsid_references(:users), null: false
      add :node_id, tsid_references(:nodes), null: false
      add :title, :string, size: 128, null: false
      add :description, :text, null: false
      add :location, :string, size: 256, null: false
      add :status, :string, size: 24, null: false, default: "draft"
      add :fee_amount, :bigint, null: false, default: 0
      add :capacity, :integer, null: false
      add :application_deadline, :utc_datetime_usec, null: false
      add :starts_at, :utc_datetime_usec, null: false
      add :ends_at, :utc_datetime_usec, null: false
      add :published_at, :utc_datetime_usec
      add :client_request_id, :string, size: 128
      timestamps(type: :utc_datetime_usec)
      add :organizer_contact, :string, size: 256
      add :settlement_node_id, tsid_references(:nodes)
      add :round, :integer, null: false, default: 1
    end

    create index(:events, [:node_id, :id])
    create index(:events, [:creator_id, :id])
    create index(:events, [:status, :starts_at])
    create unique_index(:events, [:creator_id, :client_request_id])

    create unique_index(:events, [:creator_id],
             name: :events_one_draft_per_creator,
             where: "status = 'draft'"
           )

    create constraint(:events, :events_status,
             check: "status in ('draft','open','in_progress','completed','cancelled')"
           )

    create constraint(:events, :events_fee_capacity, check: "fee_amount >= 0 and capacity > 0")

    create constraint(:events, :events_times,
             check: "application_deadline <= starts_at and starts_at < ends_at"
           )

    create constraint(:events, :events_round_positive, check: "round > 0")

    create table(:event_applications, primary_key: false) do
      tsid_primary_key()
      add :event_id, tsid_references(:events), null: false
      add :user_id, tsid_references(:users), null: false
      add :reason, :string, size: 512, null: false, default: ""
      add :status, :string, size: 24, null: false, default: "pending"
      add :payment_status, :string, size: 16, null: false, default: "none"
      add :fee_amount, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
      add :contact, :string, size: 256
      add :settlement_node_id, tsid_references(:nodes)
      add :round, :integer, null: false, default: 1
    end

    create unique_index(:event_applications, [:event_id, :round, :user_id])
    create index(:event_applications, [:user_id, :id])

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

    create constraint(:event_applications, :event_applications_round_positive,
             check: "round > 0"
           )

    create table(:event_history, primary_key: false) do
      tsid_primary_key()
      add :event_id, tsid_references(:events), null: false
      add :application_id, tsid_references(:event_applications)
      add :actor_id, tsid_references(:users)
      add :action, :string, size: 40, null: false
      add :from_status, :string, size: 24
      add :to_status, :string, size: 24, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
      add :before, :map
      add :after, :map
      add :round, :integer, null: false, default: 1
    end

    create index(:event_history, [:event_id, :id])

    create table(:event_images, primary_key: false) do
      tsid_primary_key()
      add :event_id, tsid_references(:events, on_delete: :delete_all), null: false
      add :attachment_id, tsid_references(:attachments), null: false
      add :position, :integer, null: false
    end

    create unique_index(:event_images, [:event_id, :attachment_id])

    create constraint(:event_images, :event_image_position,
             check: "position >= 0 AND position < 9"
           )

    # ── 社区成员 ────────────────────────────────────────────────────

    create table(:node_memberships, primary_key: false) do
      tsid_primary_key()
      add :node_id, tsid_references(:nodes), null: false
      add :user_id, tsid_references(:users), null: false
      timestamps(type: :utc_datetime_usec)
      add :role, :string, null: false, default: "member"
    end

    create unique_index(:node_memberships, [:node_id, :user_id])
    create index(:node_memberships, [:user_id])

    create constraint(:node_memberships, :node_memberships_role,
             check: "role IN ('member', 'admin')"
           )

    create table(:node_join_applications, primary_key: false) do
      tsid_primary_key()
      add :node_id, tsid_references(:nodes), null: false
      add :user_id, tsid_references(:users), null: false
      add :reason, :text, null: false, default: ""
      add :status, :string, null: false, default: "pending"
      add :review_reason, :text
      add :reviewer_id, tsid_references(:users)
      add :reviewed_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:node_join_applications, [:node_id, :user_id],
             name: :node_join_applications_one_pending,
             where: "status = 'pending'"
           )

    create index(:node_join_applications, [:user_id, :id])

    create constraint(:node_join_applications, :node_join_application_status,
             check: "status IN ('pending', 'approved', 'rejected')"
           )

    # ── 稻米：社区账户与回执 ────────────────────────────────────────

    alter table(:grain_transfers) do
      add :from_node_id, tsid_references(:nodes)
      add :to_node_id, tsid_references(:nodes)
    end

    execute "ALTER TABLE grain_transfers ALTER COLUMN to_user_id DROP NOT NULL"

    create index(:grain_transfers, [:from_node_id, :id])
    create index(:grain_transfers, [:to_node_id, :id])

    drop constraint(:grain_transfers, :grain_transfers_kind)
    drop constraint(:grain_transfers, :grain_transfers_from_matches_kind)

    create constraint(:grain_transfers, :grain_transfers_kind,
             check:
               "kind IN ('reward', 'gift', 'grant', 'task_reward', 'event_fee', 'community_fund')"
           )

    create constraint(:grain_transfers, :grain_transfers_from_matches_kind,
             check:
               "(kind = 'grant' AND num_nonnulls(from_user_id, from_node_id) = 0) OR (kind <> 'grant' AND num_nonnulls(from_user_id, from_node_id) = 1)"
           )

    create constraint(:grain_transfers, :grain_transfers_to_account,
             check: "num_nonnulls(to_user_id, to_node_id) = 1"
           )

    create unique_index(:grain_transfers, [:from_user_id, :subject_uri],
             where: "kind = 'community_fund'",
             name: :grain_transfers_community_fund_request
           )

    create table(:grain_receipts, primary_key: false) do
      tsid_primary_key()
      add :kind, :string, null: false
      add :subject_uri, :string, size: 512, null: false
      add :amount, :bigint, null: false
      add :from_user_id, tsid_references(:users)
      add :to_user_id, tsid_references(:users)
      add :transfer_id, tsid_references(:grain_transfers)
      timestamps(type: :utc_datetime_usec, updated_at: false)
      add :from_node_id, tsid_references(:nodes)
      add :to_node_id, tsid_references(:nodes)
    end

    create unique_index(:grain_receipts, [:subject_uri, :kind])

    create unique_index(:grain_receipts, [:subject_uri],
             where: "kind IN ('refunded', 'settled')",
             name: :grain_receipts_one_outcome
           )

    create index(:grain_receipts, [:from_node_id, :id])
    create index(:grain_receipts, [:to_node_id, :id])

    create constraint(:grain_receipts, :grain_receipts_kind,
             check: "kind IN ('reserved', 'refunded', 'settled')"
           )

    create constraint(:grain_receipts, :grain_receipts_amount, check: "amount > 0")

    create constraint(:grain_receipts, :grain_receipts_from_account,
             check: "num_nonnulls(from_user_id, from_node_id) = 1"
           )

    create constraint(:grain_receipts, :grain_receipts_to_account,
             check:
               "(kind = 'settled' AND num_nonnulls(to_user_id, to_node_id) = 1) OR (kind <> 'settled' AND num_nonnulls(to_user_id, to_node_id) = 0)"
           )
  end

  def down do
    raise "Business records and Grain ledgers must be retained; restore the database backup to roll back"
  end
end

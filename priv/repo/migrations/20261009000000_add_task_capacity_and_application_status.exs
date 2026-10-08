defmodule Rice.Repo.Migrations.AddTaskCapacityAndApplicationStatus do
  @moduledoc """
  合并了五份迁移的最终状态:
    * 节点发放的幂等唯一索引;转账 / 打赏的重试标识(request_id)
    * 任务领取人数(capacity)与每个申请的奖励名额(reward_slot)
    * task_applications.status —— 申请自己的状态机(见 Rice.Tasks.ApplicationState)
  """
  use Ecto.Migration

  @max_capacity 1_000

  def up do
    # ── 稻米流转 ──────────────────────────────────────────────────────────
    create unique_index(:grain_transfers, [:subject_uri],
             where: "kind = 'grant' AND to_node_id IS NOT NULL AND subject_uri IS NOT NULL",
             name: :grain_transfers_node_grant_request
           )

    # 网络超时后带同一个 request_id 重试,同一付款人只记一笔
    alter table(:grain_transfers) do
      add :request_id, :string, size: 128
    end

    create unique_index(:grain_transfers, [:from_user_id, :request_id],
             where: "request_id IS NOT NULL",
             name: :grain_transfers_request_id
           )

    # ── 多人承接 ──────────────────────────────────────────────────────────
    alter table(:tasks) do
      add :capacity, :integer, null: false, default: 1
    end

    alter table(:task_applications) do
      add :appointed_at, :utc_datetime_usec
      add :appointment_reason, :string, size: 512
      add :reward_slot, :integer
      add :status, :string, null: false, default: "pending"
    end

    create constraint(:tasks, :tasks_capacity_range,
             check: "capacity BETWEEN 1 AND #{@max_capacity}"
           )

    create constraint(:task_applications, :task_applications_reward_slot_positive,
             check: "reward_slot IS NULL OR reward_slot BETWEEN 1 AND #{@max_capacity}"
           )

    create unique_index(:task_applications, [:task_id, :round, :reward_slot],
             where: "reward_slot IS NOT NULL"
           )

    drop constraint(:tasks, :tasks_assignee_matches_status)

    create constraint(:tasks, :tasks_assignee_matches_status,
             check:
               "(capacity > 1 AND assignee_id IS NULL AND appointed_at IS NULL) OR " <>
                 "(capacity = 1 AND ((status IN ('draft', 'open', 'expired', 'cancelled') AND assignee_id IS NULL AND appointed_at IS NULL) OR " <>
                 "(status IN ('in_progress', 'overdue', 'under_review', 'completed') AND assignee_id IS NOT NULL AND appointed_at IS NOT NULL)))"
           )

    # ── 申请状态机 ────────────────────────────────────────────────────────
    # 回填:被指派的申请(归档轮次里 final_status = appointed,或当前轮次里就是 assignee)。
    # 只认当前轮次的 assignee:任务重开后同一个人再申请、再被指派,旧轮次那行仍是落选。
    execute """
    UPDATE task_applications a
       SET appointed_at = COALESCE(a.appointed_at, t.appointed_at, a.updated_at)
      FROM tasks t
     WHERE t.id = a.task_id
       AND a.appointed_at IS NULL
       AND ((a.round = t.round AND a.user_id = t.assignee_id) OR a.final_status = 'appointed')
    """

    execute """
    UPDATE task_applications a
       SET status = CASE
         -- 已归档的旧轮次:沿用当时的结果
         WHEN a.final_status IS NOT NULL AND a.round < t.round THEN
           CASE a.final_status
             WHEN 'appointed' THEN 'completed'
             WHEN 'cancelled' THEN 'cancelled'
             WHEN 'expired' THEN 'expired'
             ELSE 'not_selected'
           END
         WHEN a.appointed_at IS NOT NULL THEN
           CASE
             WHEN t.capacity = 1 THEN
               CASE t.status
                 WHEN 'completed' THEN 'completed'
                 WHEN 'under_review' THEN 'under_review'
                 WHEN 'overdue' THEN 'overdue'
                 ELSE 'appointed'
               END
             ELSE COALESCE(
               (SELECT CASE
                         WHEN s.final_status = 'approved' THEN 'completed'
                         WHEN s.review_reason IS NULL AND s.final_status IS NULL THEN 'under_review'
                         WHEN t.execution_deadline IS NOT NULL
                              AND t.execution_deadline <= now() AT TIME ZONE 'utc' THEN 'overdue'
                         ELSE 'appointed'
                       END
                  FROM task_submissions s
                 WHERE s.task_id = a.task_id AND s.round = a.round AND s.user_id = a.user_id
                 ORDER BY s.id DESC LIMIT 1),
               CASE WHEN t.execution_deadline IS NOT NULL
                         AND t.execution_deadline <= now() AT TIME ZONE 'utc'
                    THEN 'overdue' ELSE 'appointed' END)
           END
         WHEN a.rejected_at IS NOT NULL THEN 'rejected'
         WHEN t.status = 'cancelled' THEN 'cancelled'
         WHEN t.status = 'expired' THEN 'expired'
         WHEN t.status = 'open' THEN 'pending'
         ELSE 'not_selected'
       END
      FROM tasks t
     WHERE t.id = a.task_id
    """

    # 单人任务就是只有一个名额的多人任务,也按名额编号算账:已指派的那一个占 1 号。
    # 每个轮次最多一条,唯一索引不会冲突。
    execute """
    UPDATE task_applications a SET reward_slot = 1
      FROM tasks t
     WHERE t.id = a.task_id AND t.capacity = 1 AND a.reward_slot IS NULL
       AND a.status IN ('appointed', 'overdue', 'under_review', 'completed')
    """

    create constraint(:task_applications, :task_applications_status,
             check:
               "status IN ('pending', 'appointed', 'overdue', 'under_review', 'completed', " <>
                 "'released', 'rejected', 'not_selected', 'cancelled', 'expired')"
           )

    create constraint(:task_applications, :task_applications_status_fields,
             check:
               "(status IN ('appointed', 'overdue', 'under_review', 'completed', 'released') " <>
                 "AND appointed_at IS NOT NULL) OR " <>
                 "(status = 'rejected' AND rejected_at IS NOT NULL AND appointed_at IS NULL) OR " <>
                 "(status IN ('pending', 'not_selected', 'cancelled', 'expired') " <>
                 "AND appointed_at IS NULL)"
           )

    create index(:task_applications, [:task_id, :round, :status])
  end

  def down do
    raise "Task participant assignments, application states and Grain settlement evidence must be retained"
  end
end

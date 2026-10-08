defmodule Rice.Repo.Migrations.BackfillSingleTaskRewardSlot do
  @moduledoc """
  单人任务并进多人任务的代码路径之后,单人任务也按名额编号算账。合并前指派的
  单人申请没记编号,它占的就是 1 号。每个轮次最多一条,唯一索引不会冲突。
  """
  use Ecto.Migration

  def up do
    execute """
    UPDATE task_applications a SET reward_slot = 1
    FROM tasks t
    WHERE a.task_id = t.id AND t.capacity = 1 AND a.reward_slot IS NULL
      AND a.status IN ('appointed', 'overdue', 'under_review', 'completed')
    """
  end

  def down, do: :ok
end

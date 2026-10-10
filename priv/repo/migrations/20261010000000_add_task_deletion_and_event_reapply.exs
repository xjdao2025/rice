defmodule Rice.Repo.Migrations.AddTaskDeletionAndEventReapply do
  @moduledoc """
    * 任务软删除(deleted_at):删掉的任务列表和详情都不再出现,账本与事件保留
    * 活动申请被拒绝 / 撤销后可以重新报名:同一期每人只限一份「有效」申请
    * 节点发放稻米的重试标识:同一节点的同一个 request_id 只记一笔
  """
  use Ecto.Migration

  def change do
    alter table(:tasks) do
      add :deleted_at, :utc_datetime_usec
    end

    drop unique_index(:event_applications, [:event_id, :round, :user_id])

    create unique_index(:event_applications, [:event_id, :round, :user_id],
             where: "status NOT IN ('rejected', 'withdrawn')"
           )

    create unique_index(:grain_transfers, [:from_node_id, :request_id],
             where: "request_id IS NOT NULL AND from_node_id IS NOT NULL",
             name: :grain_transfers_node_request_id
           )
  end
end

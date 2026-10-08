defmodule Rice.Tasks.ApplicationState do
  @moduledoc """
  任务申请(`task_applications.status`)的状态机,与任务状态(`tasks.status`)一一对应:

      pending ──指派──▶ appointed ──提交──▶ under_review ──通过──▶ completed
         │                 │  ▲                 │
         │                 │  └───要求修改──────┘
         │                 └─超期─▶ overdue ──提交──▶ under_review
         ├──拒绝──▶ rejected
         ├──名额满 / 申请截止──▶ not_selected  (申请再次开放时可回到 pending)
         └──任务取消 / 过期──▶ cancelled / expired

  单人任务:任务状态就是被指派那一个申请的状态,
  `open`↔`pending`、`in_progress`↔`appointed`、`overdue`、`under_review`、`completed` 同名。
  多人任务:任务状态是所有被指派申请状态的汇总(见 `Rice.Tasks.aggregate_status/3`)。

  所有改状态的地方必须经过 `Rice.Tasks.move_applications/4`,它只放行下表里的迁移。
  """

  @states ~w(pending appointed overdue under_review completed rejected not_selected cancelled expired)

  # 被指派之后的状态:必须有 appointed_at
  @appointed ~w(appointed overdue under_review completed)

  @transitions %{
    "pending" => ~w(appointed rejected not_selected cancelled expired),
    "appointed" => ~w(overdue under_review),
    "overdue" => ~w(appointed under_review),
    "under_review" => ~w(appointed overdue completed),
    "not_selected" => ~w(pending),
    "completed" => [],
    "rejected" => [],
    "cancelled" => [],
    "expired" => []
  }

  def states, do: @states
  def appointed_states, do: @appointed
  def transitions, do: @transitions

  @doc "能迁移到 `to` 的来源状态。"
  def sources(to) do
    for {from, tos} <- @transitions, to in tos, do: from
  end

  def can?(from, to), do: to in Map.get(@transitions, from, [])

  def appointed?(status), do: status in @appointed

  @doc "接口里给老前端看的粗粒度状态:被指派之后的都叫 appointed,rejected 叫 not_selected。"
  def legacy("rejected"), do: "not_selected"
  def legacy(status) when status in @appointed, do: "appointed"
  def legacy(status), do: status
end

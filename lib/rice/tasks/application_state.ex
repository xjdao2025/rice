defmodule Rice.Tasks.ApplicationState do
  @moduledoc """
  任务申请(`task_applications.status`)的状态机。状态图、它和任务状态的关系
  (任务状态是所有占名额申请的汇总)见 docs/tasks.md。

  所有改状态的地方必须经过 `Rice.Tasks.move_applications/4`,它只放行 `transitions/0` 里列出的迁移。
  """

  @states ~w(pending appointed overdue under_review completed released rejected not_selected cancelled expired)

  # 仍占着名额的被指派状态
  @appointed ~w(appointed overdue under_review completed)

  @transitions %{
    "pending" => ~w(appointed rejected not_selected cancelled expired),
    "appointed" => ~w(overdue under_review released),
    "overdue" => ~w(appointed under_review released),
    "under_review" => ~w(appointed overdue completed),
    "not_selected" => ~w(pending),
    "completed" => [],
    "released" => [],
    "rejected" => [],
    "cancelled" => [],
    "expired" => []
  }

  @spec states() :: [String.t()]
  def states, do: @states
  @spec appointed_states() :: [String.t()]
  def appointed_states, do: @appointed
  @spec transitions() :: %{String.t() => [String.t()]}
  def transitions, do: @transitions

  @doc "能迁移到 `to` 的来源状态。"
  @spec sources(String.t()) :: [String.t()]
  def sources(to) do
    for {from, tos} <- @transitions, to in tos, do: from
  end

  @doc "是否还占着一个名额。"
  @spec appointed?(String.t()) :: boolean()
  def appointed?(status), do: status in @appointed

  @doc "接口里给老前端看的粗粒度状态:占着名额的都叫 appointed,rejected 叫 not_selected。"
  @spec legacy(String.t()) :: String.t()
  def legacy("rejected"), do: "not_selected"
  def legacy(status) when status in @appointed, do: "appointed"
  def legacy(status), do: status
end

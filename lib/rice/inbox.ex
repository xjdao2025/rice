defmodule Rice.Inbox do
  @moduledoc "Task, activity and membership messages share the existing private inbox."
  import Ecto.Query
  alias Rice.{Pagination, Repo, Tasks.Notification}

  def notify(repo, recipient_id, actor_id, event, detail, type, id) do
    %Notification{}
    |> Notification.create_changeset(%{
      recipient_id: recipient_id,
      actor_id: actor_id,
      event: event,
      detail: detail,
      subject_type: type,
      subject_id: id
    })
    |> repo.insert()
  end

  def list(user), do: list_page(user, %{}).notifications

  def list_page(user, params) do
    %{limit: limit, before: before} =
      params
      |> Map.take(["limit", "before"])
      |> Map.put_new("limit", 100)
      |> Pagination.params()

    query = from n in Notification, where: n.recipient_id == ^user.id
    query = if before, do: from(n in query, where: n.id < ^before), else: query

    {page, more} =
      Repo.all(
        from n in query,
          left_join: event in Rice.Events.Event,
          on: n.subject_type == "event" and n.subject_id == event.id,
          order_by: [desc: n.id],
          limit: ^(limit + 1),
          select: {n, event},
          preload: [actor: :avatar, task: []]
      )
      |> Enum.split(limit)

    %{
      notifications: Enum.map(page, fn {n, event} -> format_notification(n, event) end),
      cursor: if(more == [], do: nil, else: elem(List.last(page), 0).id)
    }
  end

  defp format_notification(n, event) do
    type = n.subject_type || "task"
    subject = event || n.task
    title = if subject, do: subject.title
    detail = notification_detail(n, event)

    %{
      uri: "business-notification:#{n.id}",
      reason: "task-#{n.event}",
      record: %{text: Enum.join(Enum.reject([title, detail], &is_nil/1), " · ")},
      isRead: not is_nil(n.read_at),
      indexedAt: n.inserted_at,
      author: %{handle: n.actor.handle, displayName: n.actor.nickname},
      taskId: n.task_id,
      subjectType: type,
      subjectId: n.subject_id || n.task_id
    }
  end

  # Published fees are immutable, so existing notifications can gain context without rewriting them.
  defp notification_detail(%{event: action, detail: detail}, %{fee_amount: amount})
       when amount > 0 and
              action in ~w(event_application_rejected event_application_removed event_application_withdrawn event_application_not_selected event_application_cancelled) do
    String.replace(detail || "报名费已退回", "报名费已退回", "报名费 #{amount} 稻米已退回")
  end

  defp notification_detail(%{event: "event_completed", detail: detail}, %{fee_amount: amount})
       when amount > 0,
       do: (detail || "活动已结束") <> "，报名费 #{amount} 稻米已结算"

  defp notification_detail(
         %{
           event: "task_cancelled",
           detail: nil,
           task: %{reward_status: "refunded", reward_amount: amount} = task
         },
         _event
       )
       when amount > 0,
       do: "已向#{if(task.funding_node_id, do: "社区", else: "发布者")}退回 #{amount} 稻米"

  defp notification_detail(notification, _event), do: notification.detail

  def mark_read(user), do: Rice.Tasks.mark_notifications_read(user)
end

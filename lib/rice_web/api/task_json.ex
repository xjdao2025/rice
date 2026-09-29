defmodule RiceWeb.Api.TaskJSON do
  @moduledoc "Task V1 的 JSON 表示。"
  alias Rice.Accounts.User
  alias Rice.Tasks.{Application, Event, Submission}
  alias RiceWeb.Api.UserJSON

  def index(%{page: page} = assigns) do
    %{
      data: Enum.map(page.entries, &data(&1, assigns[:current_user], false)),
      meta: Rice.Pagination.meta(page)
    }
  end

  def show(%{task: task} = assigns),
    do: %{data: data(task, assigns[:current_user], true)}

  def notifications(%{notifications: notifications}),
    do: %{notifications: Enum.map(notifications, &notification/1)}

  defp notification(item) do
    %{
      uri: "task-notification:#{item.id}",
      reason: "task-#{item.event}",
      record: %{text: Enum.join(Enum.reject([item.task.title, item.detail], &is_nil/1), " · ")},
      isRead: not is_nil(item.read_at),
      indexedAt: item.inserted_at,
      author: %{handle: item.actor.handle, displayName: item.actor.nickname},
      taskId: item.task.id
    }
  end

  defp data(task, current_user, detail?) do
    all_applications = loaded(task.applications)
    applications = Enum.filter(all_applications, &(&1.round == task.round))
    past_applications = Enum.reject(all_applications, &(&1.round == task.round))
    all_submissions = loaded(task.submissions)
    submissions = Enum.filter(all_submissions, &(&1.round == task.round))
    past_submissions = Enum.reject(all_submissions, &(&1.round == task.round))
    events = loaded(task.events)

    %{
      id: task.id,
      round: task.round,
      title: task.title,
      description: task.description,
      organizer_contact: task.organizer_contact,
      funding_node_id: task.funding_node_id,
      can_manage: Rice.Tasks.can_manage?(task, current_user),
      attachments:
        Enum.map(loaded(task.image_links), &RiceWeb.Api.AttachmentJSON.embed(&1.attachment)),
      requirement: task.requirement,
      node: RiceWeb.Api.NodeJSON.embed(task.node),
      execution_deadline: task.execution_deadline,
      application_closed: past?(task.application_deadline),
      overdue: task.status == "overdue",
      status: task.status,
      creator: public_user(task.creator),
      assignee: public_user(task.assignee),
      application_deadline: task.application_deadline,
      appointed_at: task.appointed_at,
      appointment_reason:
        if(
          current_user &&
            (Rice.Tasks.can_manage?(task, current_user) || current_user.id == task.assignee_id),
          do: task.appointment_reason
        ),
      reward_amount: task.reward_amount,
      reward_status: task.reward_status,
      application_count: length(applications),
      my_application_status: my_application_status(task, applications, current_user),
      my_application: my_application(task, applications, current_user, detail?),
      allowed_actions: allowed_actions(task, applications, current_user),
      applications: visible_applications(task, applications, current_user, detail?),
      past_applications:
        visible_past_applications(task, past_applications, current_user, detail?),
      submissions: visible_submissions(task, submissions, current_user, detail?),
      past_submissions: visible_past_submissions(task, past_submissions, current_user, detail?),
      events: if(detail?, do: visible_events(task, events, current_user), else: nil),
      published_at: published_at(task, events),
      inserted_at: task.inserted_at,
      updated_at: task.updated_at
    }
  end

  defp visible_applications(task, applications, %User{} = user, true),
    do: if(Rice.Tasks.can_manage?(task, user), do: Enum.map(applications, &application(&1, task)))

  defp visible_applications(_task, _applications, _user, _detail?), do: nil

  defp visible_past_applications(task, applications, %User{id: user_id}, true) do
    applications
    |> Enum.filter(&(task.creator_id == user_id || &1.user_id == user_id))
    |> Enum.map(&application(&1, task))
  end

  defp visible_past_applications(_task, _applications, _user, _detail?), do: nil

  defp visible_submissions(task, submissions, %User{id: user_id} = user, true),
    do:
      if(user_id == task.assignee_id || Rice.Tasks.can_manage?(task, user),
        do: Enum.map(submissions, &submission(&1, task))
      )

  defp visible_submissions(_task, _submissions, _user, _detail?), do: nil

  defp visible_past_submissions(task, submissions, %User{id: user_id}, true) do
    submissions
    |> Enum.filter(&(task.creator_id == user_id || &1.user_id == user_id))
    |> Enum.map(&submission(&1, task))
  end

  defp visible_past_submissions(_task, _submissions, _user, _detail?), do: nil

  defp application(%Application{} = application, task, detail? \\ true) do
    %{
      id: application.id,
      round: application.round,
      reason: application.reason,
      status: application_status(application, task),
      user: public_user(application.user),
      inserted_at: application.inserted_at
    }
    |> then(fn data ->
      if detail?, do: Map.put(data, :contact, application.contact), else: data
    end)
  end

  defp submission(%Submission{} = submission, task) do
    %{
      id: submission.id,
      round: submission.round,
      body: submission.body,
      status: submission_status(submission, task),
      review_reason: submission.review_reason,
      user: public_user(submission.user),
      inserted_at: submission.inserted_at
    }
  end

  defp my_application(_task, _applications, nil, _detail?), do: nil

  defp my_application(task, applications, user, detail?) do
    case Enum.find(applications, &(&1.user_id == user.id)) do
      nil -> nil
      own -> application(own, task, detail?)
    end
  end

  defp visible_events(task, events, user) do
    manager? = Rice.Tasks.can_manage?(task, user)
    private? = user && (manager? || user.id == task.assignee_id)

    events
    |> Enum.filter(fn e ->
      e.detail != "收到任务申请" || manager? || (user && user.id == e.actor_id)
    end)
    |> Enum.filter(fn e ->
      private? || e.from_status != e.to_status || e.detail == "申请已截止" || e.before != nil
    end)
    |> Enum.map(fn e ->
      rendered = event(e)
      if private?, do: rendered, else: %{rendered | detail: nil}
    end)
  end

  defp past?(nil), do: false
  defp past?(time), do: DateTime.compare(time, DateTime.utc_now()) != :gt

  defp event(%Event{} = event) do
    %{
      id: event.id,
      from_status: event.from_status,
      to_status: event.to_status,
      detail: event.detail,
      action: if(event.before, do: "edited"),
      before: event.before,
      after: event.after,
      actor: public_user(event.actor),
      inserted_at: event.inserted_at
    }
  end

  defp allowed_actions(_task, _applications, nil), do: []

  defp allowed_actions(task, applications, %User{id: user_id} = user) do
    manager? = Rice.Tasks.can_manage?(task, user)

    can_review_applications? =
      task.status == "open" and not past?(task.application_deadline) and manager? and
        Enum.any?(applications, &is_nil(&1.rejected_at))

    []
    |> maybe_add(task.status == "draft" and manager?, "publish")
    |> maybe_add(
      task.status in ~w(draft open in_progress overdue under_review expired cancelled) and
        Rice.Tasks.can_edit?(task, user),
      "edit"
    )
    |> maybe_add(
      task.status == "open" and not past?(task.application_deadline) and
        task.creator_id != user_id and not manager? and
        not Enum.any?(applications, &(&1.user_id == user_id)),
      "apply"
    )
    |> maybe_add(can_review_applications?, "appoint")
    |> maybe_add(can_review_applications?, "reject_application")
    |> maybe_add(
      manager? and
        (task.status == "draft" or
           (task.status == "open" and not past?(task.application_deadline))),
      "cancel"
    )
    |> maybe_add(
      task.status in ["in_progress", "overdue"] and task.assignee_id == user_id,
      "submit_result"
    )
    |> maybe_add(task.status == "under_review" and manager?, "approve_result")
    |> maybe_add(task.status == "under_review" and manager?, "request_changes")
    |> Enum.reverse()
  end

  defp maybe_add(actions, true, action), do: [action | actions]
  defp maybe_add(actions, false, _action), do: actions

  defp my_application_status(_task, _applications, nil), do: nil

  defp my_application_status(task, applications, %User{id: user_id}) do
    case Enum.find(applications, &(&1.user_id == user_id)) do
      nil -> nil
      application -> application_status(application, task)
    end
  end

  defp application_status(%Application{final_status: status}, _task) when not is_nil(status),
    do: status

  defp application_status(%Application{user_id: id}, %{assignee_id: id}), do: "appointed"

  defp application_status(%Application{rejected_at: rejected_at}, _task)
       when not is_nil(rejected_at),
       do: "not_selected"

  defp application_status(_application, %{status: "open", application_deadline: deadline}),
    do: if(past?(deadline), do: "expired", else: "pending")

  defp application_status(_application, %{status: "cancelled"}), do: "cancelled"
  defp application_status(_application, %{status: "expired"}), do: "expired"
  defp application_status(_application, _task), do: "not_selected"

  defp submission_status(%Submission{final_status: status}, _task) when not is_nil(status),
    do: status

  defp submission_status(%Submission{review_reason: reason}, _task) when not is_nil(reason),
    do: "changes_requested"

  defp submission_status(_submission, %{status: "completed"}), do: "approved"
  defp submission_status(_submission, _task), do: "pending"

  defp loaded(%Ecto.Association.NotLoaded{}), do: []
  defp loaded(items) when is_list(items), do: items

  defp published_at(%{status: "draft"}, _events), do: nil

  defp published_at(task, events) do
    case events
         |> Enum.filter(
           &(&1.to_status == "open" and &1.from_status != "open" and
               &1.detail != "状态记录从这里开始")
         )
         |> List.last() do
      nil -> task.inserted_at
      event -> event.inserted_at
    end
  end

  defp public_user(nil), do: nil
  defp public_user(%Ecto.Association.NotLoaded{}), do: nil
  defp public_user(user), do: UserJSON.public(user)
end

defmodule Rice.Tasks do
  @moduledoc """
  社区单人任务：草稿、发布、申请、任命、交付与验收。

  管理员代表节点发布，由社区账户出资；历史任务保留原出资账户。
  """
  import Ecto.Query

  alias Ecto.Multi
  alias Rice.Accounts.User
  alias Rice.Tasks.{Application, Event, Notification, Submission, Task}
  alias Rice.{Grains, Pagination, Repo}

  @overdue_detail "交付已超时，仍可提交成果"
  @public_visibility_grace_seconds 24 * 60 * 60

  def list_tasks(user, params \\ %{}) do
    query =
      from(t in Task, as: :task)
      |> scope_visibility(user, params["mine"])
      |> filter_status(params["status"])
      |> filter_query(params["q"])
      |> filter_node(params["node_id"])
      |> filter_available(user, params["available"])
      |> scope_public_user(params["participant_did"], params["creator_did"])
      |> scope_mine(user, params["mine"])

    page = paginate_tasks(query, params)

    %{page | entries: preload_list(page.entries)}
  end

  def fetch_task(id, user \\ nil) do
    with {:ok, task} <- fetch_task_record(id),
         true <- visible_to?(task, user) do
      {:ok, task}
    else
      false -> {:error, :not_found}
      error -> error
    end
  end

  defp fetch_task_record(id) do
    if Rice.Tsid.valid?(id) do
      case Repo.get(Task, id) do
        nil -> {:error, :not_found}
        task -> {:ok, preload_detail(task)}
      end
    else
      {:error, :not_found}
    end
  end

  def create_task(%User{} = user, attrs) do
    Repo.transaction(fn ->
      Repo.one!(from u in User, where: u.id == ^user.id, lock: "FOR UPDATE")

      with {:ok, node} <- publishing_node(user, attrs["node_id"] || attrs[:node_id]) do
        key = attrs["client_request_id"] || attrs[:client_request_id]

        existing =
          if is_binary(key) && key != "",
            do: Repo.get_by(Task, creator_id: user.id, client_request_id: key)

        if existing do
          preload_detail(existing)
        else
          case create_new_task(user, node, attrs) do
            {:ok, task} -> task
            {:error, reason} -> Repo.rollback(reason)
          end
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def can_manage?(_task, nil), do: false

  def can_manage?(%Task{status: "draft", creator_id: id} = task, user),
    do:
      id == user.id and not is_nil(task.node_id) and
        Rice.Community.admin?(Repo.get(Rice.Community.Node, task.node_id), user)

  def can_manage?(%Task{funding_node_id: nil, creator_id: id}, %User{id: user_id}),
    do: id == user_id

  def can_manage?(task, user),
    do:
      not is_nil(task.node_id) and
        Rice.Community.admin?(Repo.get(Rice.Community.Node, task.node_id), user)

  defp authorize_management(task, user),
    do: if(can_manage?(task, user), do: :ok, else: {:error, :forbidden})

  def can_edit?(%Task{status: "draft"} = task, user), do: can_manage?(task, user)

  def can_edit?(%Task{node_id: node_id}, %User{} = user),
    do: Rice.Community.admin?(Repo.get(Rice.Community.Node, node_id), user)

  def can_edit?(_, _), do: false

  defp publishing_node(user, nil) do
    ids = Rice.Community.managed_node_ids(user)

    case Repo.all(from n in Rice.Community.Node, where: n.id in ^ids, limit: 2) do
      [node] -> {:ok, node}
      _ -> {:error, :forbidden}
    end
  end

  defp publishing_node(user, id) do
    if Rice.Tsid.valid?(id) do
      node = Repo.get(Rice.Community.Node, id)
      if Rice.Community.admin?(node, user), do: {:ok, node}, else: {:error, :forbidden}
    else
      {:error, :forbidden}
    end
  end

  defp create_new_task(user, node, attrs) do
    with {:ok, status} <- initial_status(attrs) do
      # Do not wait on the draft unique index while holding the payer lock:
      # publishing that draft needs the same payer lock to reserve its reward.
      if status == "draft" and
           Repo.exists?(
             from t in Task,
               where: t.creator_id == ^user.id and t.status == "draft"
           ) do
        Repo.rollback(
          Ecto.Changeset.add_error(Ecto.Changeset.change(%Task{}), :creator_id, "已有草稿，请继续编辑")
        )
      end

      task_changeset =
        %Task{creator_id: user.id, node_id: node.id, funding_node_id: node.id, status: status}
        |> Task.create_changeset(attrs)

      reward_amount = Ecto.Changeset.get_field(task_changeset, :reward_amount) || 0

      task_changeset =
        Ecto.Changeset.put_change(
          task_changeset,
          :reward_status,
          if(status == "open" and reward_amount > 0, do: "reserved", else: "none")
        )

      Multi.new()
      |> Multi.insert(:task, task_changeset)
      |> maybe_run_reward(
        if status == "open" and reward_amount > 0 do
          fn repo, %{task: task} ->
            Grains.reserve_business(
              repo,
              reward_account(task),
              reward_amount,
              "rice://tasks/#{task.id}"
            )
          end
        end
      )
      |> Multi.insert(:event, fn %{task: task} ->
        detail = if status == "open", do: reward_detail(task, :reserved)
        event_changeset(task.id, user.id, nil, status, detail)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{task: task}} -> {:ok, preload_detail(task)}
        {:error, _step, reason, _changes} -> {:error, reason}
      end
    end
  end

  def update_draft(user, task, attrs) do
    with_locked_task(task.id, &update_current_draft(user, &1, attrs))
  end

  def update_task(user, task, attrs) do
    with_locked_task(task.id, fn current ->
      if current.status == "draft",
        do: update_current_draft(user, current, attrs),
        else: update_current_published(user, current, attrs)
    end)
  end

  defp update_current_published(user, task, attrs) do
    with true <- can_edit?(task, user) or {:error, :forbidden},
         true <-
           task.status in ~w(open in_progress overdue under_review expired cancelled) or
             {:error, :conflict} do
      attrs = Map.drop(attrs, ["client_request_id", :client_request_id])
      task = Repo.preload(task, :image_links)
      node_id = attrs["node_id"] || attrs[:node_id] || task.node_id

      with changeset <-
             task
             |> Task.create_changeset(attrs, published_edit: true, editing_user_id: user.id)
             |> Ecto.Changeset.put_change(:node_id, node_id)
             |> validate_active_terms_edit(task)
             |> validate_reopen_schedule(task),
           {:ok, _} <- Ecto.Changeset.apply_action(changeset, :update),
           :ok <- require_edit_node(user, task.node_id, node_id) do
        before = task_snapshot(task)
        amount = Ecto.Changeset.get_field(changeset, :reward_amount)
        application_deadline = Ecto.Changeset.get_field(changeset, :application_deadline)

        reopening? = task.status in ~w(expired cancelled)

        expiring? =
          task.status == "open" and not is_nil(application_deadline) and
            DateTime.compare(application_deadline, DateTime.utc_now()) != :gt

        overdue? =
          task.status == "in_progress" and
            case Ecto.Changeset.get_field(changeset, :execution_deadline) do
              nil -> false
              deadline -> DateTime.compare(deadline, DateTime.utc_now()) != :gt
            end

        resuming? =
          task.status == "overdue" and
            Ecto.Changeset.changed?(changeset, :execution_deadline) and
            case Ecto.Changeset.get_field(changeset, :execution_deadline) do
              nil -> false
              deadline -> DateTime.compare(deadline, DateTime.utc_now()) == :gt
            end

        with {:ok, changeset} <- revise_reward(task, changeset, amount, node_id, reopening?),
             {:ok, changeset} <- expire_edited_task(task, changeset, expiring?),
             :ok <- maybe_begin_next_round(task, reopening?),
             changeset <-
               changeset
               |> Ecto.Changeset.put_change(
                 :status,
                 next_edited_status(task.status, reopening?, expiring?, overdue?, resuming?)
               )
               |> maybe_reset_assignee(reopening?)
               |> maybe_advance_round(task.round, reopening?),
             {:ok, saved} <- Repo.update(changeset) do
          saved = Repo.preload(saved, :image_links, force: true)
          after_snapshot = task_snapshot(saved)

          history =
            if before != after_snapshot do
              Repo.insert(
                Event.create_changeset(%Event{}, %{
                  task_id: task.id,
                  actor_id: user.id,
                  from_status: task.status,
                  to_status: saved.status,
                  detail: if(reopening?, do: "编辑并重新开放任务", else: "编辑了任务"),
                  before: before,
                  after: after_snapshot
                })
              )
            else
              {:ok, nil}
            end

          with {:ok, _} <- history,
               :ok <- maybe_notify_edited_due(task, saved, user.id, expiring?, overdue?) do
            {:ok, preload_detail(saved)}
          end
        end
      end
    else
      false -> {:error, :conflict}
      error -> error
    end
  end

  defp validate_active_terms_edit(changeset, %Task{status: status})
       when status in ~w(open in_progress overdue under_review) do
    changeset =
      if Ecto.Changeset.changed?(changeset, :reward_amount),
        do: Ecto.Changeset.add_error(changeset, :reward_amount, "已发布任务不能修改稻米报酬"),
        else: changeset

    if Ecto.Changeset.changed?(changeset, :node_id),
      do: Ecto.Changeset.add_error(changeset, :node_id, "已发布任务不能修改所属社区"),
      else: changeset
  end

  defp validate_active_terms_edit(changeset, _task), do: changeset

  defp validate_reopen_schedule(changeset, %Task{status: status})
       when status in ~w(expired cancelled) do
    case Ecto.Changeset.get_field(changeset, :application_deadline) do
      nil ->
        Ecto.Changeset.add_error(changeset, :application_deadline, "重新开放需要将来的申请截止时间")

      deadline ->
        if DateTime.compare(deadline, DateTime.utc_now()) == :gt,
          do: changeset,
          else: Ecto.Changeset.add_error(changeset, :application_deadline, "重新开放需要将来的申请截止时间")
    end
  end

  defp validate_reopen_schedule(changeset, _task), do: changeset

  defp next_edited_status(_status, true, _, _, _), do: "open"
  defp next_edited_status(_status, _, true, _, _), do: "expired"
  defp next_edited_status(_status, _, _, true, _), do: "overdue"
  defp next_edited_status(_status, _, _, _, true), do: "in_progress"
  defp next_edited_status(status, _, _, _, _), do: status

  defp maybe_reset_assignee(changeset, false), do: changeset

  defp maybe_reset_assignee(changeset, true) do
    changeset
    |> Ecto.Changeset.put_change(:assignee_id, nil)
    |> Ecto.Changeset.put_change(:appointed_at, nil)
    |> Ecto.Changeset.put_change(:appointment_reason, nil)
  end

  defp maybe_advance_round(changeset, _round, false), do: changeset

  defp maybe_advance_round(changeset, round, true),
    do: Ecto.Changeset.put_change(changeset, :round, round + 1)

  defp expire_edited_task(_task, changeset, false), do: {:ok, changeset}

  defp expire_edited_task(task, changeset, true) do
    case maybe_refund_edited_reward(task) do
      {:ok, _} ->
        {:ok,
         Ecto.Changeset.put_change(
           changeset,
           :reward_status,
           if(task.reward_status == "reserved", do: "refunded", else: "none")
         )}

      error ->
        error
    end
  end

  defp maybe_begin_next_round(_task, false), do: :ok

  defp maybe_begin_next_round(task, true) do
    applications =
      Repo.all(from a in Application, where: a.task_id == ^task.id and a.round == ^task.round)

    submissions =
      Repo.all(from s in Submission, where: s.task_id == ^task.id and s.round == ^task.round)

    with :ok <- archive_applications(task, applications),
         do: archive_submissions(task, submissions)
  end

  defp archive_applications(task, applications) do
    Enum.reduce_while(applications, :ok, fn application, _ ->
      status = previous_application_status(task, application)

      case Repo.update(Ecto.Changeset.change(application, final_status: status)) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp archive_submissions(task, submissions) do
    Enum.reduce_while(submissions, :ok, fn submission, _ ->
      status = previous_submission_status(task, submission)

      case Repo.update(Ecto.Changeset.change(submission, final_status: status)) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp previous_application_status(%Task{assignee_id: user_id}, %Application{user_id: user_id})
       when not is_nil(user_id),
       do: "appointed"

  defp previous_application_status(_task, %Application{rejected_at: rejected_at})
       when not is_nil(rejected_at),
       do: "not_selected"

  defp previous_application_status(%Task{status: status}, _application)
       when status in ["cancelled", "expired"],
       do: status

  defp previous_application_status(_task, _application), do: "not_selected"

  defp previous_submission_status(_task, %Submission{review_reason: reason})
       when not is_nil(reason),
       do: "changes_requested"

  defp previous_submission_status(_task, _submission), do: "pending"

  defp maybe_notify_edited_due(_old, _saved, _actor_id, false, false), do: :ok

  defp maybe_notify_edited_due(old, saved, actor_id, expiring?, overdue?) do
    recipients =
      cond do
        expiring? ->
          Enum.map(applicant_ids(Repo, old), &{&1, "task_expired", "申请已截止"})

        overdue? ->
          [{old.assignee_id, "task_overdue", @overdue_detail}]
      end

    Enum.reduce_while(recipients, :ok, fn {recipient_id, event, detail}, _ ->
      case Repo.insert(notification_changeset(saved, recipient_id, actor_id, event, detail)) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp revise_reward(_task, changeset, _amount, _node_id, false),
    do: {:ok, changeset}

  defp revise_reward(task, changeset, amount, node_id, true) do
    with {:ok, subject} <- maybe_reserve_edited_reward({:node, node_id}, amount, task.id) do
      {:ok,
       changeset
       |> Ecto.Changeset.put_change(:funding_node_id, node_id)
       |> Ecto.Changeset.put_change(:reward_status, if(amount > 0, do: "reserved", else: "none"))
       |> Ecto.Changeset.put_change(:reward_subject_uri, subject)}
    end
  end

  defp maybe_refund_edited_reward(%Task{reward_status: "reserved", reward_amount: amount} = task)
       when amount > 0,
       do: Grains.refund_business(Repo, reward_account(task), amount, reward_subject(task))

  defp maybe_refund_edited_reward(_task), do: {:ok, nil}

  defp maybe_reserve_edited_reward(_account, 0, _task_id), do: {:ok, nil}

  defp maybe_reserve_edited_reward(account, amount, task_id) do
    subject = "rice://tasks/#{task_id}/edits/#{Rice.Tsid.generate()}"

    case Grains.reserve_business(Repo, account, amount, subject) do
      {:ok, _} -> {:ok, subject}
      error -> error
    end
  end

  defp task_snapshot(task) do
    %{
      "node_id" => task.node_id,
      "node_name" => Repo.get!(Rice.Community.Node, task.node_id).name,
      "title" => task.title,
      "description" => task.description,
      "organizer_contact" => task.organizer_contact,
      "requirement" => task.requirement,
      "application_deadline" => task.application_deadline,
      "execution_deadline" => task.execution_deadline,
      "reward_amount" => task.reward_amount,
      "round" => task.round,
      "funding_node_id" => task.funding_node_id,
      "attachment_ids" => Enum.map(task.image_links, & &1.attachment_id)
    }
  end

  defp require_edit_node(_user, node_id, node_id), do: :ok

  defp require_edit_node(user, _old_node_id, new_node_id) do
    case publishing_node(user, new_node_id) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp update_current_draft(
         %User{id: creator_id},
         %Task{creator_id: creator_id, status: "draft"} = task,
         attrs
       ) do
    attrs = Map.drop(attrs, ["client_request_id", :client_request_id])

    with {:ok, updated} <- task |> Task.create_changeset(attrs) |> Repo.update() do
      {:ok, preload_detail(updated)}
    end
  end

  defp update_current_draft(%User{id: creator_id}, %Task{creator_id: creator_id}, _attrs),
    do: {:error, :conflict}

  defp update_current_draft(%User{}, %Task{}, _attrs), do: {:error, :forbidden}

  def publish_draft(user, %Task{} = task) do
    with_locked_task(task.id, &publish_current_draft(user, &1))
  end

  defp publish_current_draft(
         %User{id: creator_id},
         %Task{creator_id: creator_id, status: "draft"} = task
       ) do
    with {:ok, _node} <- publishing_node(%User{id: creator_id}, task.node_id) do
      case Task.publish_changeset(task) do
        %{valid?: true} ->
          {updates, detail, reward_step} = reserve_reward(task)

          transition_task(
            from(t in Task, where: t.id == ^task.id and t.status == "draft"),
            task,
            updates,
            creator_id,
            detail,
            [],
            reward_step
          )

        changeset ->
          {:error, changeset}
      end
    end
  end

  defp publish_current_draft(
         %User{id: creator_id},
         %Task{creator_id: creator_id, status: "open"} = task
       ),
       do: {:ok, preload_detail(task)}

  defp publish_current_draft(%User{id: creator_id}, %Task{creator_id: creator_id}),
    do: {:error, :conflict}

  defp publish_current_draft(%User{}, %Task{}), do: {:error, :forbidden}

  def cancel(user, task) do
    with_locked_task(task.id, fn current ->
      with :ok <- authorize_management(current, user), do: cancel_current(user, current)
    end)
  end

  defp cancel_current(%User{id: creator_id}, %Task{status: status} = task)
       when status in ["open", "draft"] do
    if status == "open" and application_deadline_reached?(task) do
      {:error, :conflict}
    else
      {updates, detail, reward_step} = refund_reward(task, "cancelled")

      notifications =
        fn repo ->
          Enum.map(applicant_ids(repo, task), &{&1, creator_id, "task_cancelled", nil})
        end

      transition_task(
        from(t in Task, where: t.id == ^task.id and t.status == ^status),
        task,
        updates,
        creator_id,
        detail,
        notifications,
        reward_step
      )
    end
  end

  defp cancel_current(%User{}, %Task{}), do: {:error, :conflict}

  def apply(%User{id: user_id}, %Task{creator_id: user_id}, _attrs),
    do: {:error, :forbidden}

  def apply(%User{} = user, %Task{status: "open"} = task, attrs) do
    now = DateTime.utc_now()

    if can_manage?(task, user) do
      {:error, :forbidden}
    else
      Multi.new()
      |> Multi.run(:task, fn repo, _ -> lock_open_task(repo, task.id, now) end)
      |> Multi.run(:existing_application, fn repo, %{task: current_task} ->
        {:ok,
         repo.get_by(Application,
           task_id: task.id,
           round: current_task.round,
           user_id: user.id
         )}
      end)
      |> Multi.run(:application, fn repo, %{task: current_task, existing_application: existing} ->
        case existing do
          nil ->
            %Application{task_id: task.id, round: current_task.round, user_id: user.id}
            |> Application.create_changeset(attrs)
            |> repo.insert()

          existing ->
            {:ok, existing}
        end
      end)
      |> Multi.run(:application_event, fn repo, %{existing_application: existing} ->
        if existing,
          do: {:ok, :already_applied},
          else: repo.insert(event_changeset(task.id, user.id, "open", "open", "收到任务申请"))
      end)
      |> Multi.merge(fn %{task: current_task, existing_application: existing} ->
        recipients = if existing, do: [], else: manager_ids(current_task)

        notification_multi(
          current_task,
          Enum.map(recipients, &{&1, user.id, "application_created", nil})
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{application: application}} ->
          {:ok, Repo.preload(application, user: :avatar)}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  def apply(%User{}, %Task{}, _attrs), do: {:error, :conflict}

  def appoint(user, %Task{} = task, application_id, attrs \\ %{}) do
    with_locked_task(task.id, fn current ->
      with :ok <- authorize_management(current, user),
           {:ok, application} <- fetch_record(Application, current, application_id) do
        appoint_application(user, current, application, attrs)
      end
    end)
  end

  def reject_application(user, %Task{} = task, application_id) do
    with_locked_task(task.id, fn current ->
      with :ok <- authorize_management(current, user),
           {:ok, application} <- fetch_record(Application, current, application_id) do
        reject_current_application(user, current, application)
      end
    end)
  end

  defp reject_current_application(
         %User{id: creator_id},
         %Task{status: "open"} = task,
         %Application{} = application
       ) do
    cond do
      application_deadline_reached?(task) ->
        {:error, :conflict}

      application.rejected_at ->
        {:ok, preload_detail(task)}

      true ->
        with {:ok, _} <-
               application
               |> Ecto.Changeset.change(rejected_at: DateTime.utc_now())
               |> Repo.update(),
             {:ok, _} <-
               Repo.insert(
                 notification_changeset(
                   task,
                   application.user_id,
                   creator_id,
                   "application_rejected"
                 )
               ) do
          {:ok, preload_detail(task)}
        end
    end
  end

  defp reject_current_application(%User{}, %Task{}, _application), do: {:error, :conflict}

  defp appoint_application(
         %User{id: creator_id},
         %Task{status: "open"} = task,
         %Application{task_id: task_id, rejected_at: nil} = application,
         attrs
       )
       when task_id == task.id do
    changeset = Task.appointment_changeset(task, attrs)

    cond do
      application_deadline_reached?(task) ->
        {:error, :conflict}

      not changeset.valid? ->
        {:error, changeset}

      true ->
        appointment_reason = Ecto.Changeset.get_field(changeset, :appointment_reason)

        notifications =
          fn repo ->
            pending_ids =
              repo.all(
                from a in Application,
                  where:
                    a.task_id == ^task.id and a.round == ^task.round and is_nil(a.rejected_at),
                  select: a.user_id
              )

            Enum.map(pending_ids, fn user_id ->
              if user_id == application.user_id,
                do: {user_id, creator_id, "assignee_appointed", appointment_reason},
                else: {user_id, creator_id, "application_not_selected", nil}
            end)
          end

        transition_task(
          from(t in Task, where: t.id == ^task.id and t.status == "open"),
          task,
          [
            status: "in_progress",
            assignee_id: application.user_id,
            appointed_at: DateTime.utc_now(),
            appointment_reason: appointment_reason
          ],
          creator_id,
          appointment_reason,
          notifications
        )
    end
  end

  defp appoint_application(%User{}, %Task{}, %Application{}, _attrs), do: {:error, :conflict}

  def submit_result(user, %Task{} = task, attrs),
    do: with_locked_task(task.id, &submit_current_result(user, &1, attrs))

  defp submit_current_result(
         %User{id: user_id},
         %Task{assignee_id: user_id, status: status} = task,
         attrs
       )
       when status in ["in_progress", "overdue"] do
    now = DateTime.utc_now()

    newly_overdue? =
      status == "in_progress" and not is_nil(task.execution_deadline) and
        DateTime.compare(task.execution_deadline, now) != :gt

    from_status = if newly_overdue?, do: "overdue", else: status

    changeset =
      Submission.create_changeset(
        %Submission{task_id: task.id, round: task.round, user_id: user_id},
        attrs
      )

    Multi.new()
    |> maybe_mark_overdue(task, newly_overdue?, now)
    |> Multi.run(:task, fn repo, _ ->
      conditional_update(
        repo,
        from(t in Task,
          where: t.id == ^task.id and t.status == ^from_status and t.assignee_id == ^user_id
        ),
        status: "under_review",
        updated_at: now
      )
    end)
    |> Multi.insert(
      :event,
      event_changeset(task.id, user_id, from_status, "under_review")
    )
    |> Multi.insert(:submission, changeset)
    |> Multi.merge(fn _ ->
      notification_multi(
        task,
        Enum.map(manager_ids(task), &{&1, user_id, "result_submitted", nil})
      )
    end)
    |> Repo.transaction()
    |> transaction_task(task.id)
  end

  defp submit_current_result(%User{id: user_id}, %Task{assignee_id: user_id}, _attrs),
    do: {:error, :conflict}

  defp submit_current_result(%User{}, %Task{}, _attrs), do: {:error, :forbidden}

  defp maybe_mark_overdue(multi, _task, false, _now), do: multi

  defp maybe_mark_overdue(multi, task, true, now) do
    multi
    |> Multi.run(:overdue, fn repo, _ ->
      conditional_update(
        repo,
        from(t in Task, where: t.id == ^task.id and t.status == "in_progress"),
        status: "overdue",
        updated_at: now
      )
    end)
    |> Multi.insert(
      :overdue_event,
      event_changeset(task.id, nil, "in_progress", "overdue", @overdue_detail)
    )
    |> Multi.insert(
      :overdue_notification,
      notification_changeset(
        task,
        task.assignee_id,
        task.creator_id,
        "task_overdue",
        @overdue_detail
      )
    )
  end

  def approve_result(user, %Task{} = task, submission_id) do
    with_locked_task(task.id, fn current_task ->
      with :ok <- authorize_management(current_task, user),
           {:ok, submission} <- fetch_record(Submission, current_task, submission_id) do
        approve_submission(user, current_task, submission)
      end
    end)
  end

  defp approve_submission(
         %User{id: creator_id},
         %Task{status: "under_review"} = task,
         %Submission{task_id: task_id, review_reason: nil} = submission
       )
       when task_id == task.id do
    {updates, detail, reward_step} = settle_reward(task, submission.user_id)

    transition_task(
      from(t in Task, where: t.id == ^task.id and t.status == "under_review"),
      task,
      updates,
      creator_id,
      detail,
      [{submission.user_id, creator_id, "result_approved", detail}],
      reward_step
    )
  end

  defp approve_submission(%User{}, %Task{}, %Submission{}), do: {:error, :conflict}

  def request_changes(user, %Task{} = task, submission_id, reason) do
    with_locked_task(task.id, fn current_task ->
      with :ok <- authorize_management(current_task, user),
           {:ok, submission} <- fetch_record(Submission, current_task, submission_id) do
        request_submission_changes(user, current_task, submission, reason)
      end
    end)
  end

  defp request_submission_changes(
         %User{id: creator_id},
         %Task{status: "under_review"} = task,
         %Submission{task_id: task_id, review_reason: nil} = submission,
         reason
       )
       when task_id == task.id and is_binary(reason) do
    changeset = Submission.review_changeset(submission, reason)

    if changeset.valid? do
      now = DateTime.utc_now()

      next_status =
        if task.execution_deadline && DateTime.compare(task.execution_deadline, now) != :gt,
          do: "overdue",
          else: "in_progress"

      Multi.new()
      |> Multi.run(:task, fn repo, _ ->
        conditional_update(
          repo,
          from(t in Task, where: t.id == ^task.id and t.status == "under_review"),
          status: next_status,
          updated_at: now
        )
      end)
      |> Multi.insert(
        :event,
        event_changeset(task.id, creator_id, "under_review", next_status, reason)
      )
      |> Multi.update(:submission, changeset)
      |> Multi.insert(
        :notification,
        notification_changeset(task, submission.user_id, creator_id, "changes_requested", reason)
      )
      |> Repo.transaction()
      |> transaction_task(task.id)
    else
      {:error, changeset}
    end
  end

  defp request_submission_changes(%User{}, %Task{}, %Submission{}, _), do: {:error, :conflict}

  def check_due_tasks(now \\ DateTime.utc_now()) do
    due =
      from(t in Task,
        where:
          (t.status == "open" and t.application_deadline <= ^now) or
            (t.status == "in_progress" and t.execution_deadline <= ^now)
      )

    results =
      due
      |> select([t], t.id)
      |> Repo.all()
      |> Enum.map(fn id ->
        Repo.transaction(fn ->
          case Repo.one(from t in due, where: t.id == ^id, lock: "FOR UPDATE SKIP LOCKED") do
            nil ->
              nil

            task ->
              case transition_due_task(task) do
                {:ok, updated} -> updated
                {:error, reason} -> Repo.rollback(reason)
              end
          end
        end)
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:ok, for({:ok, %Task{} = task} <- results, do: task)}
      error -> error
    end
  end

  defp transition_due_task(%Task{status: "open"} = task) do
    {updates, reward_detail, reward_step} = refund_reward(task, "expired")
    detail = Enum.join(Enum.reject(["申请已截止", reward_detail], &is_nil/1), "，")

    transition_task(
      from(t in Task, where: t.id == ^task.id and t.status == "open"),
      task,
      updates,
      nil,
      detail,
      fn repo ->
        Enum.map(applicant_ids(repo, task), &{&1, task.creator_id, "task_expired", detail})
      end,
      reward_step
    )
  end

  defp transition_due_task(%Task{status: "in_progress"} = task) do
    transition_task(
      from(t in Task, where: t.id == ^task.id and t.status == "in_progress"),
      task,
      [status: "overdue"],
      nil,
      @overdue_detail,
      [{task.assignee_id, task.creator_id, "task_overdue", @overdue_detail}]
    )
  end

  def list_notifications(%User{id: user_id}) do
    from(n in Notification,
      where: n.recipient_id == ^user_id and not is_nil(n.task_id),
      order_by: [desc: n.id],
      limit: 50,
      preload: [actor: :avatar, task: []]
    )
    |> Repo.all()
  end

  def mark_notifications_read(%User{id: user_id}) do
    Repo.update_all(
      from(n in Notification, where: n.recipient_id == ^user_id and is_nil(n.read_at)),
      set: [read_at: DateTime.utc_now(), updated_at: DateTime.utc_now()]
    )

    :ok
  end

  defp initial_status(attrs) do
    case attrs["status"] || attrs[:status] do
      nil -> {:ok, "open"}
      "draft" -> {:ok, "draft"}
      "open" -> {:ok, "open"}
      _ -> {:error, :unprocessable_entity}
    end
  end

  defp application_deadline_reached?(%Task{application_deadline: nil}), do: false

  defp application_deadline_reached?(%Task{application_deadline: deadline}),
    do: DateTime.compare(deadline, DateTime.utc_now()) != :gt

  defp visible_to?(%Task{status: "draft", creator_id: creator_id}, %User{id: creator_id}),
    do: true

  defp visible_to?(%Task{status: "draft"}, _user), do: false
  defp visible_to?(%Task{status: "cancelled"} = task, user), do: private_viewer?(task, user)

  defp visible_to?(%Task{status: "open", application_deadline: deadline} = task, user) do
    is_nil(deadline) or
      DateTime.compare(
        deadline,
        DateTime.add(DateTime.utc_now(), -@public_visibility_grace_seconds)
      ) == :gt or
      private_viewer?(task, user)
  end

  defp visible_to?(%Task{status: "expired", application_deadline: deadline} = task, user) do
    (deadline &&
       DateTime.compare(
         deadline,
         DateTime.add(DateTime.utc_now(), -@public_visibility_grace_seconds)
       ) == :gt) ||
      private_viewer?(task, user)
  end

  defp visible_to?(%Task{}, _user), do: true

  defp private_viewer?(_task, nil), do: false

  defp private_viewer?(task, %User{id: id} = user) do
    task.creator_id == id or can_manage?(task, user) or can_edit?(task, user) or
      Repo.exists?(from a in Application, where: a.task_id == ^task.id and a.user_id == ^id)
  end

  defp scope_visibility(query, %User{}, mine) when mine in ~w(created managed assigned applied),
    do: query

  defp scope_visibility(query, _user, _mine) do
    cutoff = DateTime.add(DateTime.utc_now(), -@public_visibility_grace_seconds)

    from(t in query,
      where:
        t.status not in ["draft", "cancelled"] and
          (t.status != "expired" or t.application_deadline > ^cutoff) and
          (t.status != "open" or is_nil(t.application_deadline) or
             t.application_deadline > ^cutoff)
    )
  end

  defp filter_status(query, status)
       when status in ~w(draft open in_progress overdue under_review completed expired cancelled),
       do: from(t in query, where: t.status == ^status)

  defp filter_status(query, "closed"),
    do: from(t in query, where: t.status in ["expired", "cancelled"])

  defp filter_status(query, _), do: query

  defp filter_query(query, value) when is_binary(value) and value != "" do
    pattern = "%" <> escape_like(String.trim(value)) <> "%"
    from(t in query, where: ilike(t.title, ^pattern) or ilike(t.description, ^pattern))
  end

  defp filter_query(query, _), do: query

  defp filter_node(query, nil), do: query

  defp filter_node(query, id) do
    if Rice.Tsid.valid?(id),
      do: from(t in query, where: t.node_id == ^id),
      else: from(t in query, where: false)
  end

  defp filter_available(query, %User{id: id}, value) when value in [true, "true", "1"] do
    now = DateTime.utc_now()

    managed_ids = Rice.Community.managed_node_ids(%User{id: id})

    applied =
      from a in Application,
        where:
          a.task_id == parent_as(:task).id and a.round == parent_as(:task).round and
            a.user_id == ^id,
        select: 1

    from(t in query,
      where:
        t.status == "open" and t.creator_id != ^id and
          (is_nil(t.funding_node_id) or t.node_id not in ^managed_ids) and
          not exists(applied) and
          (is_nil(t.application_deadline) or t.application_deadline > ^now)
    )
  end

  defp filter_available(query, nil, value) when value in [true, "true", "1"],
    do: from(t in query, where: false)

  defp filter_available(query, _, _), do: query

  defp paginate_tasks(query, %{"sort" => "published"} = params) do
    %{limit: limit, before: before} = Pagination.params(params)

    published_events =
      from(e in Event,
        where:
          e.to_status == "open" and
            (is_nil(e.from_status) or e.from_status != "open") and
            (is_nil(e.detail) or e.detail != "状态记录从这里开始"),
        group_by: e.task_id,
        select: %{task_id: e.task_id, cursor: max(e.id)}
      )

    query =
      from([task: task] in query,
        left_join: published in subquery(published_events),
        as: :published,
        on: published.task_id == task.id,
        select_merge: %{
          search_cursor: fragment("COALESCE(?, ?)", published.cursor, task.id)
        }
      )
      |> before_published(before)
      |> order_by(
        [task: task, published: published],
        desc: fragment("COALESCE(?, ?)", published.cursor, task.id)
      )
      |> limit(^(limit + 1))
      |> Repo.all()

    {entries, more} = Enum.split(query, limit)

    %{
      entries: entries,
      next_cursor: if(more == [], do: nil, else: List.last(entries).search_cursor)
    }
  end

  defp paginate_tasks(query, params),
    do: Pagination.paginate(query, Repo, Pagination.params(params))

  defp before_published(query, nil), do: query

  defp before_published(query, before) do
    from([task: task, published: published] in query,
      where: fragment("COALESCE(?, ?)", published.cursor, task.id) < ^before
    )
  end

  defp scope_public_user(query, participant_did, creator_did) do
    query
    |> scope_participant(participant_did)
    |> scope_creator(creator_did)
  end

  defp scope_participant(query, did) when is_binary(did) and did != "" do
    from(t in query, join: user in User, on: user.id == t.assignee_id, where: user.did == ^did)
  end

  defp scope_participant(query, _did), do: query

  defp scope_creator(query, did) when is_binary(did) and did != "" do
    from(t in query,
      join: creator in User,
      on: creator.id == t.creator_id,
      where: creator.did == ^did
    )
  end

  defp scope_creator(query, _did), do: query

  defp scope_mine(query, %User{id: id}, "created"),
    do: from(t in query, where: t.creator_id == ^id)

  defp scope_mine(query, %User{id: id} = user, "managed") do
    ids = Rice.Community.managed_node_ids(user)

    from t in query,
      where:
        t.creator_id == ^id or
          (t.status != "draft" and t.node_id in ^ids)
  end

  defp scope_mine(query, %User{id: id}, "assigned") do
    previous_assignment =
      from(a in Application,
        where:
          a.task_id == parent_as(:task).id and a.user_id == ^id and
            a.final_status == "appointed",
        select: 1
      )

    from(t in query, where: t.assignee_id == ^id or exists(previous_assignment))
  end

  defp scope_mine(query, %User{id: id}, "applied") do
    application =
      from(a in Application,
        where: a.task_id == parent_as(:task).id and a.user_id == ^id,
        select: 1
      )

    from(t in query,
      where: exists(application) and (is_nil(t.assignee_id) or t.assignee_id != ^id)
    )
  end

  defp scope_mine(query, nil, mine) when mine in ~w(created managed assigned applied),
    do: from(t in query, where: false)

  defp scope_mine(query, _user, _mine), do: query

  defp conditional_update(repo, query, updates) do
    case repo.update_all(query, set: updates) do
      {1, _} -> {:ok, :updated}
      _ -> {:error, :conflict}
    end
  end

  # Core terms and the reviewed submission must come from the same locked task state.
  defp with_locked_task(task_id, action) do
    Repo.transaction(fn ->
      case Repo.one(from t in Task, where: t.id == ^task_id, lock: "FOR UPDATE") do
        nil ->
          Repo.rollback(:not_found)

        task ->
          case action.(task) do
            {:ok, result} -> result
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  defp transition_task(query, task, updates, actor_id, detail, notifications) do
    transition_task(query, task, updates, actor_id, detail, notifications, nil)
  end

  defp transition_task(query, task, updates, actor_id, detail, notifications, reward_step) do
    now = DateTime.utc_now()

    multi =
      Multi.new()
      |> Multi.run(:task, fn repo, _ ->
        conditional_update(repo, query, Keyword.put(updates, :updated_at, now))
      end)
      |> maybe_run_reward(reward_step)
      |> Multi.insert(
        :event,
        event_changeset(task.id, actor_id, task.status, Keyword.fetch!(updates, :status), detail)
      )
      |> Multi.run(:notification_rows, fn repo, _ ->
        {:ok, notification_rows(notifications, repo)}
      end)

    multi
    |> Multi.merge(fn %{notification_rows: rows} -> notification_multi(task, rows) end)
    |> Repo.transaction()
    |> transaction_task(task.id)
  end

  defp maybe_run_reward(multi, nil), do: multi

  defp maybe_run_reward(multi, reward_step) do
    Multi.run(multi, :task_reward, reward_step)
  end

  defp reserve_reward(%Task{reward_amount: amount} = task) when amount > 0 do
    # Drafts have no reservation yet. Publication fixes the community payer;
    # existing published tasks keep their nullable legacy funding owner.
    task = %{task | funding_node_id: task.node_id}

    {
      [status: "open", reward_status: "reserved", funding_node_id: task.node_id],
      reward_detail(task, :reserved),
      fn repo, _changes ->
        Grains.reserve_business(repo, reward_account(task), amount, reward_subject(task))
      end
    }
  end

  defp reserve_reward(task), do: {[status: "open", funding_node_id: task.node_id], nil, nil}

  defp refund_reward(%Task{reward_status: "reserved", reward_amount: amount} = task, status)
       when amount > 0 do
    {
      [status: status, reward_status: "refunded"],
      reward_detail(task, :refunded),
      fn repo, _changes ->
        Grains.refund_business(repo, reward_account(task), amount, reward_subject(task))
      end
    }
  end

  defp refund_reward(_task, status), do: {[status: status], nil, nil}

  defp settle_reward(
         %Task{reward_status: "reserved", reward_amount: amount} = task,
         assignee_id
       )
       when amount > 0 do
    {
      [status: "completed", reward_status: "settled"],
      reward_detail(task, :settled),
      fn repo, _changes ->
        Grains.settle_business(
          repo,
          reward_account(task),
          assignee_id,
          amount,
          reward_subject(task)
        )
      end
    }
  end

  defp settle_reward(_task, _assignee_id), do: {[status: "completed"], nil, nil}

  defp reward_account(%Task{funding_node_id: nil, creator_id: id}), do: id
  defp reward_account(%Task{funding_node_id: id}), do: {:node, id}
  defp reward_subject(%Task{reward_subject_uri: nil, id: id}), do: "rice://tasks/#{id}"
  defp reward_subject(%Task{reward_subject_uri: subject}), do: subject

  defp reward_detail(%Task{reward_amount: amount} = task, action) when amount > 0 do
    case action do
      :reserved -> "已冻结 #{amount} 稻米作为任务奖励"
      :settled -> "已向承作人发放 #{amount} 稻米"
      :refunded -> "已向#{if(task.funding_node_id, do: "社区", else: "发布者")}退回 #{amount} 稻米"
    end
  end

  defp reward_detail(_task, _action), do: nil

  defp manager_ids(task),
    do: Rice.Community.admin_ids(Repo.get!(Rice.Community.Node, task.node_id))

  defp notification_rows(builder, repo) when is_function(builder, 1), do: builder.(repo)
  defp notification_rows(rows, _repo), do: rows

  defp notification_multi(task, rows) do
    rows
    |> Enum.with_index()
    |> Enum.reduce(Multi.new(), fn {{recipient_id, actor_id, event, detail}, index}, multi ->
      Multi.insert(
        multi,
        {:notification, index},
        notification_changeset(task, recipient_id, actor_id, event, detail)
      )
    end)
  end

  defp applicant_ids(repo, task) do
    repo.all(
      from(a in Application,
        where: a.task_id == ^task.id and a.round == ^task.round,
        select: a.user_id
      )
    )
  end

  defp lock_open_task(repo, task_id, now) do
    query =
      from(t in Task,
        where:
          t.id == ^task_id and t.status == "open" and
            (is_nil(t.application_deadline) or t.application_deadline > ^now),
        lock: "FOR UPDATE"
      )

    case repo.one(query) do
      nil -> {:error, :conflict}
      task -> {:ok, task}
    end
  end

  defp notification_changeset(task, recipient_id, actor_id, event, detail \\ nil) do
    Notification.create_changeset(%Notification{}, %{
      task_id: task.id,
      recipient_id: recipient_id,
      actor_id: actor_id,
      event: event,
      detail: detail
    })
  end

  defp event_changeset(task_id, actor_id, from_status, to_status, detail \\ nil) do
    Event.create_changeset(%Event{}, %{
      task_id: task_id,
      actor_id: actor_id,
      from_status: from_status,
      to_status: to_status,
      detail: detail
    })
  end

  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp fetch_record(schema, task, id) do
    if Rice.Tsid.valid?(id) do
      case Repo.get_by(schema, id: id, task_id: task.id, round: task.round) do
        nil -> {:error, :not_found}
        record -> {:ok, record}
      end
    else
      {:error, :not_found}
    end
  end

  defp transaction_task({:ok, _changes}, task_id), do: fetch_task_record(task_id)
  defp transaction_task({:error, _step, reason, _changes}, _task_id), do: {:error, reason}

  defp preload_list(tasks) do
    Repo.preload(tasks,
      image_links: :attachment,
      node: [:logo, user: :avatar],
      creator: :avatar,
      assignee: :avatar,
      applications: [],
      events: from(e in Event, where: e.to_status == "open", order_by: [asc: e.id])
    )
  end

  defp preload_detail(task) do
    Repo.preload(task,
      image_links: :attachment,
      node: [:logo, user: :avatar],
      creator: :avatar,
      assignee: :avatar,
      applications: [user: :avatar],
      submissions: [user: :avatar],
      events: from(e in Event, order_by: [asc: e.id], preload: [actor: :avatar])
    )
  end
end

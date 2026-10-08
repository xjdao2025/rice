defmodule Rice.Tasks do
  @moduledoc """
  节点任务：草稿、发布、申请、接收、交付与验收，每个名额独立结算。

  管理员代表节点发布，由节点账户出资；历史任务保留原出资账户。
  """
  import Ecto.Query

  alias Ecto.Multi
  alias Rice.Accounts.User
  alias Rice.Tasks.{Application, ApplicationState, Event, Notification, Submission, Task}
  alias Rice.{Grains, Pagination, Repo}

  # 仍占着名额的申请状态。被撤销指派(released)的人留着 appointed_at,
  # 所以"算不算承接者"一律按状态判断,不看 appointed_at。
  @appointed ApplicationState.appointed_states()

  @overdue_detail "交付已超时，仍可提交成果"
  @public_visibility_grace_seconds 24 * 60 * 60

  def list_tasks(user, params \\ %{}) do
    query =
      from(t in Task, as: :task)
      |> scope_visibility(user, params["mine"])
      |> filter_status(params["status"], user, params["mine"])
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

  def appointed_applications(task) do
    task
    |> Repo.preload(:applications)
    |> Map.fetch!(:applications)
    |> Enum.filter(
      &(&1.round == task.round and
          (ApplicationState.appointed?(&1.status) or &1.user_id == task.assignee_id))
    )
  end

  def appointed?(_task, nil), do: false

  def appointed?(task, user),
    do:
      task.assignee_id == user.id or
        Enum.any?(appointed_applications(task), &(&1.user_id == user.id))

  def my_status(task, user, now \\ DateTime.utc_now()) do
    application =
      if is_struct(user, User) and task.capacity > 1 and
           task.status not in ~w(draft completed expired cancelled),
         do: Enum.find(appointed_applications(task), &(&1.user_id == user.id))

    if application, do: application_progress(task, application, now), else: task.status
  end

  # 申请状态 → 任务口径的状态。appointed / overdue 以交付截止为准实时判断,
  # 落库的 overdue 由定时任务和 refresh_overdue 追平,编辑延期时立即生效。
  defp application_progress(task, %Application{status: status}, now) do
    case status do
      "completed" -> "completed"
      "under_review" -> "under_review"
      _ -> if(execution_overdue?(task, now), do: "overdue", else: "in_progress")
    end
  end

  def accepting_applications?(task) do
    task.status in ~w(open in_progress overdue under_review) and
      not application_deadline_reached?(task) and
      (task.status == "open" or task.capacity > 1) and
      length(appointed_applications(task)) < task.capacity
  end

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
            reserve_task_reward(repo, task)
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
             {:ok, changeset} <- aggregate_edited_task(task, changeset, user.id),
             {:ok, saved} <- Repo.update(changeset),
             :ok <- sync_after_edit(task, saved) do
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
      error -> error
    end
  end

  defp validate_active_terms_edit(changeset, %Task{status: status})
       when status in ~w(open in_progress overdue under_review) do
    changeset =
      if Ecto.Changeset.changed?(changeset, :reward_amount),
        do: Ecto.Changeset.add_error(changeset, :reward_amount, "已发布任务不能修改任务奖励"),
        else: changeset

    changeset =
      if Ecto.Changeset.changed?(changeset, :capacity),
        do: Ecto.Changeset.add_error(changeset, :capacity, "已发布任务不能修改领取人数"),
        else: changeset

    if Ecto.Changeset.changed?(changeset, :node_id),
      do: Ecto.Changeset.add_error(changeset, :node_id, "已发布任务不能修改所属节点"),
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

  defp previous_application_status(_task, %Application{status: status})
       when status in @appointed,
       do: "appointed"

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

  defp previous_submission_status(_task, %Submission{final_status: status})
       when not is_nil(status),
       do: status

  defp previous_submission_status(_task, %Submission{review_reason: reason})
       when not is_nil(reason),
       do: "changes_requested"

  defp previous_submission_status(_task, _submission), do: "pending"

  defp aggregate_edited_task(%Task{capacity: capacity, status: status}, changeset, actor_id)
       when capacity > 1 and status in ~w(in_progress overdue under_review) do
    current = changeset |> Ecto.Changeset.apply_changes() |> preload_detail()
    {next, unused} = aggregate_multi_status(current, DateTime.utc_now())

    with {:ok, _} <-
           if(next == "completed",
             do: refund_reward_slots(Repo, current, unused),
             else: {:ok, nil}
           ),
         :ok <- notify_closed_applications(current, actor_id, DateTime.utc_now()) do
      changeset = Ecto.Changeset.put_change(changeset, :status, next)

      {:ok,
       if(next == "completed" and current.reward_amount > 0,
         do: Ecto.Changeset.put_change(changeset, :reward_status, "settled"),
         else: changeset
       )}
    end
  end

  defp aggregate_edited_task(_task, changeset, _actor_id), do: {:ok, changeset}

  defp maybe_notify_edited_due(
         old,
         %Task{capacity: capacity} = saved,
         actor_id,
         _expiring?,
         _overdue?
       )
       when capacity > 1 and old.status != "open" do
    if saved.status == "overdue" and old.status != "overdue",
      do: notify_overdue(preload_detail(saved), actor_id, DateTime.utc_now()),
      else: :ok
  end

  defp maybe_notify_edited_due(_old, _saved, _actor_id, false, false), do: :ok

  defp maybe_notify_edited_due(old, saved, actor_id, expiring?, overdue?) do
    recipients =
      cond do
        expiring? ->
          Enum.map(applicant_ids(Repo, old), &{&1, "task_expired", "申请已截止"})

        overdue? ->
          Enum.map(appointed_applications(old), &{&1.user_id, "task_overdue", @overdue_detail})
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
    with {:ok, subject} <-
           maybe_reserve_edited_reward(
             task,
             amount,
             node_id,
             Ecto.Changeset.get_field(changeset, :capacity)
           ) do
      {:ok,
       changeset
       |> Ecto.Changeset.put_change(:funding_node_id, node_id)
       |> Ecto.Changeset.put_change(:reward_status, if(amount > 0, do: "reserved", else: "none"))
       |> Ecto.Changeset.put_change(:reward_subject_uri, subject)}
    end
  end

  defp maybe_refund_edited_reward(%Task{reward_status: "reserved", reward_amount: amount} = task)
       when amount > 0,
       do: refund_task_reward(Repo, task)

  defp maybe_refund_edited_reward(_task), do: {:ok, nil}

  defp maybe_reserve_edited_reward(_task, 0, _node_id, _capacity), do: {:ok, nil}

  defp maybe_reserve_edited_reward(task, amount, node_id, capacity) do
    subject = "rice://tasks/#{task.id}/edits/#{Rice.Tsid.generate()}"

    case reserve_task_reward(Repo, %{
           task
           | funding_node_id: node_id,
             reward_amount: amount,
             capacity: capacity,
             reward_subject_uri: subject
         }) do
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
      "capacity" => task.capacity,
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

  def apply(%User{} = user, %Task{status: status} = task, attrs)
      when status in ~w(open in_progress overdue under_review) do
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
      |> Multi.run(:application_event, fn repo,
                                          %{task: current_task, existing_application: existing} ->
        if existing,
          do: {:ok, :already_applied},
          else:
            repo.insert(
              event_changeset(
                task.id,
                user.id,
                current_task.status,
                current_task.status,
                "收到任务申请"
              )
            )
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
         %Task{} = task,
         %Application{} = application
       ) do
    cond do
      not accepting_applications?(task) or not is_nil(application.appointed_at) ->
        {:error, :conflict}

      application.rejected_at ->
        {:ok, preload_detail(task)}

      true ->
        with {:ok, [_]} <-
               move_applications(
                 Repo,
                 from(a in Application, where: a.id == ^application.id),
                 "rejected",
                 rejected_at: DateTime.utc_now()
               ),
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
        else
          {:ok, _} -> {:error, :conflict}
          error -> error
        end
    end
  end

  defp reject_current_application(%User{}, %Task{}, _application), do: {:error, :conflict}

  defp appoint_application(
         %User{} = user,
         %Task{capacity: capacity} = task,
         %Application{} = application,
         attrs
       )
       when capacity > 1 do
    changeset = Task.appointment_changeset(task, attrs)
    appointed = appointed_applications(task)

    cond do
      ApplicationState.appointed?(application.status) ->
        {:ok, preload_detail(task)}

      task.status not in ~w(open in_progress overdue under_review) ->
        {:error, :conflict}

      length(appointed) >= capacity ->
        {:error, :capacity_full}

      # released / rejected / cancelled 等都不能再指派
      application.status != "pending" or application_deadline_reached?(task) ->
        {:error, :conflict}

      not changeset.valid? ->
        {:error, changeset}

      true ->
        reason = Ecto.Changeset.get_field(changeset, :appointment_reason)

        with {:ok, [_]} <-
               move_applications(
                 Repo,
                 from(a in Application, where: a.id == ^application.id),
                 "appointed",
                 appointed_at: DateTime.utc_now(),
                 appointment_reason: reason,
                 reward_slot: next_reward_slot(task, appointed)
               ),
             {:ok, _} <-
               Repo.insert(
                 notification_changeset(
                   task,
                   application.user_id,
                   user.id,
                   "assignee_appointed",
                   reason
                 )
               ),
             {:ok, updated} <- update_multi_status(task, user.id, reason) do
          {:ok, updated}
        else
          {:ok, _} -> {:error, :conflict}
          error -> error
        end
    end
  end

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

        appointed_at = DateTime.utc_now()

        with {:ok, [_]} <-
               move_applications(
                 Repo,
                 from(a in Application, where: a.id == ^application.id),
                 "appointed",
                 appointed_at: appointed_at,
                 appointment_reason: appointment_reason
               ),
             {:ok, _} <- move_applications(Repo, round_applications(task), "not_selected") do
          transition_task(
            from(t in Task, where: t.id == ^task.id and t.status == "open"),
            task,
            [
              status: "in_progress",
              assignee_id: application.user_id,
              appointed_at: appointed_at,
              appointment_reason: appointment_reason
            ],
            creator_id,
            appointment_reason,
            notifications
          )
        else
          {:ok, _} -> {:error, :conflict}
        end
    end
  end

  defp appoint_application(%User{}, %Task{}, %Application{}, _attrs), do: {:error, :conflict}

  # 被撤销指派的人让出名额,编号(以及那份冻结)留给下一个被指派的人。
  defp next_reward_slot(task, appointed) do
    used = Enum.map(appointed, & &1.reward_slot)
    Enum.find(1..task.capacity, &(&1 not in used))
  end

  @doc """
  多人任务:撤销一个人的指派。名额让出来,奖励不发;对方已提交、等待验收时不能撤,
  要先验收或退回修改。没有人在承作时任务回到 `open`。
  """
  def release_assignee(user, %Task{} = task, application_id, attrs \\ %{}) do
    with_locked_task(task.id, fn current ->
      with :ok <- authorize_management(current, user),
           {:ok, application} <- fetch_record(Application, current, application_id) do
        release_current_assignee(user, current, application, attrs)
      end
    end)
  end

  defp release_current_assignee(
         %User{} = user,
         %Task{capacity: capacity, status: status} = task,
         %Application{} = application,
         attrs
       )
       when capacity > 1 and status in ~w(in_progress overdue under_review) do
    reason = release_reason(attrs)

    with true <- application.status in ~w(appointed overdue) or {:error, :conflict},
         {:ok, [_]} <-
           move_applications(
             Repo,
             from(a in Application, where: a.id == ^application.id),
             "released",
             reward_slot: nil
           ),
         {:ok, _} <-
           Repo.insert(
             notification_changeset(
               task,
               application.user_id,
               user.id,
               "appointment_released",
               reason
             )
           ),
         {:ok, updated} <- update_multi_status(task, user.id, reason) do
      {:ok, updated}
    else
      {:ok, _} -> {:error, :conflict}
      error -> error
    end
  end

  defp release_current_assignee(%User{}, %Task{}, %Application{}, _attrs),
    do: {:error, :conflict}

  defp release_reason(attrs) do
    case attrs["reason"] || attrs[:reason] do
      reason when is_binary(reason) -> String.slice(String.trim(reason), 0, 512)
      _ -> nil
    end
    |> case do
      "" -> nil
      reason -> reason
    end
  end

  @doc """
  多人任务:提前结束。还在承作的人撤销指派,待处理的申请落选,没发出去的奖励退回节点。
  有人已通过验收就记为 `completed`,一个都没有则记为 `cancelled`。
  有成果等待验收时不能结束,要先验收或退回修改。
  """
  def close(user, %Task{} = task) do
    with_locked_task(task.id, fn current ->
      with :ok <- authorize_management(current, user), do: close_current(user, current)
    end)
  end

  defp close_current(%User{id: actor_id}, %Task{capacity: capacity, status: status} = task)
       when capacity > 1 and status in ~w(in_progress overdue under_review) do
    scope = round_applications(task)

    if Repo.exists?(from(a in scope, where: a.status == "under_review")) do
      {:error, :conflict}
    else
      completed_slots =
        Repo.all(from(a in scope, where: a.status == "completed", select: a.reward_slot))

      next = if completed_slots == [], do: "cancelled", else: "completed"
      unused = Enum.to_list(1..task.capacity) -- completed_slots

      reward_status =
        cond do
          task.reward_amount == 0 or task.reward_status != "reserved" -> task.reward_status
          next == "completed" -> "settled"
          true -> "refunded"
        end

      detail =
        if task.reward_amount > 0 and unused != [],
          do: "已提前结束，向节点退回 #{task.reward_amount * length(unused)} 稻米",
          else: "已提前结束"

      with {:ok, released} <- move_applications(Repo, scope, "released", reward_slot: nil),
           {:ok, not_selected} <- move_applications(Repo, scope, "not_selected"),
           {:ok, _} <- refund_reward_slots(Repo, task, unused),
           {:ok, saved} <-
             Repo.update(Ecto.Changeset.change(task, status: next, reward_status: reward_status)),
           {:ok, _} <- Repo.insert(event_changeset(task.id, actor_id, task.status, next, detail)),
           :ok <-
             notify_each(task, actor_id, [
               {released, "appointment_released", detail},
               {not_selected, "application_not_selected", nil}
             ]) do
        {:ok, preload_detail(saved)}
      end
    end
  end

  defp close_current(%User{}, %Task{}), do: {:error, :conflict}

  defp notify_each(task, actor_id, groups) do
    groups
    |> Enum.flat_map(fn {user_ids, event, detail} -> Enum.map(user_ids, &{&1, event, detail}) end)
    |> Enum.reduce_while(:ok, fn {user_id, event, detail}, _ ->
      case Repo.insert(notification_changeset(task, user_id, actor_id, event, detail)) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def submit_result(user, %Task{} = task, attrs),
    do: with_locked_task(task.id, &submit_current_result(user, &1, attrs))

  defp submit_current_result(
         %User{} = user,
         %Task{capacity: capacity} = task,
         attrs
       )
       when capacity > 1 do
    cond do
      not appointed?(task, user) ->
        {:error, :forbidden}

      task.status not in ~w(in_progress overdue under_review) ->
        {:error, :conflict}

      my_status(task, user) not in ~w(in_progress overdue) ->
        {:error, :conflict}

      true ->
        changeset =
          Submission.create_changeset(
            %Submission{task_id: task.id, round: task.round, user_id: user.id},
            attrs
          )

        with {:ok, _} <- Repo.insert(changeset),
             {:ok, [_]} <-
               move_applications(Repo, user_application(task, user.id), "under_review"),
             {:ok, updated} <- update_multi_status(task, user.id),
             :ok <- notify_managers(task, user.id, "result_submitted") do
          {:ok, updated}
        else
          {:ok, _} -> {:error, :conflict}
          error -> error
        end
    end
  end

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
    |> Multi.run(:applications, fn repo, _ ->
      sync_applications(repo, task, "under_review")
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
      # 被指派后才升成节点管理员的人,不能自己给自己验收发奖
      with :ok <- authorize_management(current_task, user),
           {:ok, submission} <- fetch_record(Submission, current_task, submission_id),
           :ok <- if(submission.user_id == user.id, do: {:error, :forbidden}, else: :ok) do
        approve_submission(user, current_task, submission)
      end
    end)
  end

  defp approve_submission(
         %User{} = user,
         %Task{capacity: capacity} = task,
         %Submission{} = submission
       )
       when capacity > 1 do
    case latest_submission(task, submission.user_id) do
      %Submission{id: id, final_status: "approved"} when id == submission.id ->
        {:ok, preload_detail(task)}

      %Submission{id: id, review_reason: nil, final_status: nil} when id == submission.id ->
        application = Enum.find(appointed_applications(task), &(&1.user_id == submission.user_id))

        if application && task.status in ~w(in_progress overdue under_review) do
          with {:ok, _} <- settle_application_reward(task, application),
               {:ok, [_]} <-
                 move_applications(Repo, user_application(task, submission.user_id), "completed"),
               {:ok, _} <-
                 Repo.update(Ecto.Changeset.change(submission, final_status: "approved")),
               {:ok, updated} <- update_multi_status(task, user.id),
               {:ok, _} <-
                 Repo.insert(
                   notification_changeset(
                     task,
                     submission.user_id,
                     user.id,
                     "result_approved",
                     reward_detail(task, :settled)
                   )
                 ) do
            {:ok, updated}
          else
            {:ok, _} -> {:error, :conflict}
            error -> error
          end
        else
          {:error, :conflict}
        end

      _ ->
        {:error, :conflict}
    end
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
         %User{} = user,
         %Task{capacity: capacity} = task,
         %Submission{} = submission,
         reason
       )
       when capacity > 1 and is_binary(reason) do
    case latest_submission(task, submission.user_id) do
      %Submission{id: id, review_reason: nil, final_status: nil} when id == submission.id ->
        with true <- task.status in ~w(in_progress overdue under_review) or {:error, :conflict},
             {:ok, _} <- Repo.update(Submission.review_changeset(submission, reason)),
             {:ok, [_]} <-
               move_applications(Repo, user_application(task, submission.user_id), "appointed"),
             {:ok, updated} <- update_multi_status(task, user.id, reason),
             {:ok, _} <-
               Repo.insert(
                 notification_changeset(
                   task,
                   submission.user_id,
                   user.id,
                   "changes_requested",
                   reason
                 )
               ) do
          {:ok, updated}
        else
          {:ok, _} -> {:error, :conflict}
          error -> error
        end

      _ ->
        {:error, :conflict}
    end
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
      |> Multi.run(:applications, fn repo, _ ->
        sync_applications(repo, task, next_status)
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
    # 多人任务过了截止仍留在进行中,只在还有事可做时才拿出来:申请截止后还有待处理的申请、
    # 或者所有承作人都已结束(该收尾了);交付截止后还有人没记成超期。
    pending_exists =
      from(a in Application,
        where: a.task_id == parent_as(:task).id and a.round == parent_as(:task).round,
        where: a.status == "pending"
      )

    working_exists =
      from(a in Application,
        where: a.task_id == parent_as(:task).id and a.round == parent_as(:task).round,
        where: a.status in ["appointed", "overdue", "under_review"]
      )

    not_yet_overdue_exists =
      from(a in Application,
        where: a.task_id == parent_as(:task).id and a.round == parent_as(:task).round,
        where: a.status == "appointed"
      )

    due =
      from(t in Task,
        as: :task,
        where:
          (t.status == "open" and t.application_deadline <= ^now) or
            (t.status == "in_progress" and t.capacity == 1 and t.execution_deadline <= ^now) or
            (t.capacity > 1 and t.status in ["in_progress", "overdue", "under_review"] and
               ((t.application_deadline <= ^now and
                   (exists(pending_exists) or not exists(working_exists))) or
                  (t.execution_deadline <= ^now and exists(not_yet_overdue_exists))))
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
              case transition_due_task(task, now) do
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

  defp transition_due_task(%Task{capacity: capacity, status: status} = task, now)
       when capacity > 1 and status in ~w(in_progress overdue under_review) do
    update_multi_status(task, nil, nil, now)
  end

  defp transition_due_task(%Task{status: "open"} = task, _now) do
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

  defp transition_due_task(%Task{status: "in_progress"} = task, _now) do
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

  defp filter_status(query, status, %User{id: user_id}, mine)
       when mine in ~w(assigned applied) and
              status in ~w(in_progress overdue under_review completed) do
    latest =
      from s in Submission,
        group_by: [s.task_id, s.round, s.user_id],
        select: %{task_id: s.task_id, round: s.round, user_id: s.user_id, id: max(s.id)}

    now = DateTime.utc_now()

    from(t in query,
      left_join: a in Application,
      on: a.task_id == t.id and a.round == t.round and a.user_id == ^user_id,
      left_join: l in subquery(latest),
      on: l.task_id == t.id and l.round == t.round and l.user_id == ^user_id,
      left_join: s in Submission,
      on: s.id == l.id,
      where:
        fragment(
          "CASE WHEN ? = 1 OR ? IN ('draft', 'completed', 'expired', 'cancelled') OR ? IS NULL THEN ? WHEN ? = 'approved' THEN 'completed' WHEN ? IS NOT NULL AND ? IS NULL THEN 'under_review' WHEN ? <= ? THEN 'overdue' ELSE 'in_progress' END",
          t.capacity,
          t.status,
          a.appointed_at,
          t.status,
          s.final_status,
          s.id,
          s.review_reason,
          t.execution_deadline,
          ^now
        ) == ^status
    )
  end

  defp filter_status(query, status, _user, _mine)
       when status in ~w(draft open in_progress overdue under_review completed expired cancelled),
       do: from(t in query, where: t.status == ^status)

  defp filter_status(query, "closed", _user, _mine),
    do: from(t in query, where: t.status in ["expired", "cancelled"])

  defp filter_status(query, _status, _user, _mine), do: query

  defp filter_query(query, value) when is_binary(value) and value != "" do
    pattern = Repo.contains(value)
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
        (t.status == "open" or
           (t.capacity > 1 and t.status in ["in_progress", "overdue", "under_review"])) and
          fragment(
            "(SELECT count(*) FROM task_applications a WHERE a.task_id = ? AND a.round = ? AND a.status = ANY(?))",
            t.id,
            t.round,
            ^@appointed
          ) < t.capacity and t.creator_id != ^id and
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
    appointed =
      from(a in Application,
        join: user in User,
        on: user.id == a.user_id,
        where: a.task_id == parent_as(:task).id and a.status in ^@appointed and user.did == ^did,
        select: 1
      )

    from(t in query,
      left_join: user in User,
      on: user.id == t.assignee_id,
      where: user.did == ^did or exists(appointed)
    )
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
            (a.final_status == "appointed" or a.status in ^@appointed),
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

    appointed =
      from(a in Application,
        where:
          a.task_id == parent_as(:task).id and a.round == parent_as(:task).round and
            a.user_id == ^id and a.status in ^@appointed,
        select: 1
      )

    from(t in query,
      where:
        exists(application) and (is_nil(t.assignee_id) or t.assignee_id != ^id) and
          not exists(appointed)
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
      |> Multi.run(:applications, fn repo, _ ->
        sync_applications(repo, task, Keyword.fetch!(updates, :status))
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
        reserve_task_reward(repo, task)
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
        refund_task_reward(repo, task)
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
  defp reward_subject(task, slot), do: "#{reward_subject(task)}/slots/#{slot}"

  defp reserve_task_reward(repo, %Task{capacity: 1} = task),
    do:
      Grains.reserve_business(
        repo,
        reward_account(task),
        task.reward_amount,
        reward_subject(task)
      )

  defp reserve_task_reward(repo, task) do
    Enum.reduce_while(1..task.capacity, {:ok, nil}, fn slot, _ ->
      case Grains.reserve_business(
             repo,
             reward_account(task),
             task.reward_amount,
             reward_subject(task, slot)
           ) do
        {:ok, receipt} -> {:cont, {:ok, receipt}}
        error -> {:halt, error}
      end
    end)
  end

  defp refund_task_reward(repo, %Task{capacity: 1} = task),
    do:
      Grains.refund_business(repo, reward_account(task), task.reward_amount, reward_subject(task))

  defp refund_task_reward(repo, task),
    do: refund_reward_slots(repo, task, Enum.to_list(1..task.capacity))

  defp refund_reward_slots(_repo, %Task{reward_amount: 0}, _slots), do: {:ok, nil}

  defp refund_reward_slots(repo, task, slots) do
    Enum.reduce_while(slots, {:ok, nil}, fn slot, _ ->
      case Grains.refund_business(
             repo,
             reward_account(task),
             task.reward_amount,
             reward_subject(task, slot)
           ) do
        {:ok, receipt} -> {:cont, {:ok, receipt}}
        error -> {:halt, error}
      end
    end)
  end

  defp settle_application_reward(%Task{reward_amount: 0}, _application), do: {:ok, nil}

  defp settle_application_reward(task, application),
    do:
      Grains.settle_business(
        Repo,
        reward_account(task),
        application.user_id,
        task.reward_amount,
        reward_subject(task, application.reward_slot)
      )

  defp latest_submission(task, user_id) do
    task
    |> Repo.preload(:submissions)
    |> Map.fetch!(:submissions)
    |> Enum.filter(&(&1.round == task.round and &1.user_id == user_id))
    |> Enum.max_by(& &1.id, fn -> nil end)
  end

  defp execution_overdue?(task, now) do
    task.execution_deadline && DateTime.compare(task.execution_deadline, now) != :gt
  end

  defp aggregate_multi_status(task, now) do
    appointed = appointed_applications(task)
    statuses = Enum.map(appointed, &application_progress(task, &1, now))

    application_closed? =
      not is_nil(task.application_deadline) and
        DateTime.compare(task.application_deadline, now) != :gt

    complete? =
      Enum.all?(statuses, &(&1 == "completed")) and
        (length(appointed) == task.capacity or application_closed?)

    next =
      cond do
        # 承作的人都被撤销了:回到招募中,再没人接就由定时任务按申请截止处理
        appointed == [] -> "open"
        complete? -> "completed"
        "overdue" in statuses -> "overdue"
        "under_review" in statuses -> "under_review"
        true -> "in_progress"
      end

    {next, Enum.to_list(1..task.capacity) -- Enum.map(appointed, & &1.reward_slot)}
  end

  defp update_multi_status(task, actor_id, detail \\ nil, now \\ DateTime.utc_now()) do
    {:ok, _} = refresh_overdue(Repo, task, now)
    current = preload_detail(task)
    {next, unused} = aggregate_multi_status(current, now)

    # 撤销指派让出了名额:之前因名额满而落选的申请重新排队
    if accepting_applications?(current),
      do: {:ok, _} = move_applications(Repo, round_applications(current), "pending")

    with :ok <- notify_closed_applications(current, actor_id || task.creator_id, now) do
      if next == task.status and is_nil(actor_id) do
        {:ok, current}
      else
        with {:ok, _} <-
               if(next == "completed",
                 do: refund_reward_slots(Repo, task, unused),
                 else: {:ok, nil}
               ),
             {:ok, saved} <-
               Repo.update(
                 Ecto.Changeset.change(task,
                   status: next,
                   reward_status:
                     if(next == "completed" and task.reward_amount > 0,
                       do: "settled",
                       else: task.reward_status
                     )
                 )
               ),
             {:ok, _} <-
               Repo.insert(event_changeset(task.id, actor_id, task.status, next, detail)),
             :ok <-
               if(next == "overdue" and task.status != "overdue",
                 do: notify_overdue(current, actor_id, now),
                 else: :ok
               ) do
          {:ok, preload_detail(saved)}
        end
      end
    end
  end

  defp notify_closed_applications(task, actor_id, now) do
    closed? =
      length(appointed_applications(task)) >= task.capacity or
        (not is_nil(task.application_deadline) and
           DateTime.compare(task.application_deadline, now) != :gt)

    if closed? do
      # pending -> not_selected 只会发生一次,通知跟着迁移走,不需要再查通知表去重。
      {:ok, user_ids} = move_applications(Repo, round_applications(task), "not_selected")

      Enum.reduce_while(user_ids, :ok, fn user_id, _ ->
        case Repo.insert(
               notification_changeset(task, user_id, actor_id, "application_not_selected")
             ) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    else
      :ok
    end
  end

  defp notify_managers(task, actor_id, event) do
    Enum.reduce_while(manager_ids(task), :ok, fn id, _ ->
      case Repo.insert(notification_changeset(task, id, actor_id, event)) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp notify_overdue(task, actor_id, now) do
    Enum.reduce_while(appointed_applications(task), :ok, fn application, _ ->
      if my_status(task, application.user, now) == "overdue" do
        case Repo.insert(
               notification_changeset(
                 task,
                 application.user_id,
                 actor_id || task.creator_id,
                 "task_overdue",
                 @overdue_detail
               )
             ) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      else
        {:cont, :ok}
      end
    end)
  end

  defp reward_detail(%Task{reward_amount: amount} = task, action) when amount > 0 do
    case action do
      :reserved ->
        "已冻结 #{amount * task.capacity} 稻米作为任务奖励"

      :settled ->
        "已向承作人发放 #{amount} 稻米"

      :refunded ->
        "已向#{if(task.funding_node_id, do: "节点", else: "发布者")}退回 #{amount * task.capacity} 稻米"
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
          t.id == ^task_id and
            (t.status == "open" or
               (t.capacity > 1 and t.status in ["in_progress", "overdue", "under_review"])) and
            (is_nil(t.application_deadline) or t.application_deadline > ^now),
        lock: "FOR UPDATE"
      )

    case repo.one(query) do
      nil -> {:error, :conflict}
      task -> if(accepting_applications?(task), do: {:ok, task}, else: {:error, :capacity_full})
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
      applications: [user: :avatar],
      submissions: [],
      events: from(e in Event, where: e.to_status == "open", order_by: [asc: e.id])
    )
  end

  # 编辑可能改变任务状态(过期 / 超期 / 延期恢复)或申请是否还开放,申请状态要跟上。
  defp sync_after_edit(%Task{} = old, %Task{} = saved) do
    now = DateTime.utc_now()

    result =
      cond do
        saved.capacity > 1 and saved.status in ~w(in_progress overdue under_review) ->
          with {:ok, _} <- refresh_overdue(Repo, saved, now) do
            if accepting_applications?(saved),
              do: move_applications(Repo, round_applications(saved), "pending"),
              else: {:ok, []}
          end

        old.status != saved.status ->
          sync_applications(Repo, old, saved.status)

        true ->
          {:ok, []}
      end

    with {:ok, _} <- result, do: :ok
  end

  defp round_applications(%Task{id: id, round: round}),
    do: from(a in Application, where: a.task_id == ^id and a.round == ^round)

  defp user_application(%Task{} = task, user_id),
    do: from(a in round_applications(task), where: a.user_id == ^user_id)

  @doc false
  # 申请状态机的唯一入口:只放行 ApplicationState 里允许的迁移,返回真正迁移了的 user_id。
  def move_applications(repo, scope, to, extra \\ []) do
    sources = ApplicationState.sources(to)
    query = from(a in scope, where: a.status in ^sources, select: a.user_id)
    set = [status: to, updated_at: DateTime.utc_now()] ++ extra
    {_count, user_ids} = repo.update_all(query, set: set)
    {:ok, user_ids}
  end

  # 任务状态变化时,同步单人任务那一个承接申请(多人任务按人逐个迁移,不走这里)。
  defp sync_applications(repo, %Task{} = task, to) do
    scope = round_applications(task)

    result =
      case {task.capacity, task.status, to} do
        {_, from, "cancelled"} when from in ~w(open draft) ->
          move_applications(repo, scope, "cancelled")

        {_, "open", "expired"} ->
          move_applications(repo, scope, "expired")

        {1, _, to}
        when not is_nil(task.assignee_id) and to in ~w(overdue under_review completed) ->
          move_applications(repo, user_application(task, task.assignee_id), to)

        {1, from, "in_progress"}
        when from in ~w(under_review overdue) and not is_nil(task.assignee_id) ->
          move_applications(repo, user_application(task, task.assignee_id), "appointed")

        _ ->
          {:ok, []}
      end

    with {:ok, _} <- result, do: {:ok, :synced}
  end

  # 多人任务:交付截止已过 → appointed 记为 overdue;截止被延后 → overdue 回到 appointed。
  defp refresh_overdue(repo, %Task{} = task, now) do
    scope = round_applications(task)

    if execution_overdue?(task, now),
      do: move_applications(repo, from(a in scope, where: a.status == "appointed"), "overdue"),
      else: move_applications(repo, from(a in scope, where: a.status == "overdue"), "appointed")
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

defmodule Rice.Tasks do
  @moduledoc """
  节点任务：草稿、发布、申请、接收、交付与验收，每个名额独立结算。

  节点管理员代表节点发布，由节点账户出资；没有可管节点、但有 `can_publish_tasks`
  的人以个人名义发布，由自己的余额出资。单人任务就是只有一个名额的多人任务，
  两者剩下的差别见 docs/tasks.md。
  """
  import Ecto.Query

  alias Ecto.Multi
  alias Rice.Accounts.User
  alias Rice.Tasks.{Application, ApplicationState, Event, Notification, Submission, Task}
  alias Rice.{Grains, Pagination, Repo}

  @type error ::
          :not_found | :forbidden | :conflict | :grain_reservation_missing | Ecto.Changeset.t()

  # 仍占着名额的申请状态。被撤销指派(released)的人留着 appointed_at,
  # 所以"算不算承接者"一律按状态判断,不看 appointed_at。
  @appointed ApplicationState.appointed_states()
  @running ~w(in_progress overdue under_review)

  @overdue_detail "交付已超时，仍可提交成果"
  @public_visibility_grace_seconds 24 * 60 * 60

  @frozen_terms [
    reward_amount: "已发布任务不能修改任务奖励",
    capacity: "已发布任务不能修改领取人数",
    node_id: "已发布任务不能修改所属节点"
  ]

  @spec list_tasks(User.t() | nil, map()) :: Pagination.page(Task.t())
  def list_tasks(user, params \\ %{}) do
    query =
      from(t in Task, as: :task)
      |> scope_visibility(user, params["mine"])
      |> filter_status(params["status"], user, params["mine"])
      |> filter_query(params["q"])
      |> filter_node(params["node_id"])
      |> filter_available(user, params["available"])
      |> scope_participant(params["participant_did"])
      |> scope_creator(params["creator_did"])
      |> scope_mine(user, params["mine"])

    page = paginate_tasks(query, params)

    %{page | entries: preload_list(page.entries)}
  end

  @spec fetch_task(String.t(), User.t() | nil) :: {:ok, Task.t()} | {:error, :not_found}
  def fetch_task(id, user \\ nil) do
    with {:ok, task} <- fetch_task_record(id) do
      if visible_to?(task, user), do: {:ok, task}, else: {:error, :not_found}
    end
  end

  defp fetch_task_record(id) do
    with true <- Rice.Tsid.valid?(id),
         %Task{} = task <- Repo.get(Task, id) do
      {:ok, preload_detail(task)}
    else
      _ -> {:error, :not_found}
    end
  end

  @spec create_task(User.t(), map()) ::
          {:ok, Task.t()}
          | {:error,
             :forbidden
             | :unprocessable_entity
             | :conflict
             | :insufficient_balance
             | Ecto.Changeset.t()}
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

  @spec can_manage?(Task.t(), User.t() | nil) :: boolean()
  def can_manage?(_task, nil), do: false

  def can_manage?(%Task{status: "draft", creator_id: id} = task, user),
    do: id == user.id and (is_nil(task.node_id) or Rice.Community.admin?(node_of(task), user))

  def can_manage?(%Task{funding_node_id: nil, creator_id: id}, %User{id: user_id}),
    do: id == user_id

  def can_manage?(task, user), do: Rice.Community.admin?(node_of(task), user)

  defp authorize_management(task, user),
    do: if(can_manage?(task, user), do: :ok, else: {:error, :forbidden})

  @spec can_edit?(Task.t(), User.t() | nil) :: boolean()
  def can_edit?(%Task{status: "draft"} = task, user), do: can_manage?(task, user)
  def can_edit?(%Task{funding_node_id: nil} = task, user), do: can_manage?(task, user)

  def can_edit?(%Task{} = task, %User{} = user), do: Rice.Community.admin?(node_of(task), user)
  def can_edit?(_, _), do: false

  # 渲染时任务带着预加载的节点和管理员名单;写操作拿的是加锁新读的任务,没有预加载,
  # 走查询 —— 刚被撤掉的管理员不会因为旧数据还能操作
  defp node_of(%Task{node: %Rice.Community.Node{} = node}), do: node
  defp node_of(%Task{node_id: id}), do: id && Repo.get(Rice.Community.Node, id)

  @spec appointed_applications(Task.t()) :: [Application.t()]
  def appointed_applications(task) do
    task
    |> Repo.preload(:applications)
    |> Map.fetch!(:applications)
    |> Enum.filter(
      &(&1.round == task.round and
          (ApplicationState.appointed?(&1.status) or &1.user_id == task.assignee_id))
    )
  end

  @spec appointed?(Task.t(), User.t() | nil) :: boolean()
  def appointed?(_task, nil), do: false

  def appointed?(task, user),
    do:
      task.assignee_id == user.id or
        Enum.any?(appointed_applications(task), &(&1.user_id == user.id))

  # 单人任务的个人状态就是任务状态;多人任务每人各自流转
  @spec my_status(Task.t(), User.t() | nil, DateTime.t()) :: String.t()
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

  @spec accepting_applications?(Task.t()) :: boolean()
  def accepting_applications?(task) do
    recruiting?(task) and not application_deadline_reached?(task) and
      length(appointed_applications(task)) < task.capacity
  end

  # 单人任务只在 open 时招人;多人任务进行中名额没满也继续招
  defp recruiting?(task),
    do: task.status == "open" or (task.capacity > 1 and task.status in @running)

  # 发任务的资格是"或":节点管理员用节点的稻米;没有可管节点、但平台给了
  # `can_publish_tasks` 的人用自己的稻米(返回 nil 节点,即个人出资)。
  defp publishing_node(user, nil) do
    ids = Rice.Community.managed_node_ids(user)

    case Repo.all(from n in Rice.Community.Node, where: n.id in ^ids, limit: 2) do
      [node] -> {:ok, node}
      [] -> personal_publisher(user)
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

  defp personal_publisher(user) do
    if Repo.get!(User, user.id).can_publish_tasks, do: {:ok, nil}, else: {:error, :forbidden}
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
        %Task{
          creator_id: user.id,
          node_id: node && node.id,
          funding_node_id: node && node.id,
          status: status
        }
        |> Task.create_changeset(attrs)

      reserve? =
        status == "open" and (Ecto.Changeset.get_field(task_changeset, :reward_amount) || 0) > 0

      task_changeset =
        Ecto.Changeset.put_change(
          task_changeset,
          :reward_status,
          if(reserve?, do: "reserved", else: "none")
        )

      Multi.new()
      |> Multi.insert(:task, task_changeset)
      |> maybe_run_reward(if reserve?, do: &reserve_task_reward(&1, &2.task))
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

  @spec update_task(User.t(), Task.t(), map()) ::
          {:ok, Task.t()} | {:error, error() | :insufficient_balance}
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
             {:error, :conflict},
         attrs = Map.drop(attrs, ["client_request_id", :client_request_id]),
         task = Repo.preload(task, :image_links),
         node_id = attrs["node_id"] || attrs[:node_id] || task.node_id,
         changeset =
           task
           |> Task.create_changeset(attrs, published_edit: true, editing_user_id: user.id)
           |> Ecto.Changeset.put_change(:node_id, node_id)
           |> validate_active_terms_edit(task)
           |> validate_reopen_schedule(task),
         {:ok, _} <- Ecto.Changeset.apply_action(changeset, :update),
         :ok <- require_edit_node(user, task.node_id, node_id) do
      before = task_snapshot(task)
      reopening? = task.status in ~w(expired cancelled)

      expiring? =
        task.status == "open" and
          past?(Ecto.Changeset.get_field(changeset, :application_deadline), DateTime.utc_now())

      status =
        cond do
          reopening? -> "open"
          expiring? -> "expired"
          true -> task.status
        end

      with {:ok, changeset} <- revise_reward(task, changeset, node_id, reopening?),
           {:ok, changeset} <- expire_edited_task(task, changeset, expiring?),
           {:ok, changeset} <- begin_next_round(task, changeset, reopening?),
           changeset = Ecto.Changeset.put_change(changeset, :status, status),
           {:ok, changeset} <- aggregate_edited_task(task, changeset, user.id),
           {:ok, saved} <- Repo.update(changeset),
           :ok <- sync_after_edit(task, saved),
           :ok <- record_edit(task, saved, before, user.id, reopening?),
           :ok <- notify_edited_due(task, saved, user.id, expiring?) do
        {:ok, preload_detail(saved)}
      end
    end
  end

  defp validate_active_terms_edit(changeset, %Task{status: status})
       when status in ~w(open in_progress overdue under_review) do
    Enum.reduce(@frozen_terms, changeset, fn {field, message}, changeset ->
      if Ecto.Changeset.changed?(changeset, field),
        do: Ecto.Changeset.add_error(changeset, field, message),
        else: changeset
    end)
  end

  defp validate_active_terms_edit(changeset, _task), do: changeset

  defp validate_reopen_schedule(changeset, %Task{status: status})
       when status in ~w(expired cancelled) do
    deadline = Ecto.Changeset.get_field(changeset, :application_deadline)

    if deadline && not past?(deadline, DateTime.utc_now()),
      do: changeset,
      else: Ecto.Changeset.add_error(changeset, :application_deadline, "重新开放需要将来的申请截止时间")
  end

  defp validate_reopen_schedule(changeset, _task), do: changeset

  defp expire_edited_task(_task, changeset, false), do: {:ok, changeset}

  defp expire_edited_task(task, changeset, true) do
    with :ok <- refund_task_reward(Repo, task) do
      {:ok,
       Ecto.Changeset.put_change(
         changeset,
         :reward_status,
         if(task.reward_status == "reserved", do: "refunded", else: "none")
       )}
    end
  end

  # 重新开放进入下一轮:旧一轮的申请和成果归档,承接人清空
  defp begin_next_round(_task, changeset, false), do: {:ok, changeset}

  defp begin_next_round(task, changeset, true) do
    applications = Repo.all(round_applications(task))

    submissions =
      Repo.all(from s in Submission, where: s.task_id == ^task.id and s.round == ^task.round)

    with :ok <- all_ok(applications, &archive(&1, previous_application_status(task, &1))),
         :ok <- all_ok(submissions, &archive(&1, previous_submission_status(&1))) do
      {:ok,
       Ecto.Changeset.change(changeset,
         assignee_id: nil,
         appointed_at: nil,
         appointment_reason: nil,
         round: task.round + 1
       )}
    end
  end

  defp archive(record, status),
    do: Repo.update(Ecto.Changeset.change(record, final_status: status))

  # 只有重开已过期 / 已取消的任务才归档,那时任务上没有承接人(有约束);
  # 提前结束时被撤销的承接人(released)和其余没走到底的申请一样,记成任务的结局。
  defp previous_application_status(_task, %Application{status: status})
       when status in @appointed,
       do: "appointed"

  defp previous_application_status(_task, %Application{rejected_at: rejected_at})
       when not is_nil(rejected_at),
       do: "not_selected"

  defp previous_application_status(%Task{status: status}, _application), do: status

  defp previous_submission_status(%Submission{final_status: status}) when not is_nil(status),
    do: status

  defp previous_submission_status(%Submission{review_reason: reason}) when not is_nil(reason),
    do: "changes_requested"

  defp previous_submission_status(_submission), do: "pending"

  # 编辑可能改了交付截止或申请截止:按新期限追平个人超期,重新汇总任务状态
  defp aggregate_edited_task(%Task{status: status}, changeset, actor_id)
       when status in @running do
    now = DateTime.utc_now()
    current = Ecto.Changeset.apply_changes(changeset)
    {:ok, _} = refresh_overdue(Repo, current, now)
    current = preload_detail(current)
    {next, unused} = aggregate_status(current, now)

    with :ok <- close_applications(current, actor_id, now),
         {:ok, changes} <- status_changes(current, next, unused) do
      {:ok, Ecto.Changeset.change(changeset, changes)}
    end
  end

  defp aggregate_edited_task(_task, changeset, _actor_id), do: {:ok, changeset}

  # 编辑可能让招募中的任务过期(待处理申请跟着过期),或让多人任务重新开放招募
  defp sync_after_edit(%Task{} = old, %Task{} = saved) do
    result =
      if saved.status in @running and accepting_applications?(saved),
        do: move_applications(Repo, round_applications(saved), "pending"),
        else: sync_applications(Repo, old, saved.status)

    with {:ok, _} <- result, do: :ok
  end

  defp record_edit(task, saved, before, actor_id, reopening?) do
    after_snapshot = saved |> Repo.preload(:image_links, force: true) |> task_snapshot()

    if before == after_snapshot do
      :ok
    else
      %Event{}
      |> Event.create_changeset(%{
        task_id: task.id,
        actor_id: actor_id,
        from_status: task.status,
        to_status: saved.status,
        detail: if(reopening?, do: "编辑并重新开放任务", else: "编辑了任务"),
        before: before,
        after: after_snapshot
      })
      |> Repo.insert()
      |> case do
        {:ok, _} -> :ok
        error -> error
      end
    end
  end

  defp notify_edited_due(old, saved, actor_id, expiring?) do
    cond do
      expiring? ->
        notify(saved, actor_id, Enum.map(applicant_ids(old), &{&1, "task_expired", "申请已截止"}))

      saved.status == "overdue" and old.status != "overdue" ->
        notify_overdue(preload_detail(saved), actor_id)

      true ->
        :ok
    end
  end

  defp revise_reward(_task, changeset, _node_id, false), do: {:ok, changeset}

  defp revise_reward(task, changeset, node_id, true) do
    amount = Ecto.Changeset.get_field(changeset, :reward_amount)
    capacity = Ecto.Changeset.get_field(changeset, :capacity)

    with {:ok, subject} <- reserve_edited_reward(task, amount, node_id, capacity) do
      {:ok,
       Ecto.Changeset.change(changeset,
         funding_node_id: node_id,
         reward_status: if(amount > 0, do: "reserved", else: "none"),
         reward_subject_uri: subject
       )}
    end
  end

  defp reserve_edited_reward(_task, 0, _node_id, _capacity), do: {:ok, nil}

  defp reserve_edited_reward(task, amount, node_id, capacity) do
    subject = "rice://tasks/#{task.id}/edits/#{Rice.Tsid.generate()}"

    edited = %{
      task
      | funding_node_id: node_id,
        reward_amount: amount,
        capacity: capacity,
        reward_subject_uri: subject
    }

    with :ok <- reserve_task_reward(Repo, edited), do: {:ok, subject}
  end

  defp task_snapshot(task) do
    %{
      "node_id" => task.node_id,
      "node_name" => task.node_id && Repo.get!(Rice.Community.Node, task.node_id).name,
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
    with {:ok, _} <- publishing_node(user, new_node_id), do: :ok
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

  @spec publish_draft(User.t(), Task.t()) ::
          {:ok, Task.t()}
          | {:error,
             :not_found | :forbidden | :conflict | :insufficient_balance | Ecto.Changeset.t()}
  def publish_draft(user, %Task{} = task) do
    with_locked_task(task.id, &publish_current_draft(user, &1))
  end

  defp publish_current_draft(
         %User{id: creator_id},
         %Task{creator_id: creator_id, status: "draft"} = task
       ) do
    publisher =
      if task.node_id,
        do: publishing_node(%User{id: creator_id}, task.node_id),
        else: personal_publisher(%User{id: creator_id})

    with {:ok, _node} <- publisher do
      case Task.publish_changeset(task) do
        %{valid?: true} ->
          {updates, detail, reward_step} = reserve_reward(task)
          transition_task(task, updates, creator_id, detail, [], reward_step)

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

  @spec cancel(User.t(), Task.t()) :: {:ok, Task.t()} | {:error, error()}
  def cancel(user, task), do: with_managed(task, user, &cancel_current(user, &1))

  defp cancel_current(%User{id: actor_id}, %Task{status: status} = task)
       when status in ["open", "draft"] do
    if status == "open" and application_deadline_reached?(task) do
      {:error, :conflict}
    else
      {updates, detail, reward_step} = refund_reward(task, "cancelled")
      rows = Enum.map(applicant_ids(task), &{&1, "task_cancelled", nil})
      transition_task(task, updates, actor_id, detail, rows, reward_step)
    end
  end

  defp cancel_current(%User{}, %Task{}), do: {:error, :conflict}

  @spec apply(User.t(), Task.t(), map()) ::
          {:ok, Application.t()}
          | {:error, :forbidden | :conflict | :capacity_full | Ecto.Changeset.t()}
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
      |> Multi.run(:application, fn
        repo, %{task: current_task, existing_application: nil} ->
          %Application{task_id: task.id, round: current_task.round, user_id: user.id}
          |> Application.create_changeset(attrs)
          |> repo.insert()

        _repo, %{existing_application: existing} ->
          {:ok, existing}
      end)
      |> Multi.run(:announce, fn repo, %{task: current_task, existing_application: existing} ->
        if existing do
          {:ok, :already_applied}
        else
          event =
            event_changeset(
              task.id,
              user.id,
              current_task.status,
              current_task.status,
              "收到任务申请"
            )

          rows = Enum.map(manager_ids(current_task), &{&1, "application_created", nil})

          with {:ok, _} <- repo.insert(event),
               :ok <- notify(current_task, user.id, rows),
               do: {:ok, :applied}
        end
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

  @spec appoint(User.t(), Task.t(), String.t(), map()) ::
          {:ok, Task.t()} | {:error, error() | :capacity_full}
  def appoint(user, %Task{} = task, application_id, attrs \\ %{}) do
    with_managed(task, user, {Application, application_id}, fn current, application ->
      appoint_application(user, current, application, attrs)
    end)
  end

  @spec reject_application(User.t(), Task.t(), String.t()) ::
          {:ok, Task.t()} | {:error, :not_found | :forbidden | :conflict | Ecto.Changeset.t()}
  def reject_application(user, %Task{} = task, application_id) do
    with_managed(task, user, {Application, application_id}, fn current, application ->
      reject_current_application(user, current, application)
    end)
  end

  defp reject_current_application(%User{id: actor_id}, task, application) do
    cond do
      not accepting_applications?(task) or not is_nil(application.appointed_at) ->
        {:error, :conflict}

      application.rejected_at ->
        {:ok, preload_detail(task)}

      true ->
        with :ok <- move_one(app_scope(application), "rejected", rejected_at: DateTime.utc_now()),
             :ok <- notify(task, actor_id, [{application.user_id, "application_rejected", nil}]),
             do: {:ok, preload_detail(task)}
    end
  end

  defp appoint_application(%User{id: actor_id}, task, application, attrs) do
    changeset = Task.appointment_changeset(task, attrs)
    appointed = appointed_applications(task)

    cond do
      # 多人任务重复指派按幂等处理;单人任务指派后就不再招募,重复指派是冲突
      task.capacity > 1 and ApplicationState.appointed?(application.status) ->
        {:ok, preload_detail(task)}

      not recruiting?(task) ->
        {:error, :conflict}

      length(appointed) >= task.capacity ->
        {:error, :capacity_full}

      # released / rejected / not_selected 等都不能再指派
      application.status != "pending" or application_deadline_reached?(task) ->
        {:error, :conflict}

      not changeset.valid? ->
        {:error, changeset}

      true ->
        reason = Ecto.Changeset.get_field(changeset, :appointment_reason)

        with :ok <-
               move_one(app_scope(application), "appointed",
                 appointed_at: DateTime.utc_now(),
                 appointment_reason: reason,
                 reward_slot: next_reward_slot(task, appointed)
               ),
             :ok <- notify(task, actor_id, [{application.user_id, "assignee_appointed", reason}]),
             do: update_status(task, actor_id, detail: reason)
    end
  end

  # 被撤销指派的人让出名额,编号(以及那份冻结)留给下一个被指派的人。
  defp next_reward_slot(task, appointed) do
    used = Enum.map(appointed, & &1.reward_slot)
    Enum.find(1..task.capacity, &(&1 not in used))
  end

  @doc """
  多人任务:撤销一个人的指派。名额让出来,奖励不发;对方已提交、等待验收时不能撤,
  要先验收或退回修改。没有人在承作时任务回到 `open`。
  单人任务没有撤销指派,承接人不干了就提前结束(`close/2`)。
  """
  @spec release_assignee(User.t(), Task.t(), String.t(), map()) ::
          {:ok, Task.t()} | {:error, error()}
  def release_assignee(user, %Task{} = task, application_id, attrs \\ %{}) do
    with_managed(task, user, {Application, application_id}, fn current, application ->
      release_current_assignee(user, current, application, attrs)
    end)
  end

  defp release_current_assignee(
         %User{id: actor_id},
         %Task{capacity: capacity, status: status} = task,
         application,
         attrs
       )
       when capacity > 1 and status in @running do
    reason = release_reason(attrs)

    with true <- application.status in ~w(appointed overdue) or {:error, :conflict},
         :ok <- move_one(app_scope(application), "released", reward_slot: nil),
         :ok <- notify(task, actor_id, [{application.user_id, "appointment_released", reason}]),
         do: update_status(task, actor_id, detail: reason)
  end

  defp release_current_assignee(_user, _task, _application, _attrs), do: {:error, :conflict}

  defp release_reason(attrs) do
    with reason when is_binary(reason) <- attrs["reason"] || attrs[:reason],
         reason when reason != "" <- reason |> String.trim() |> String.slice(0, 512) do
      reason
    else
      _ -> nil
    end
  end

  @doc """
  提前结束进行中的任务。还在承作的人撤销指派,待处理的申请落选,没发出去的奖励退回节点。
  有人已通过验收就记为 `completed`,一个都没有则记为 `cancelled`。
  有成果等待验收时不能结束,要先验收或退回修改。

  单人任务也走这里:承接人超期不交、又不能取消时,这是唯一能把冻结的奖励退回去的路。
  """
  @spec close(User.t(), Task.t()) :: {:ok, Task.t()} | {:error, error()}
  def close(user, %Task{} = task), do: with_managed(task, user, &close_current(user, &1))

  defp close_current(%User{id: actor_id}, %Task{status: status} = task)
       when status in @running do
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
          do:
            "已提前结束，向#{if(task.funding_node_id, do: "节点", else: "发布者")}退回 #{task.reward_amount * length(unused)} 稻米",
          else: "已提前结束"

      with {:ok, released} <- move_applications(Repo, scope, "released", reward_slot: nil),
           {:ok, not_selected} <- move_applications(Repo, scope, "not_selected"),
           :ok <- refund_reward_slots(Repo, task, unused),
           {:ok, saved} <-
             Repo.update(
               Ecto.Changeset.change(task,
                 status: next,
                 reward_status: reward_status,
                 assignee_id: nil,
                 appointed_at: nil
               )
             ),
           {:ok, _} <- Repo.insert(event_changeset(task.id, actor_id, task.status, next, detail)),
           :ok <-
             notify(
               task,
               actor_id,
               Enum.map(released, &{&1, "appointment_released", detail}) ++
                 Enum.map(not_selected, &{&1, "application_not_selected", nil})
             ) do
        {:ok, preload_detail(saved)}
      end
    end
  end

  defp close_current(%User{}, %Task{}), do: {:error, :conflict}

  @spec submit_result(User.t(), Task.t(), map()) :: {:ok, Task.t()} | {:error, error()}
  def submit_result(user, %Task{} = task, attrs),
    do: with_locked_task(task.id, &submit_current_result(user, &1, attrs))

  defp submit_current_result(%User{id: user_id} = user, task, attrs) do
    cond do
      not appointed?(task, user) ->
        {:error, :forbidden}

      task.status not in @running or my_status(task, user) not in ~w(in_progress overdue) ->
        {:error, :conflict}

      true ->
        submission = %Submission{task_id: task.id, round: task.round, user_id: user_id}
        managers = Enum.map(manager_ids(task), &{&1, "result_submitted", nil})

        with {:ok, task} <- record_late_overdue(task),
             {:ok, _} <- Repo.insert(Submission.create_changeset(submission, attrs)),
             :ok <- move_one(user_application(task, user_id), "under_review"),
             {:ok, updated} <- update_status(task, user_id),
             :ok <- notify(task, user_id, managers),
             do: {:ok, updated}
    end
  end

  # 单人任务过了交付截止、定时检查还没跑到就交付:先照定时检查补记超期(事件和提醒),
  # 历史里才看得出是迟交的。多人任务的个人超期在汇总时追平,不单独记。
  defp record_late_overdue(%Task{capacity: 1, status: "in_progress"} = task) do
    if execution_overdue?(task, DateTime.utc_now()),
      do: update_status(task, nil),
      else: {:ok, task}
  end

  defp record_late_overdue(task), do: {:ok, task}

  @spec approve_result(User.t(), Task.t(), String.t()) ::
          {:ok, Task.t()} | {:error, error() | :recipient_not_found}
  def approve_result(user, %Task{} = task, submission_id) do
    with_managed(task, user, {Submission, submission_id}, fn current, submission ->
      # 被指派后才升成节点管理员的人,不能自己给自己验收发奖
      if submission.user_id == user.id,
        do: {:error, :forbidden},
        else: approve_submission(user, current, submission)
    end)
  end

  defp approve_submission(%User{id: actor_id}, task, %Submission{id: id} = submission) do
    application = Enum.find(appointed_applications(task), &(&1.user_id == submission.user_id))

    case latest_submission(task, submission.user_id) do
      # 多人任务里别人可能还在做,重复验收按幂等处理;单人任务这时已经完成,重复验收是冲突
      %Submission{id: ^id, final_status: "approved"} when task.capacity > 1 ->
        {:ok, preload_detail(task)}

      %Submission{id: ^id, review_reason: nil, final_status: nil}
      when not is_nil(application) and task.status in @running ->
        with :ok <- settle_application_reward(task, application),
             :ok <- move_one(user_application(task, submission.user_id), "completed"),
             {:ok, _} <- Repo.update(Ecto.Changeset.change(submission, final_status: "approved")),
             {:ok, updated} <- update_status(task, actor_id),
             :ok <-
               notify(task, actor_id, [
                 {submission.user_id, "result_approved", reward_detail(task, :settled)}
               ]),
             do: {:ok, updated}

      _ ->
        {:error, :conflict}
    end
  end

  @spec request_changes(User.t(), Task.t(), String.t(), term()) ::
          {:ok, Task.t()} | {:error, error()}
  def request_changes(user, %Task{} = task, submission_id, reason) do
    with_managed(task, user, {Submission, submission_id}, fn current, submission ->
      request_submission_changes(user, current, submission, reason)
    end)
  end

  defp request_submission_changes(
         %User{id: actor_id},
         task,
         %Submission{id: id} = submission,
         reason
       )
       when is_binary(reason) do
    case latest_submission(task, submission.user_id) do
      %Submission{id: ^id, review_reason: nil, final_status: nil} when task.status in @running ->
        with {:ok, _} <- Repo.update(Submission.review_changeset(submission, reason)),
             :ok <- move_one(user_application(task, submission.user_id), "appointed"),
             {:ok, updated} <- update_status(task, actor_id, detail: reason),
             :ok <- notify(task, actor_id, [{submission.user_id, "changes_requested", reason}]),
             do: {:ok, updated}

      _ ->
        {:error, :conflict}
    end
  end

  defp request_submission_changes(_user, _task, _submission, _reason), do: {:error, :conflict}

  @spec check_due_tasks(DateTime.t()) ::
          {:ok, [Task.t()]}
          | {:error, :not_found | :conflict | :grain_reservation_missing | Ecto.Changeset.t()}
  def check_due_tasks(now \\ DateTime.utc_now()) do
    # 进行中的任务过了截止仍留在进行中,只在还有事可做时才拿出来:申请截止后还有待处理的申请、
    # 或者所有承作人都已结束(该收尾了);交付截止后还有人没记成超期。
    pending = from(a in current_round_applications(), where: a.status == "pending")

    working =
      from(a in current_round_applications(),
        where: a.status in ["appointed", "overdue", "under_review"]
      )

    not_yet_overdue = from(a in current_round_applications(), where: a.status == "appointed")

    due =
      from(t in Task,
        as: :task,
        where:
          (t.status == "open" and t.application_deadline <= ^now) or
            (t.status in ["in_progress", "overdue", "under_review"] and
               ((t.application_deadline <= ^now and (exists(pending) or not exists(working))) or
                  (t.execution_deadline <= ^now and exists(not_yet_overdue))))
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

  defp transition_due_task(%Task{status: "open"} = task, _now) do
    {updates, reward_detail, reward_step} = refund_reward(task, "expired")
    detail = Enum.join(Enum.reject(["申请已截止", reward_detail], &is_nil/1), "，")
    rows = Enum.map(applicant_ids(task), &{&1, "task_expired", detail})
    transition_task(task, updates, nil, detail, rows, reward_step)
  end

  defp transition_due_task(task, now), do: update_status(task, nil, now: now)

  @spec list_notifications(User.t()) :: [Notification.t()]
  def list_notifications(%User{id: user_id}) do
    from(n in Notification,
      where: n.recipient_id == ^user_id and not is_nil(n.task_id),
      order_by: [desc: n.id],
      limit: 50,
      preload: [actor: :avatar, task: []]
    )
    |> Repo.all()
  end

  defp initial_status(attrs) do
    case attrs["status"] || attrs[:status] do
      nil -> {:ok, "open"}
      "draft" -> {:ok, "draft"}
      "open" -> {:ok, "open"}
      _ -> {:error, :unprocessable_entity}
    end
  end

  # 截止时间到了(正好到点也算);没设截止的永远不算到
  defp past?(nil, _now), do: false
  defp past?(time, now), do: DateTime.compare(time, now) != :gt

  defp application_deadline_reached?(task),
    do: past?(task.application_deadline, DateTime.utc_now())

  defp execution_overdue?(task, now), do: past?(task.execution_deadline, now)

  defp visible_to?(%Task{status: "draft", creator_id: creator_id}, %User{id: creator_id}),
    do: true

  defp visible_to?(%Task{status: "draft"}, _user), do: false
  defp visible_to?(%Task{status: "cancelled"} = task, user), do: private_viewer?(task, user)

  defp visible_to?(%Task{status: "open", application_deadline: deadline} = task, user),
    do: not past?(deadline, visibility_cutoff()) or private_viewer?(task, user)

  defp visible_to?(%Task{status: "expired", application_deadline: deadline} = task, user),
    do: (deadline && not past?(deadline, visibility_cutoff())) || private_viewer?(task, user)

  defp visible_to?(%Task{}, _user), do: true

  defp visibility_cutoff,
    do: DateTime.add(DateTime.utc_now(), -@public_visibility_grace_seconds)

  defp private_viewer?(_task, nil), do: false

  defp private_viewer?(task, %User{id: id} = user) do
    task.creator_id == id or can_manage?(task, user) or can_edit?(task, user) or
      Repo.exists?(from a in Application, where: a.task_id == ^task.id and a.user_id == ^id)
  end

  defp scope_visibility(query, %User{}, mine) when mine in ~w(created managed assigned applied),
    do: query

  defp scope_visibility(query, _user, _mine) do
    cutoff = visibility_cutoff()

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
    applied = from(a in current_round_applications(), where: a.user_id == ^id)

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
      from(a in current_round_applications(), where: a.user_id == ^id and a.status in ^@appointed)

    from(t in query,
      where:
        exists(application) and (is_nil(t.assignee_id) or t.assignee_id != ^id) and
          not exists(appointed)
    )
  end

  defp scope_mine(query, nil, mine) when mine in ~w(created managed assigned applied),
    do: from(t in query, where: false)

  defp scope_mine(query, _user, _mine), do: query

  # 外层任务(`as: :task`)当前轮次的申请,给 exists 子查询用
  defp current_round_applications do
    from(a in Application,
      where: a.task_id == parent_as(:task).id and a.round == parent_as(:task).round,
      select: 1
    )
  end

  defp conditional_update(repo, query, updates) do
    case repo.update_all(query, set: updates) do
      {1, _} -> {:ok, :updated}
      _ -> {:error, :conflict}
    end
  end

  # Core terms and the reviewed submission must come from the same locked task state.
  defp with_locked_task(task_id, action) do
    Repo.transaction(fn ->
      with %Task{} = task <- Repo.one(from t in Task, where: t.id == ^task_id, lock: "FOR UPDATE"),
           {:ok, result} <- action.(task) do
        result
      else
        nil -> Repo.rollback(:not_found)
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # 管理动作:加锁重读任务、确认管理权限,需要时再取出本轮的申请或成果
  defp with_managed(task, user, action) do
    with_locked_task(task.id, fn current ->
      with :ok <- authorize_management(current, user), do: action.(current)
    end)
  end

  defp with_managed(task, user, {schema, id}, action) do
    with_managed(task, user, fn current ->
      with {:ok, record} <- fetch_record(schema, current, id), do: action.(current, record)
    end)
  end

  # 发布 / 取消 / 申请截止:状态没被别人先改掉才写入,在同一事务里同步申请、动账、记事件和通知
  defp transition_task(task, updates, actor_id, detail, rows, reward_step) do
    to = Keyword.fetch!(updates, :status)
    query = from(t in Task, where: t.id == ^task.id and t.status == ^task.status)

    Multi.new()
    |> Multi.run(:task, fn repo, _ ->
      conditional_update(repo, query, Keyword.put(updates, :updated_at, DateTime.utc_now()))
    end)
    |> Multi.run(:applications, fn repo, _ -> sync_applications(repo, task, to) end)
    |> maybe_run_reward(reward_step)
    |> Multi.insert(:event, event_changeset(task.id, actor_id, task.status, to, detail))
    |> Multi.run(:notifications, fn _repo, _ ->
      with :ok <- notify(task, actor_id, rows), do: {:ok, length(rows)}
    end)
    |> Repo.transaction()
    |> transaction_task(task.id)
  end

  defp maybe_run_reward(multi, nil), do: multi

  defp maybe_run_reward(multi, reward_step) do
    Multi.run(multi, :task_reward, fn repo, changes ->
      with :ok <- reward_step.(repo, changes), do: {:ok, nil}
    end)
  end

  defp reserve_reward(%Task{reward_amount: amount} = task) when amount > 0 do
    # 草稿还没有冻结,发布时才定出资方:节点任务由节点出,个人任务(没有节点)由发布者本人出
    task = %{task | funding_node_id: task.node_id}

    {
      [status: "open", reward_status: "reserved", funding_node_id: task.node_id],
      reward_detail(task, :reserved),
      fn repo, _changes -> reserve_task_reward(repo, task) end
    }
  end

  defp reserve_reward(task), do: {[status: "open", funding_node_id: task.node_id], nil, nil}

  defp refund_reward(%Task{reward_status: "reserved", reward_amount: amount} = task, status)
       when amount > 0 do
    {
      [status: status, reward_status: "refunded"],
      reward_detail(task, :refunded),
      fn repo, _changes -> refund_task_reward(repo, task) end
    }
  end

  defp refund_reward(_task, status), do: {[status: status], nil, nil}

  defp reward_account(%Task{funding_node_id: nil, creator_id: id}), do: id
  defp reward_account(%Task{funding_node_id: id}), do: {:node, id}
  defp reward_subject(%Task{reward_subject_uri: nil, id: id}), do: "rice://tasks/#{id}"
  defp reward_subject(%Task{reward_subject_uri: subject}), do: subject

  # 单人任务的冻结、结算和退款一直记在任务本身(没有 /slots/1),账本不迁移,这里照旧
  defp slot_subject(%Task{capacity: 1} = task, _slot), do: reward_subject(task)
  defp slot_subject(task, slot), do: "#{reward_subject(task)}/slots/#{slot}"

  defp reserve_task_reward(repo, task) do
    all_ok(1..task.capacity, fn slot ->
      Grains.reserve_business(
        repo,
        reward_account(task),
        task.reward_amount,
        slot_subject(task, slot)
      )
    end)
  end

  defp refund_task_reward(repo, task),
    do: refund_reward_slots(repo, task, Enum.to_list(1..task.capacity))

  defp refund_reward_slots(_repo, %Task{reward_amount: 0}, _slots), do: :ok

  defp refund_reward_slots(repo, task, slots) do
    all_ok(slots, fn slot ->
      Grains.refund_business(
        repo,
        reward_account(task),
        task.reward_amount,
        slot_subject(task, slot)
      )
    end)
  end

  defp settle_application_reward(%Task{reward_amount: 0}, _application), do: :ok

  defp settle_application_reward(task, application) do
    with {:ok, _} <-
           Grains.settle_business(
             Repo,
             reward_account(task),
             application.user_id,
             task.reward_amount,
             slot_subject(task, application.reward_slot)
           ),
         do: :ok
  end

  # 逐个执行,遇到第一个错误就停下返回它
  defp all_ok(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        {:ok, _} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp latest_submission(task, user_id) do
    task
    |> Repo.preload(:submissions)
    |> Map.fetch!(:submissions)
    |> Enum.filter(&(&1.round == task.round and &1.user_id == user_id))
    |> Enum.max_by(& &1.id, fn -> nil end)
  end

  # 任务状态是所有占名额申请的汇总,最差者优先(规则见 docs/tasks.md)。
  # 调用前已用 refresh_overdue 按交付截止追平过个人的 overdue。
  defp aggregate_status(task, now) do
    appointed = appointed_applications(task)
    statuses = Enum.map(appointed, & &1.status)

    complete? =
      Enum.all?(statuses, &(&1 == "completed")) and
        (length(appointed) == task.capacity or past?(task.application_deadline, now))

    next =
      cond do
        # 承作的人都被撤销了:回到招募中,再没人接就由定时任务按申请截止处理
        appointed == [] -> "open"
        complete? -> "completed"
        "overdue" in statuses -> "overdue"
        "under_review" in statuses -> "under_review"
        true -> "in_progress"
      end

    # 迁移给已有的单人申请补了 1 号,但部署时旧版本在迁移之后、新版本起来之前还可能
    # 指派单人任务,那一行没有编号。单人任务只有 1 号,按 1 号算;否则验收时会把刚结算
    # 的那笔当成没用上的名额去退款,整笔验收冲突回滚
    {next, Enum.to_list(1..task.capacity) -- Enum.map(appointed, &(&1.reward_slot || 1))}
  end

  # 任务整体完成时退回没用上的名额,奖励记为已结算
  defp status_changes(task, next, unused) do
    with :ok <- if(next == "completed", do: refund_reward_slots(Repo, task, unused), else: :ok) do
      settled? = next == "completed" and task.reward_amount > 0
      {:ok, [status: next] ++ if(settled?, do: [reward_status: "settled"], else: [])}
    end
  end

  # 申请迁移之后重算任务状态:追平个人超期、重新开放或关闭招募、落库并记事件。
  # 定时检查(没有操作人)发现状态没变时什么都不写。
  defp update_status(task, actor_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    # 单人任务的指派:那一刻不判超期(超期连同提醒统一由定时检查记),承接人记到 tasks 上
    single_appointment? = task.capacity == 1 and task.status == "open"
    unless single_appointment?, do: {:ok, _} = refresh_overdue(Repo, task, now)
    current = preload_detail(task)
    {next, unused} = aggregate_status(current, now)

    # 撤销指派让出了名额:之前因名额满而落选的申请重新排队
    if accepting_applications?(current),
      do: {:ok, _} = move_applications(Repo, round_applications(current), "pending")

    with :ok <- close_applications(current, actor_id, now) do
      if next == task.status and is_nil(actor_id) do
        {:ok, current}
      else
        assignee = if single_appointment?, do: assignee_columns(current), else: []
        detail = Keyword.get(opts, :detail) || single_detail(task, next)

        with {:ok, changes} <- status_changes(task, next, unused),
             {:ok, saved} <- Repo.update(Ecto.Changeset.change(task, changes ++ assignee)),
             {:ok, _} <-
               Repo.insert(event_changeset(task.id, actor_id, task.status, next, detail)),
             :ok <- notify_newly_overdue(current, task.status, next, actor_id) do
          {:ok, preload_detail(saved)}
        end
      end
    end
  end

  # 约束 tasks_assignee_matches_status:单人任务进行中 / 完成时 tasks 上要有承接人
  defp assignee_columns(task) do
    [application] = appointed_applications(task)

    [
      assignee_id: application.user_id,
      appointed_at: application.appointed_at,
      appointment_reason: application.appointment_reason
    ]
  end

  # 单人任务的事件说明承接人也看得到(TaskJSON.visible_events),沿用发给他的那句话
  defp single_detail(%Task{capacity: 1}, "overdue"), do: @overdue_detail
  defp single_detail(%Task{capacity: 1} = task, "completed"), do: reward_detail(task, :settled)
  defp single_detail(_task, _status), do: nil

  # 名额满或申请截止:还在排队的申请落选。pending -> not_selected 只会发生一次,
  # 通知跟着迁移走,不需要再查通知表去重。
  defp close_applications(task, actor_id, now) do
    if length(appointed_applications(task)) >= task.capacity or
         past?(task.application_deadline, now) do
      {:ok, user_ids} = move_applications(Repo, round_applications(task), "not_selected")
      notify(task, actor_id, Enum.map(user_ids, &{&1, "application_not_selected", nil}))
    else
      :ok
    end
  end

  # 任务刚进入超期时提醒超期的人。单人任务只在定时检查记超期时提醒,退回修改回到超期不再提醒
  defp notify_newly_overdue(task, from, to, actor_id) do
    if to == "overdue" and from != "overdue" and (task.capacity > 1 or is_nil(actor_id)),
      do: notify_overdue(task, actor_id),
      else: :ok
  end

  defp notify_overdue(task, actor_id) do
    rows =
      for %{status: "overdue"} = application <- appointed_applications(task),
          do: {application.user_id, "task_overdue", @overdue_detail}

    notify(task, actor_id, rows)
  end

  # rows 是 {收件人, 事件, 说明};没有操作人(定时检查)时以发布者名义发
  defp notify(task, actor_id, rows) do
    all_ok(rows, fn {recipient_id, event, detail} ->
      Repo.insert(
        notification_changeset(task, recipient_id, actor_id || task.creator_id, event, detail)
      )
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

  # 申请、交付要通知的人:节点的管理员们;个人出资的任务没有节点,就是发起人自己
  defp manager_ids(%Task{node_id: nil, creator_id: id}), do: [id]

  defp manager_ids(task),
    do: Rice.Community.admin_ids(Repo.get!(Rice.Community.Node, task.node_id))

  defp applicant_ids(task), do: Repo.all(from(a in round_applications(task), select: a.user_id))

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

  defp notification_changeset(task, recipient_id, actor_id, event, detail) do
    Notification.create_changeset(%Notification{}, %{
      task_id: task.id,
      recipient_id: recipient_id,
      actor_id: actor_id,
      event: event,
      detail: detail
    })
  end

  defp event_changeset(task_id, actor_id, from_status, to_status, detail) do
    Event.create_changeset(%Event{}, %{
      task_id: task_id,
      actor_id: actor_id,
      from_status: from_status,
      to_status: to_status,
      detail: detail
    })
  end

  defp fetch_record(schema, task, id) do
    with true <- Rice.Tsid.valid?(id),
         %{} = record <- Repo.get_by(schema, id: id, task_id: task.id, round: task.round) do
      {:ok, record}
    else
      _ -> {:error, :not_found}
    end
  end

  defp transaction_task({:ok, _changes}, task_id), do: fetch_task_record(task_id)
  defp transaction_task({:error, _step, reason, _changes}, _task_id), do: {:error, reason}

  defp round_applications(%Task{id: id, round: round}),
    do: from(a in Application, where: a.task_id == ^id and a.round == ^round)

  defp user_application(%Task{} = task, user_id),
    do: from(a in round_applications(task), where: a.user_id == ^user_id)

  defp app_scope(%Application{id: id}), do: from(a in Application, where: a.id == ^id)

  @doc false
  # 申请状态机的唯一入口:只放行 ApplicationState 里允许的迁移,返回真正迁移了的 user_id。
  @spec move_applications(Ecto.Repo.t(), Ecto.Queryable.t(), String.t(), keyword()) ::
          {:ok, [Rice.Tsid.t()]}
  def move_applications(repo, scope, to, extra \\ []) do
    sources = ApplicationState.sources(to)
    query = from(a in scope, where: a.status in ^sources, select: a.user_id)
    set = [status: to, updated_at: DateTime.utc_now()] ++ extra
    {_count, user_ids} = repo.update_all(query, set: set)
    {:ok, user_ids}
  end

  # 只迁移这一行;没迁移成(状态已被别人改掉)就是冲突
  defp move_one(scope, to, extra \\ []) do
    case move_applications(Repo, scope, to, extra) do
      {:ok, [_]} -> :ok
      {:ok, _} -> {:error, :conflict}
    end
  end

  # 招募阶段取消 / 过期时,待处理的申请跟着变成 cancelled / expired。
  # 其余的申请迁移都由各个动作逐个做,任务状态随后汇总。
  defp sync_applications(repo, task, to) when to in ~w(cancelled expired),
    do: move_applications(repo, round_applications(task), to)

  defp sync_applications(_repo, _task, _to), do: {:ok, []}

  # 交付截止已过 → appointed 记为 overdue;截止被延后 → overdue 回到 appointed。
  defp refresh_overdue(repo, %Task{} = task, now) do
    scope = round_applications(task)

    if execution_overdue?(task, now),
      do: move_applications(repo, from(a in scope, where: a.status == "appointed"), "overdue"),
      else: move_applications(repo, from(a in scope, where: a.status == "overdue"), "appointed")
  end

  defp preload_list(tasks) do
    Repo.preload(
      tasks,
      base_preloads() ++
        [
          submissions: [],
          events: from(e in Event, where: e.to_status == "open", order_by: [asc: e.id])
        ]
    )
  end

  # 强制重读:动作之间传递的任务可能带着申请迁移之前的预加载
  defp preload_detail(task) do
    Repo.preload(
      task,
      base_preloads() ++
        [
          submissions: [user: :avatar],
          events: from(e in Event, order_by: [asc: e.id], preload: [actor: :avatar])
        ],
      force: true
    )
  end

  defp base_preloads do
    [
      image_links: :attachment,
      node: [:logo, user: :avatar, memberships: Rice.Community.admin_memberships()],
      creator: :avatar,
      assignee: :avatar,
      applications: [user: :avatar]
    ]
  end
end

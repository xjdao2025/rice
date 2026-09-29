defmodule Rice.Events do
  @moduledoc "活动候选、名额和稻米处置；每次变更锁活动，再在同一事务中改记录与余额。"
  import Ecto.Query
  alias Ecto.Changeset
  alias Rice.Accounts.User
  alias Rice.Community.Node
  alias Rice.Events.{Application, Event, EventHistory}
  alias Rice.{Grains, Inbox, Pagination, Repo}

  def list_events(user, params \\ %{}) do
    query = from(e in Event)

    query =
      if user && params["mine"] == "created",
        do: where(query, [e], e.creator_id == ^user.id),
        else: where(query, [e], e.status != "draft")

    query =
      case params["mine"] do
        "applied" when not is_nil(user) ->
          from(e in query,
            join: a in Application,
            on: a.event_id == e.id and a.user_id == ^user.id,
            distinct: true
          )

        "managed" when not is_nil(user) ->
          ids = Rice.Community.managed_node_ids(user)

          from e in Event,
            where:
              e.creator_id == ^user.id or
                (e.status != "draft" and e.node_id in ^ids)

        mine when mine in ["created", "applied", "managed"] and is_nil(user) ->
          where(query, [e], false)

        _ ->
          query
      end

    query =
      case params["node_id"] do
        nil ->
          query

        id ->
          if Rice.Tsid.valid?(id),
            do: where(query, [e], e.node_id == ^id),
            else: where(query, [e], false)
      end

    query =
      if params["status"] in ~w(draft open in_progress completed cancelled),
        do: where(query, [e], e.status == ^params["status"]),
        else: query

    query =
      case params["creator_did"] do
        did when is_binary(did) and did != "" ->
          creators = from u in User, where: u.did == ^did, select: u.id
          where(query, [e], e.creator_id in subquery(creators))

        _ ->
          query
      end

    query =
      case params["participant_did"] do
        did when is_binary(did) and did != "" ->
          participating =
            from a in Application,
              join: u in User,
              on: u.id == a.user_id,
              join: e in Event,
              on: e.id == a.event_id,
              where: u.did == ^did and a.status == "approved" and a.round == e.round,
              select: a.event_id

          where(query, [e], e.id in subquery(participating))

        _ ->
          query
      end

    query =
      case params["q"] do
        value when is_binary(value) and value != "" ->
          term = "%#{String.trim(value)}%"
          where(query, [e], ilike(e.title, ^term) or ilike(e.description, ^term))

        _ ->
          query
      end

    page = Pagination.paginate(query, Repo, Pagination.params(params))
    %{page | entries: preload(page.entries)}
  end

  def fetch_event(id, user \\ nil) do
    case if(Rice.Tsid.valid?(id), do: Repo.get(Event, id)) do
      nil ->
        {:error, :not_found}

      event ->
        if event.status != "draft" or (user && user.id == event.creator_id),
          do: {:ok, preload(event)},
          else: {:error, :not_found}
    end
  end

  def create_event(%User{} = user, attrs) do
    attrs = stringify(attrs)
    status = attrs["status"] || "open"
    key = attrs["client_request_id"]

    cond do
      status not in ["draft", "open"] ->
        {:error, :unprocessable_entity}

      not is_nil(key) and (not is_binary(key) or byte_size(key) not in 1..128) ->
        {:error, :unprocessable_entity}

      status == "open" and is_nil(key) ->
        {:error,
         Changeset.add_error(Changeset.change(%Event{}), :client_request_id, "发布请求缺少重试标识")}

      true ->
        transaction(fn ->
          # Serialize one creator's draft and retry key without adding a draft service.
          Repo.one!(from(u in User, where: u.id == ^user.id, lock: "FOR UPDATE"))
          existing = if key, do: Repo.get_by(Event, creator_id: user.id, client_request_id: key)

          if existing do
            existing
          else
            node_id = attrs["node_id"]
            require_node!(user, node_id)

            draft =
              if status == "draft",
                do:
                  Repo.one(
                    from(e in Event,
                      where: e.creator_id == ^user.id and e.status == "draft",
                      lock: "FOR UPDATE"
                    )
                  )

            event =
              draft ||
                %Event{
                  creator_id: user.id,
                  node_id: node_id,
                  settlement_node_id: node_id,
                  status: status,
                  client_request_id: key,
                  published_at: if(status == "open", do: DateTime.utc_now())
                }

            changeset =
              event
              |> Event.changeset(attrs)
              |> Changeset.put_change(:node_id, node_id)
              |> Changeset.put_change(:settlement_node_id, node_id)

            saved = unwrap!(Repo.insert_or_update(changeset))
            unless draft, do: record!(saved, user.id, nil, "created", nil, status)
            saved
          end
        end)
    end
  end

  def update_draft(user, event, attrs) do
    attrs = stringify(attrs)

    with_event(event.id, fn current ->
      require_host!(user, current)
      require!(current.status == "draft")
      node_id = attrs["node_id"] || current.node_id
      require_node!(user, node_id)

      changeset =
        current
        |> Event.changeset(attrs)
        |> Changeset.put_change(:node_id, node_id)
        |> Changeset.put_change(:settlement_node_id, node_id)

      unwrap!(Repo.update(changeset))
    end)
  end

  def update_event(user, event, attrs) do
    attrs = stringify(attrs)

    with_event(event.id, fn current ->
      if current.status == "draft" do
        require_host!(user, current)
        node_id = attrs["node_id"] || current.node_id
        require_node!(user, node_id)

        current
        |> Event.changeset(attrs)
        |> Changeset.put_change(:node_id, node_id)
        |> Changeset.put_change(:settlement_node_id, node_id)
        |> Repo.update()
        |> unwrap!()
      else
        update_published!(user, current, attrs)
      end
    end)
  end

  defp update_published!(user, event, attrs) do
    require!(can_edit?(event, user), :forbidden)
    require!(event.status in ["open", "in_progress", "cancelled"])
    event = Repo.preload(event, :image_links)
    node_id = attrs["node_id"] || event.node_id

    if node_id != event.node_id and event.status == "cancelled",
      do: require_node!(user, node_id)

    changeset =
      event
      |> Event.changeset(attrs, published_edit: true, editing_user_id: user.id)
      |> Changeset.put_change(:node_id, node_id)
      |> Changeset.put_change(
        :settlement_node_id,
        if(event.status == "cancelled", do: node_id, else: event.settlement_node_id)
      )

    now = DateTime.utc_now()
    reopening? = event.status == "cancelled"

    changeset =
      if event.status in ["open", "in_progress"] and Changeset.changed?(changeset, :node_id),
        do: Changeset.add_error(changeset, :node_id, "已发布活动不能更换所属社区"),
        else: changeset

    changeset =
      if event.status in ["open", "in_progress"] and
           Changeset.changed?(changeset, :fee_amount),
         do: Changeset.add_error(changeset, :fee_amount, "已发布活动不能修改报名费"),
         else: changeset

    changeset =
      if reopening? and
           (is_nil(Changeset.get_field(changeset, :application_deadline)) or
              not before?(now, Changeset.get_field(changeset, :application_deadline))),
         do: Changeset.add_error(changeset, :application_deadline, "报名截止时间必须在将来"),
         else: changeset

    unwrap!(Changeset.apply_action(changeset, :update))

    if event.status in ["open", "in_progress"] do
      approved =
        Repo.aggregate(
          from(a in Application,
            where: a.event_id == ^event.id and a.round == ^event.round and a.status == "approved"
          ),
          :count
        )

      require!(approved <= Changeset.get_field(changeset, :capacity), :capacity_full)
    end

    before = event_snapshot(event)

    changeset =
      if reopening?,
        do:
          Changeset.change(changeset,
            status: "open",
            round: event.round + 1,
            published_at: now
          ),
        else: changeset

    saved = changeset |> Repo.update() |> unwrap!() |> Repo.preload(:image_links, force: true)

    after_snapshot = event_snapshot(saved)

    if before != after_snapshot do
      unwrap!(
        Repo.insert(%EventHistory{
          event_id: event.id,
          actor_id: user.id,
          action: "edited",
          round: saved.round,
          from_status: event.status,
          to_status: saved.status,
          before: before,
          after: after_snapshot
        })
      )
    end

    if event.status == "open" and not before?(now, saved.starts_at),
      do: start_locked!(saved, now),
      else: saved
  end

  defp event_snapshot(event) do
    %{
      "node_id" => event.node_id,
      "node_name" => Repo.get!(Node, event.node_id).name,
      "title" => event.title,
      "description" => event.description,
      "organizer_contact" => event.organizer_contact,
      "location" => event.location,
      "application_deadline" => event.application_deadline,
      "starts_at" => event.starts_at,
      "ends_at" => event.ends_at,
      "fee_amount" => event.fee_amount,
      "capacity" => event.capacity,
      "round" => event.round,
      "settlement_node_id" => event.settlement_node_id,
      "attachment_ids" => Enum.map(event.image_links, & &1.attachment_id)
    }
  end

  def publish_draft(user, event) do
    with_event(event.id, fn current ->
      require_host!(user, current)

      cond do
        current.status == "open" ->
          current

        current.status == "draft" ->
          unwrap!(Repo.update(Event.publish_changeset(current)))

          change_event!(current, user.id, "published", "open",
            published_at: DateTime.utc_now(),
            settlement_node_id: current.node_id
          )

        true ->
          Repo.rollback(:conflict)
      end
    end)
  end

  def apply(user, event, attrs) do
    with_event(event.id, fn current ->
      require!(current.creator_id != user.id and not can_manage?(current, user), :forbidden)

      existing =
        Repo.get_by(Application, event_id: current.id, round: current.round, user_id: user.id)

      if existing do
        current
      else
        now = DateTime.utc_now()

        require!(
          current.status == "open" and before?(now, current.application_deadline) and
            before?(now, current.starts_at)
        )

        require_capacity!(current)

        application =
          unwrap!(
            Repo.insert(
              Application.changeset(
                %Application{
                  event_id: current.id,
                  user_id: user.id,
                  round: current.round,
                  fee_amount: current.fee_amount,
                  settlement_node_id: current.settlement_node_id,
                  payment_status: if(current.fee_amount > 0, do: "reserved", else: "none")
                },
                attrs
              )
            )
          )

        if application.fee_amount > 0,
          do:
            unwrap!(
              Grains.reserve_business(Repo, user.id, application.fee_amount, subject(application))
            )

        record!(current, user.id, application.id, "applied", nil, "pending")

        managers =
          if current.settlement_node_id,
            do: Rice.Community.admin_ids(Repo.get!(Node, current.settlement_node_id)),
            else: [current.creator_id]

        Enum.each(
          managers,
          &notify!(current, &1, user.id, "event_application_created", "有新的活动申请")
        )

        current
      end
    end)
  end

  def approve_application(user, event, application_id),
    do: change_application(user, event, application_id, "approved")

  def reject_application(user, event, application_id),
    do: change_application(user, event, application_id, "rejected")

  def remove_application(user, event, application_id),
    do: change_application(user, event, application_id, "removed")

  def withdraw_application(user, event, application_id),
    do: change_application(user, event, application_id, "withdrawn")

  defp change_application(user, event, application_id, target) do
    with_event(event.id, fn current ->
      if target != "withdrawn", do: require_host!(user, current)
      application = application!(current, application_id)
      if target == "withdrawn", do: require!(application.user_id == user.id, :forbidden)

      if application.status == target do
        current
      else
        if target == "removed",
          do: require!(current.status in ["open", "in_progress"]),
          else:
            require!(current.status == "open" and before?(DateTime.utc_now(), current.starts_at))

        require!(application.status == if(target == "removed", do: "approved", else: "pending"))

        if target == "approved" do
          require_capacity!(current)
          unwrap!(Repo.update(Changeset.change(application, status: "approved")))

          record!(
            current,
            user.id,
            application.id,
            "application_approved",
            application.status,
            target
          )

          notify!(current, application.user_id, user.id, "event_application_approved", "活动申请已通过")
        else
          refund_application!(current, application, user.id, target)
        end

        current
      end
    end)
  end

  def cancel(user, event) do
    with_event(event.id, fn current ->
      require_host!(user, current)

      cond do
        current.status == "cancelled" ->
          current

        current.status in ["draft", "open", "in_progress"] ->
          applications = active_applications(current)
          lock_accounts!(Enum.map(applications, & &1.user_id))
          Enum.each(applications, &refund_application!(current, &1, user.id, "cancelled"))
          change_event!(current, user.id, "cancelled", "cancelled")

        true ->
          Repo.rollback(:conflict)
      end
    end)
  end

  def finish(user, event) do
    with_event(event.id, fn current ->
      require_host!(user, current)

      if current.status == "completed" do
        current
      else
        now = DateTime.utc_now()
        require!(current.status in ["open", "in_progress"] and not before?(now, current.ends_at))
        # Acquire all relevant account locks in order before refunds and settlement.
        applications = active_applications(current)

        Grains.lock_business_accounts(
          Repo,
          Enum.map(applications, & &1.user_id) ++
            Enum.map(applications, &settlement_account(current, &1))
        )

        current = start_locked!(current, now)

        applications =
          Repo.all(
            from(a in Application,
              where:
                a.event_id == ^current.id and a.round == ^current.round and
                  a.status == "approved",
              order_by: a.user_id
            )
          )

        Enum.each(applications, fn application ->
          if application.fee_amount > 0 do
            require!(application.payment_status == "reserved", :grain_reservation_missing)

            unwrap!(
              Grains.settle_business(
                Repo,
                application.user_id,
                settlement_account(current, application),
                application.fee_amount,
                subject(application)
              )
            )

            unwrap!(Repo.update(Changeset.change(application, payment_status: "settled")))
          end

          record!(
            current,
            user.id,
            application.id,
            "application_completed",
            "approved",
            "approved"
          )

          notify!(current, application.user_id, user.id, "event_completed", "活动已结束")
        end)

        change_event!(current, user.id, "completed", "completed")
      end
    end)
  end

  def start_due_events(now \\ DateTime.utc_now()) do
    Repo.all(from(e in Event, where: e.status == "open" and e.starts_at <= ^now, select: e.id))
    |> Enum.reduce(:ok, fn id, result ->
      case start_event(id, now) do
        {:ok, _} -> result
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  def start_event(id, now \\ DateTime.utc_now()), do: with_event(id, &start_locked!(&1, now))

  def allowed_actions(_event, nil), do: []

  def allowed_actions(event, user) do
    now = DateTime.utc_now()
    host? = can_manage?(event, user)
    current = Enum.filter(event.applications, &(&1.round == event.round))
    own = Enum.find(current, &(&1.user_id == user.id))

    [
      {"edit",
       can_edit?(event, user) and
         event.status in ["draft", "open", "in_progress", "cancelled"]},
      {"publish", host? and event.status == "draft"},
      {"cancel", host? and event.status in ["draft", "open", "in_progress"]},
      {"finish",
       host? and event.status in ["open", "in_progress"] and not before?(now, event.ends_at)},
      {"apply",
       not host? and event.creator_id != user.id and is_nil(own) and event.status == "open" and
         before?(now, event.application_deadline) and before?(now, event.starts_at) and
         Enum.count(current, &(&1.status == "approved")) < event.capacity}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  def application_actions(_event, _application, nil), do: []

  def application_actions(event, application, user) do
    cond do
      application.round != event.round ->
        []

      application.user_id == user.id and application.status == "pending" and
        event.status == "open" and before?(DateTime.utc_now(), event.starts_at) ->
        ["withdraw"]

      can_manage?(event, user) ->
        cond do
          application.status == "pending" and event.status == "open" and
              before?(DateTime.utc_now(), event.starts_at) ->
            if Enum.count(
                 event.applications,
                 &(&1.round == event.round and &1.status == "approved")
               ) < event.capacity,
               do: ["approve", "reject"],
               else: ["reject"]

          application.status == "approved" and event.status in ["open", "in_progress"] ->
            ["remove"]

          true ->
            []
        end

      true ->
        []
    end
  end

  defp start_locked!(%Event{status: "open"} = event, now) do
    if before?(now, event.starts_at) do
      event
    else
      pending =
        Repo.all(
          from(a in Application,
            where: a.event_id == ^event.id and a.round == ^event.round and a.status == "pending",
            order_by: a.user_id
          )
        )

      lock_accounts!(Enum.map(pending, & &1.user_id))
      Enum.each(pending, &refund_application!(event, &1, nil, "not_selected"))
      change_event!(event, nil, "started", "in_progress")
    end
  end

  defp start_locked!(event, _now), do: event

  defp refund_application!(event, application, actor_id, status) do
    if application.fee_amount > 0 do
      require!(application.payment_status == "reserved", :grain_reservation_missing)

      unwrap!(
        Grains.refund_business(
          Repo,
          application.user_id,
          application.fee_amount,
          subject(application)
        )
      )
    end

    unwrap!(
      Repo.update(
        Changeset.change(application,
          status: status,
          payment_status: if(application.fee_amount > 0, do: "refunded", else: "none")
        )
      )
    )

    record!(event, actor_id, application.id, "application_#{status}", application.status, status)

    message =
      %{
        "rejected" => "活动申请未通过",
        "removed" => "活动报名已移除",
        "withdrawn" => "活动申请已撤销",
        "not_selected" => "活动已开始，本次未入选",
        "cancelled" => "活动已取消"
      }[status]

    message = if application.fee_amount > 0, do: message <> "，报名费已退回", else: message

    notify!(
      event,
      application.user_id,
      actor_id || event.creator_id,
      "event_application_#{status}",
      message
    )
  end

  defp active_applications(event),
    do:
      Repo.all(
        from(a in Application,
          where:
            a.event_id == ^event.id and a.round == ^event.round and
              a.status in ["pending", "approved"],
          order_by: a.user_id
        )
      )

  defp lock_accounts!(ids) do
    ids = Enum.uniq(ids)
    Repo.all(from(u in User, where: u.id in ^ids, order_by: u.id, lock: "FOR UPDATE"))
  end

  defp application!(event, id) do
    require!(Rice.Tsid.valid?(id), :not_found)

    Repo.get_by(Application, id: id, event_id: event.id, round: event.round) ||
      Repo.rollback(:not_found)
  end

  # Called only inside with_event's row lock, before creating an application or freezing its fee.
  defp require_capacity!(event) do
    count =
      Repo.aggregate(
        from(a in Application,
          where: a.event_id == ^event.id and a.round == ^event.round and a.status == "approved"
        ),
        :count
      )

    require!(count < event.capacity, :capacity_full)
  end

  defp with_event(id, fun) do
    if Rice.Tsid.valid?(id) do
      transaction(fn ->
        event =
          Repo.one(from(e in Event, where: e.id == ^id, lock: "FOR UPDATE")) ||
            Repo.rollback(:not_found)

        fun.(event)
      end)
    else
      {:error, :not_found}
    end
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, event} -> {:ok, preload(event)}
      error -> error
    end
  end

  def can_manage?(_event, nil), do: false

  def can_manage?(%Event{status: "draft", creator_id: creator_id} = event, user),
    do: creator_id == user.id and Rice.Community.admin?(Repo.get(Node, event.node_id), user)

  def can_manage?(%Event{settlement_node_id: nil, creator_id: id}, %User{id: user_id}),
    do: id == user_id

  def can_manage?(event, user), do: Rice.Community.admin?(Repo.get(Node, event.node_id), user)

  def can_edit?(%Event{status: "draft"} = event, user), do: can_manage?(event, user)

  def can_edit?(%Event{node_id: node_id}, %User{} = user),
    do: Rice.Community.admin?(Repo.get(Node, node_id), user)

  def can_edit?(_, _), do: false

  defp require_host!(user, event), do: require!(can_manage?(event, user), :forbidden)

  defp require_node!(user, node_id) do
    require!(Rice.Tsid.valid?(node_id), :forbidden)

    require!(
      Rice.Community.admin?(Repo.get(Node, node_id), user),
      :forbidden
    )
  end

  defp require!(true, _reason), do: :ok
  defp require!(_, reason), do: Repo.rollback(reason)
  defp require!(condition), do: require!(condition, :conflict)
  defp unwrap!({:ok, result}), do: result
  defp unwrap!({:error, reason}), do: Repo.rollback(reason)
  defp before?(time, other), do: DateTime.compare(time, other) == :lt
  defp subject(application), do: "rice://event_applications/#{application.id}"
  defp settlement_account(_event, %{settlement_node_id: id}) when not is_nil(id), do: {:node, id}
  defp settlement_account(event, _application), do: event.creator_id
  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)

  defp change_event!(event, actor, action, status, attrs \\ []) do
    saved = unwrap!(Repo.update(Changeset.change(event, Keyword.put(attrs, :status, status))))
    record!(event, actor, nil, action, event.status, status)
    saved
  end

  defp record!(event, actor_id, application_id, action, from_status, to_status) do
    unwrap!(
      Repo.insert(%EventHistory{
        event_id: event.id,
        round: event.round,
        actor_id: actor_id,
        application_id: application_id,
        action: action,
        from_status: from_status,
        to_status: to_status
      })
    )
  end

  defp notify!(event, recipient, actor, action, detail),
    do: unwrap!(Inbox.notify(Repo, recipient, actor, action, detail, "event", event.id))

  defp preload(events),
    do:
      Repo.preload(
        events,
        [
          image_links: :attachment,
          creator: :avatar,
          node: :logo,
          applications: {from(a in Application, order_by: a.id), [user: :avatar]},
          history: {from(h in EventHistory, order_by: h.id), [actor: :avatar]}
        ],
        force: true
      )
end

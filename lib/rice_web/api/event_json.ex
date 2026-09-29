defmodule RiceWeb.Api.EventJSON do
  alias Rice.Events
  alias RiceWeb.Api.{AttachmentJSON, UserJSON}

  def index(%{page: page} = assigns),
    do: %{
      data: Enum.map(page.entries, &data(&1, assigns[:current_user], false)),
      meta: Rice.Pagination.meta(page)
    }

  def show(%{event: event} = assigns), do: %{data: data(event, assigns[:current_user], true)}

  defp data(event, user, detail?) do
    current = Enum.filter(event.applications, &(&1.round == event.round))
    past = Enum.filter(event.applications, &(&1.round < event.round))
    own = if user, do: Enum.find(current, &(&1.user_id == user.id))

    visible_current =
      cond do
        not detail? or is_nil(user) -> []
        Events.can_manage?(event, user) -> current
        own -> [own]
        true -> []
      end

    visible_past =
      cond do
        not detail? or is_nil(user) -> []
        user.id == event.creator_id -> past
        true -> Enum.filter(past, &(&1.user_id == user.id))
      end

    visible_ids = MapSet.new(visible_current ++ visible_past, & &1.id)

    %{
      id: event.id,
      title: event.title,
      description: event.description,
      organizer_contact: event.organizer_contact,
      settlement_node_id: event.settlement_node_id,
      can_manage: Events.can_manage?(event, user),
      attachments: Enum.map(event.image_links, &AttachmentJSON.embed(&1.attachment)),
      status: event.status,
      round: event.round,
      location: event.location,
      node: %{
        id: event.node.id,
        name: event.node.name,
        logo: AttachmentJSON.embed(event.node.logo)
      },
      creator: UserJSON.public(event.creator),
      fee_amount: event.fee_amount,
      capacity: event.capacity,
      application_deadline: event.application_deadline,
      starts_at: event.starts_at,
      ends_at: event.ends_at,
      application_count: length(current),
      approved_count: Enum.count(current, &(&1.status == "approved")),
      my_application: if(own, do: application(own, event, user, detail?)),
      applications: Enum.map(visible_current, &application(&1, event, user)),
      past_applications: Enum.map(visible_past, &application(&1, event, user)),
      allowed_actions: Events.allowed_actions(event, user),
      history:
        if(detail?,
          do:
            event.history
            |> Enum.filter(fn item ->
              is_nil(item.application_id) or MapSet.member?(visible_ids, item.application_id)
            end)
            |> Enum.map(&history/1),
          else: []
        ),
      published_at: event.published_at,
      inserted_at: event.inserted_at,
      updated_at: event.updated_at
    }
  end

  defp application(item, event, user, detail? \\ true),
    do:
      %{
        id: item.id,
        user: UserJSON.public(item.user),
        reason: item.reason,
        status: item.status,
        payment_status: item.payment_status,
        fee_amount: item.fee_amount,
        round: item.round,
        settlement_node_id: item.settlement_node_id,
        allowed_actions: Events.application_actions(event, item, user),
        inserted_at: item.inserted_at,
        updated_at: item.updated_at
      }
      |> then(fn data -> if detail?, do: Map.put(data, :contact, item.contact), else: data end)

  defp history(item),
    do: %{
      id: item.id,
      action: item.action,
      round: item.round,
      from_status: item.from_status,
      to_status: item.to_status,
      before: item.before,
      after: item.after,
      actor: if(item.actor, do: UserJSON.public(item.actor)),
      inserted_at: item.inserted_at
    }
end

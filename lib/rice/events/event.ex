defmodule Rice.Events.Event do
  @moduledoc "社区活动；开始由系统推进，结束由主办方确认。"
  use Rice.Schema

  schema "events" do
    field :title, :string
    field :description, :string
    field :organizer_contact, :string
    field :location, :string
    field :status, :string, default: "draft"
    field :round, :integer, default: 1
    field :application_deadline, :utc_datetime_usec
    field :starts_at, :utc_datetime_usec
    field :ends_at, :utc_datetime_usec
    field :published_at, :utc_datetime_usec
    field :fee_amount, :integer, default: 0
    field :capacity, :integer
    field :client_request_id, :string
    belongs_to :creator, Rice.Accounts.User
    belongs_to :node, Rice.Community.Node
    belongs_to :settlement_node, Rice.Community.Node
    has_many :applications, Rice.Events.Application
    has_many :history, Rice.Events.EventHistory
    has_many :image_links, Rice.Events.Image, on_replace: :delete, preload_order: [asc: :position]
    timestamps()
  end

  def changeset(event, attrs, opts \\ []) do
    event
    |> cast(attrs, [
      :title,
      :description,
      :organizer_contact,
      :location,
      :application_deadline,
      :starts_at,
      :ends_at,
      :fee_amount,
      :capacity
    ])
    |> validate_required([
      :title,
      :description,
      :location,
      :application_deadline,
      :starts_at,
      :ends_at,
      :capacity,
      :node_id,
      :creator_id
    ])
    |> update_change(:title, &trim/1)
    |> update_change(:description, &trim/1)
    |> update_change(:organizer_contact, &trim/1)
    |> validate_length(:organizer_contact, max: 256)
    |> validate_organizer_contact()
    |> update_change(:location, &trim/1)
    |> validate_length(:title, min: 1, max: 128)
    |> validate_length(:description, min: 1, max: 8000)
    |> validate_length(:location, min: 1, max: 256)
    |> validate_number(:fee_amount,
      greater_than_or_equal_to: 0,
      less_than_or_equal_to: 2_147_483_647
    )
    |> validate_number(:capacity, greater_than: 0, less_than_or_equal_to: 100_000)
    |> validate_times(opts)
    |> foreign_key_constraint(:node_id)
    |> foreign_key_constraint(:creator_id)
    |> unique_constraint(:creator_id, name: :events_one_draft_per_creator)
    |> unique_constraint([:creator_id, :client_request_id])
    |> Rice.Files.put_images(attrs, Keyword.get(opts, :editing_user_id, event.creator_id))
  end

  def publish_changeset(event),
    do: event |> change() |> validate_required([:organizer_contact]) |> validate_times([])

  defp validate_organizer_contact(changeset) do
    if get_field(changeset, :status) == "draft",
      do: changeset,
      else: validate_required(changeset, [:organizer_contact])
  end

  defp validate_times(changeset, opts) do
    deadline = get_field(changeset, :application_deadline)
    starts = get_field(changeset, :starts_at)
    ends = get_field(changeset, :ends_at)

    changeset
    |> require_time(
      is_nil(deadline) or
        Keyword.get(opts, :published_edit, false) or
        DateTime.compare(deadline, DateTime.utc_now()) == :gt,
      :application_deadline,
      "报名截止时间必须在将来"
    )
    |> require_time(
      is_nil(deadline) or is_nil(starts) or DateTime.compare(deadline, starts) != :gt,
      :application_deadline,
      "报名截止不能晚于活动开始"
    )
    |> require_time(
      is_nil(starts) or is_nil(ends) or DateTime.compare(starts, ends) == :lt,
      :ends_at,
      "结束时间必须晚于开始时间"
    )
  end

  defp require_time(changeset, true, _, _), do: changeset
  defp require_time(changeset, false, field, message), do: add_error(changeset, field, message)
  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_), do: ""
end

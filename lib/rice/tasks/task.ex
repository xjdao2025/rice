defmodule Rice.Tasks.Task do
  @moduledoc "任务主体；新奖励由社区账户冻结，旧任务保留原个人出资账户。"
  use Rice.Schema

  @statuses ~w(draft open in_progress overdue under_review completed expired cancelled)

  schema "tasks" do
    field(:title, :string)
    field(:description, :string)
    field(:organizer_contact, :string)
    field(:status, :string, default: "open")
    field(:application_deadline, :utc_datetime_usec)
    field(:execution_deadline, :utc_datetime_usec)
    field(:requirement, :string, default: "")
    field(:client_request_id, :string)
    belongs_to(:node, Rice.Community.Node)
    belongs_to(:funding_node, Rice.Community.Node)
    field(:appointed_at, :utc_datetime_usec)
    field(:appointment_reason, :string)
    field(:reward_amount, :integer, default: 0)
    field(:reward_status, :string, default: "none")
    field(:reward_subject_uri, :string)
    field(:round, :integer, default: 1)
    field(:search_cursor, :string, virtual: true)

    belongs_to(:creator, Rice.Accounts.User)
    belongs_to(:assignee, Rice.Accounts.User)
    has_many(:applications, Rice.Tasks.Application)
    has_many(:submissions, Rice.Tasks.Submission)
    has_many(:events, Rice.Tasks.Event)
    has_many(:image_links, Rice.Tasks.Image, on_replace: :delete, preload_order: [asc: :position])

    timestamps()
  end

  @doc "发布者只能提交任务内容；身份与状态由服务端填写。"
  def create_changeset(task, attrs, opts \\ []) do
    task
    |> cast(attrs, [
      :title,
      :description,
      :organizer_contact,
      :requirement,
      :application_deadline,
      :execution_deadline,
      :reward_amount,
      :client_request_id
    ])
    |> validate_required([:title, :description])
    |> update_change(:title, &trim/1)
    |> update_change(:description, &trim/1)
    |> update_change(:organizer_contact, &trim/1)
    |> validate_length(:organizer_contact, max: 256)
    |> validate_organizer_contact()
    |> validate_length(:title, min: 1, max: 128)
    |> validate_length(:description, min: 1, max: 4000)
    |> validate_number(:reward_amount, greater_than_or_equal_to: 0)
    |> validate_execution_deadline(opts)
    |> validate_length(:requirement, max: 4000)
    |> validate_length(:client_request_id, max: 128)
    |> unique_constraint([:creator_id, :client_request_id])
    |> validate_future_deadline(opts)
    |> unique_constraint(:creator_id, name: :tasks_one_draft_per_creator)
    |> Rice.Files.put_images(attrs, Keyword.get(opts, :editing_user_id, task.creator_id))
  end

  def appointment_changeset(task, attrs) do
    task
    |> cast(attrs, [:appointment_reason])
    |> update_change(:appointment_reason, &optional_trim/1)
    |> validate_length(:appointment_reason, max: 512)
  end

  def publish_changeset(task) do
    task
    |> change()
    |> validate_required([:organizer_contact])
    |> validate_future_deadline([])
    |> validate_execution_deadline([])
  end

  defp validate_organizer_contact(changeset) do
    if get_field(changeset, :status) == "draft",
      do: changeset,
      else: validate_required(changeset, [:organizer_contact])
  end

  defp validate_execution_deadline(changeset, opts) do
    deadline = get_field(changeset, :execution_deadline)
    application = get_field(changeset, :application_deadline)

    if deadline &&
         ((not Keyword.get(opts, :published_edit, false) and
             DateTime.compare(deadline, DateTime.utc_now()) != :gt) ||
            (application && DateTime.compare(deadline, application) != :gt)),
       do: add_error(changeset, :execution_deadline, "交付时间须晚于现在及申请截止时间"),
       else: changeset
  end

  def statuses, do: @statuses

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(_), do: ""

  defp optional_trim(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp optional_trim(_), do: nil

  defp validate_future_deadline(changeset, opts) do
    case get_field(changeset, :application_deadline) do
      nil ->
        changeset

      deadline ->
        if Keyword.get(opts, :published_edit, false) or
             DateTime.compare(deadline, DateTime.utc_now()) == :gt,
           do: changeset,
           else: add_error(changeset, :application_deadline, "领取截止时间必须在将来")
    end
  end
end

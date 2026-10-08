defmodule Rice.Governance.Proposal do
  @moduledoc """
  提案(原 t_proposal)。

  `agree_count` / `oppose_count` 是计数缓存,但由投票时的原子自增维护,
  并且有测试断言它们与 `proposal_votes` 的实际行数一致。
  `total_votes` 被删掉了 —— 它等于两者之和,存第三份只是多一个不一致的机会。
  """
  use Rice.Schema

  @statuses ~w(open passed rejected)

  schema "proposals" do
    field :legacy_id, :string
    field :title, :string
    field :closes_at, :utc_datetime_usec
    field :status, :string, default: "open"
    field :agree_count, :integer, default: 0
    field :oppose_count, :integer, default: 0
    field :listed, :boolean, default: true
    field :deleted_at, :utc_datetime_usec

    belongs_to :user, Rice.Accounts.User
    belongs_to :attachment, Rice.Files.Attachment
    has_many :votes, Rice.Governance.Vote
    has_many :comments, Rice.Governance.Comment

    timestamps()
  end

  def changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [
      :legacy_id,
      :user_id,
      :title,
      :attachment_id,
      :closes_at,
      :status,
      :agree_count,
      :oppose_count,
      :listed
    ])
    |> validate_required([:title, :closes_at])
    |> validate_length(:title, min: 1, max: 128)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:attachment_id)
    |> unique_constraint(:legacy_id)
  end

  @doc "用户发起提案。status / 票数 / 上架状态都不由客户端决定。"
  def create_changeset(proposal, attrs) do
    proposal
    |> cast(attrs, [:title, :attachment_id, :closes_at])
    |> validate_required([:title, :closes_at])
    |> validate_length(:title, min: 1, max: 128)
    |> validate_future_deadline()
    |> foreign_key_constraint(:attachment_id)
  end

  defp validate_future_deadline(changeset) do
    case get_change(changeset, :closes_at) do
      nil ->
        changeset

      closes_at ->
        if DateTime.compare(closes_at, DateTime.utc_now()) == :gt,
          do: changeset,
          else: add_error(changeset, :closes_at, "截止时间必须在将来")
    end
  end

  def open?(%__MODULE__{status: "open", deleted_at: nil}), do: true
  def open?(%__MODULE__{}), do: false
end

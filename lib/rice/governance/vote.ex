defmodule Rice.Governance.Vote do
  @moduledoc """
  一票(原 t_vote_record)。

  `(proposal_id, user_id)` 上有唯一索引 —— core 靠应用层查重,并发能重复投。
  """
  use Rice.Schema

  @choices ~w(agree oppose)

  schema "proposal_votes" do
    field :legacy_id, :string
    field :choice, :string

    belongs_to :proposal, Rice.Governance.Proposal
    belongs_to :user, Rice.Accounts.User

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(vote, attrs) do
    vote
    |> cast(attrs, [:legacy_id, :proposal_id, :user_id, :choice])
    |> validate_required([:proposal_id, :user_id, :choice])
    |> validate_inclusion(:choice, @choices)
    |> foreign_key_constraint(:proposal_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:proposal_id, :user_id], message: "已经投过票了")
    |> unique_constraint(:legacy_id)
  end

  @spec choices() :: [String.t()]
  def choices, do: @choices
end

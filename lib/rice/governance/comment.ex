defmodule Rice.Governance.Comment do
  @moduledoc "提案评论(原 t_proposal_comment)。删掉了 user_name 副本。"
  use Rice.Schema

  schema "proposal_comments" do
    field :legacy_id, :string
    field :body, :string
    field :deleted_at, :utc_datetime_usec

    belongs_to :proposal, Rice.Governance.Proposal
    belongs_to :user, Rice.Accounts.User

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(comment, attrs) do
    comment
    |> cast(attrs, [:legacy_id, :proposal_id, :user_id, :body])
    |> validate_required([:proposal_id, :user_id, :body])
    |> update_change(:body, &String.trim/1)
    |> validate_length(:body, min: 1, max: 512)
    |> foreign_key_constraint(:proposal_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:legacy_id)
  end
end

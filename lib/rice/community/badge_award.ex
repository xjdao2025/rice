defmodule Rice.Community.BadgeAward do
  @moduledoc """
  某人获得某枚勋章(原 t_user_medal)。

  core 在这张表上复制了 5 列用户信息(昵称/头像/手机/区号/邮箱)——
  用户改昵称之后就是脏数据。这里只留外键。
  """
  use Rice.Schema

  schema "badge_awards" do
    field :legacy_id, :string
    field :awarded_at, :utc_datetime_usec

    belongs_to :badge, Rice.Community.Badge
    belongs_to :user, Rice.Accounts.User

    timestamps()
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(award, attrs) do
    award
    |> cast(attrs, [:legacy_id, :badge_id, :user_id, :awarded_at])
    |> validate_required([:badge_id, :user_id])
    |> put_awarded_at()
    |> foreign_key_constraint(:badge_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:badge_id, :user_id], message: "该用户已获得这枚勋章")
    |> unique_constraint(:legacy_id)
  end

  defp put_awarded_at(changeset) do
    if get_field(changeset, :awarded_at),
      do: changeset,
      else: put_change(changeset, :awarded_at, DateTime.utc_now())
  end
end

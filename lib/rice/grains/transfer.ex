defmodule Rice.Grains.Transfer do
  @moduledoc """
  一笔稻米流转(合并了 core 的 t_point_record 与 t_point_distribute_record)。

  `kind`:
    * `reward` 打赏 —— 对着某条帖子
    * `gift`   赠送 —— 点对点
    * `grant`  后台发放 —— 增发,`from_user_id` 为 NULL
    * `task_reward` 任务完成后发放 —— 只能由 Task 状态机写入
  """
  use Rice.Schema

  @kinds ~w(reward gift grant task_reward event_fee community_fund)

  schema "grain_transfers" do
    field :legacy_id, :string
    field :kind, :string
    field :amount, :integer
    field :memo, :string, default: ""
    field :subject_uri, :string

    belongs_to :from_user, Rice.Accounts.User
    belongs_to :to_user, Rice.Accounts.User
    belongs_to :from_node, Rice.Community.Node
    belongs_to :to_node, Rice.Community.Node

    timestamps()
  end

  def changeset(transfer, attrs) do
    transfer
    |> cast(attrs, [
      :kind,
      :from_user_id,
      :to_user_id,
      :from_node_id,
      :to_node_id,
      :amount,
      :memo,
      :subject_uri,
      :legacy_id
    ])
    |> validate_required([:kind, :amount])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:amount, greater_than: 0)
    |> validate_length(:memo, max: 256)
    |> validate_length(:subject_uri, max: 512)
    |> validate_not_self()
    |> validate_from_matches_kind()
    |> validate_account(:to_user_id, :to_node_id)
    |> foreign_key_constraint(:from_user_id)
    |> foreign_key_constraint(:to_user_id)
    |> foreign_key_constraint(:from_node_id)
    |> foreign_key_constraint(:to_node_id)
    |> unique_constraint(:legacy_id)
    |> check_constraint(:amount, name: :grain_transfers_amount_positive)
    |> check_constraint(:to_user_id, name: :grain_transfers_not_self, message: "不能转给自己")
    |> check_constraint(:from_user_id, name: :grain_transfers_from_matches_kind)
    |> check_constraint(:to_user_id, name: :grain_transfers_to_account)
    |> unique_constraint(:subject_uri, name: :grain_transfers_community_fund_request)
  end

  defp validate_not_self(changeset) do
    from = get_field(changeset, :from_user_id)
    to = get_field(changeset, :to_user_id)

    if from && from == to,
      do: add_error(changeset, :to_user_id, "不能转给自己"),
      else: changeset
  end

  # grant 是增发,没有付款方;reward/gift 必须有
  defp validate_from_matches_kind(changeset) do
    kind = get_field(changeset, :kind)
    from = get_field(changeset, :from_user_id) || get_field(changeset, :from_node_id)

    cond do
      kind == "grant" and not is_nil(from) ->
        add_error(changeset, :from_user_id, "后台发放不应有付款方")

      kind in ~w(reward gift task_reward event_fee community_fund) ->
        validate_account(changeset, :from_user_id, :from_node_id)

      true ->
        changeset
    end
  end

  defp validate_account(changeset, user_field, node_field) do
    if is_nil(get_field(changeset, user_field)) == is_nil(get_field(changeset, node_field)),
      do: add_error(changeset, user_field, "须指定一个账户"),
      else: changeset
  end

  def kinds, do: @kinds
end

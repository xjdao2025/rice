defmodule Rice.Accounts.User do
  @moduledoc """
  用户档案(原 t_user)。

  **rice 不存密码。** 密码权威是 PDS —— 登录就是拿 handle + 密码打
  `com.atproto.server.createSession`。这一点从 core 原样保留。
  """
  use Rice.Schema

  schema "users" do
    field :legacy_id, :string
    field :did, :string
    field :handle, :string
    field :email, :string
    field :phone, :string
    field :phone_region, :string, default: "86"
    field :nickname, :string, default: ""
    field :bio, :string, default: ""
    field :grain_balance, :integer, default: 0
    field :grain_frozen_balance, :integer, default: 0
    field :node_member, :boolean, default: false
    field :can_publish_tasks, :boolean, default: false
    field :disabled_at, :utc_datetime_usec
    field :deleted_at, :utc_datetime_usec

    # Semi 的钱包地址。不是 users 自己的列 —— 权威在 `semi_links.wallet_address`,
    # 由 `Accounts.put_semi_wallet/1` 在取当前用户时填进来。用虚拟字段而不是
    # 在视图里现查,是为了让 JSON 层保持"只读结构体"这条规矩。
    field :wallet_address, :string, virtual: true

    belongs_to :avatar, Rice.Files.Attachment

    timestamps()
  end

  @doc "注册时建档。did/handle 来自 PDS,不可由客户端指定。"
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:did, :handle, :email, :phone, :phone_region, :nickname, :legacy_id])
    |> validate_required([:did, :handle])
    |> validate_length(:handle, max: 256)
    |> validate_length(:did, max: 128)
    |> normalize_contacts()
    |> validate_contacts()
    |> unique_constraints()
  end

  @doc """
  从 core 的 `t_user` 建行(`mix rice.import`)。

  和 `registration_changeset/2` 的区别是它接受注册流程里不该由客户端决定的
  那几样:余额、节点身份、禁用与软删时刻、时间戳。

  **软删的用户必须导入。** 生产实测(§6.4⑤)里有 7 个软删用户,他们与存活用户
  之间有 1 个 handle 冲突和 5 个手机号冲突 —— 唯一索引带着 `where deleted_at
  is null`,正是为这件事准备的。不导的话,引用他们的流水和评论就成了断链。
  """
  def import_changeset(user, attrs) do
    user
    |> cast(attrs, [
      :legacy_id,
      :did,
      :handle,
      :email,
      :phone,
      :phone_region,
      :nickname,
      :bio,
      :avatar_id,
      :grain_balance,
      :grain_frozen_balance,
      :node_member,
      :can_publish_tasks,
      :disabled_at,
      :deleted_at,
      :inserted_at,
      :updated_at
    ])
    |> validate_required([:legacy_id, :did, :handle])
    |> validate_length(:handle, max: 256)
    |> validate_length(:did, max: 128)
    |> validate_length(:nickname, max: 64)
    |> validate_length(:bio, max: 512)
    |> validate_number(:grain_balance, greater_than_or_equal_to: 0)
    |> validate_number(:grain_frozen_balance, greater_than_or_equal_to: 0)
    |> normalize_contacts()
    |> validate_contacts()
    |> unique_constraints()
    |> foreign_key_constraint(:avatar_id)
  end

  @doc "用户自己能改的字段。did / handle / 余额 / 禁用状态都不在其中。"
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:nickname, :bio, :avatar_id])
    |> validate_length(:nickname, max: 64)
    |> validate_length(:bio, max: 512)
    |> foreign_key_constraint(:avatar_id)
  end

  @doc "改绑手机 / 邮箱。"
  def contact_changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :phone, :phone_region])
    |> normalize_contacts()
    |> validate_contacts()
    |> unique_constraints()
  end

  # 空串一律存成 NULL —— core 用 '' 表示"没有",导致唯一索引根本没法建
  defp normalize_contacts(changeset) do
    changeset
    |> update_change(:email, &blank_to_nil/1)
    |> update_change(:phone, &blank_to_nil/1)
    |> update_change(:email, fn v -> v && String.downcase(v) end)
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp validate_contacts(changeset) do
    changeset
    |> validate_format(:email, ~r/^[^@\s]+@[^@\s]+\.[^@\s]+$/, message: "邮箱格式不合法")
    |> validate_format(:phone, ~r/^\d{5,20}$/, message: "手机号不合法")
    |> validate_length(:phone_region, max: 8)
  end

  defp unique_constraints(changeset) do
    changeset
    |> unique_constraint(:did, name: :users_did_idx)
    |> unique_constraint(:handle, name: :users_handle_idx)
    |> unique_constraint(:email, name: :users_email_idx, message: "该邮箱已被使用")
    |> unique_constraint(:phone, name: :users_phone_idx, message: "该手机号已被使用")
    |> unique_constraint(:legacy_id)
  end

  def active?(%__MODULE__{disabled_at: nil, deleted_at: nil}), do: true
  def active?(%__MODULE__{}), do: false
end

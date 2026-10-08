defmodule Rice.Accounts.SemiLink do
  @moduledoc "Maps a Semi subject (`sub`) to the AT Protocol account rice owns for it."
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "semi_links" do
    field :semi_sub, :string
    field :did, :string
    field :handle, :string
    field :account_password_ciphertext, :binary
    # Semi 侧的 EVM 地址,来自 userinfo 的 `wallet_address`(需 `wallet` scope)。
    # 每次登录刷新 —— 用户可能是先注册、后绑钱包。
    field :wallet_address, :string

    timestamps(type: :utc_datetime_usec)
  end

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    link
    |> cast(attrs, [:semi_sub, :did, :handle, :account_password_ciphertext, :wallet_address])
    |> validate_required([:semi_sub, :did, :handle, :account_password_ciphertext])
    |> unique_constraint(:semi_sub)
    |> unique_constraint(:did)
  end
end

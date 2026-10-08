defmodule Rice.Accounts.ApiToken do
  @moduledoc """
  不透明访问令牌。库里只有 sha256,明文仅在签发时返回一次。

  相对 core 的 daoJwt(RS256,私钥放在 Redis 给两个服务共用)的实际差别:
  **可撤销**。禁用用户 = 删他的 token 行,立即生效;JWT 只能等 30 天过期。
  """
  use Rice.Schema

  @rand_bytes 32
  @default_validity_days 30

  schema "api_tokens" do
    field :token_hash, :binary
    field :context, :string, default: "client"
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec

    belongs_to :user, Rice.Accounts.User

    timestamps()
  end

  @doc "生成 `{明文, changeset}`。明文只此一次,之后无法从库里还原。"
  @spec build(Rice.Accounts.User.t(), keyword()) :: {String.t(), Ecto.Changeset.t()}
  def build(user, opts \\ []) do
    plaintext = :crypto.strong_rand_bytes(@rand_bytes) |> Base.url_encode64(padding: false)
    days = Keyword.get(opts, :validity_days, @default_validity_days)

    changeset =
      change(%__MODULE__{},
        user_id: user.id,
        token_hash: hash(plaintext),
        context: Keyword.get(opts, :context, "client"),
        expires_at: DateTime.add(DateTime.utc_now(), days * 24 * 3600, :second)
      )

    {plaintext, changeset}
  end

  @spec hash(String.t()) :: binary()
  def hash(plaintext), do: :crypto.hash(:sha256, plaintext)
end

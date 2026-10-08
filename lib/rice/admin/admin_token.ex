defmodule Rice.Admin.AdminToken do
  @moduledoc """
  管理端的不透明令牌。单独一张表,不和 C 端的 `api_tokens` 混 ——
  同一张表加个 context 列的话,写错一个 where 就是把管理员权限发给普通用户。

  有效期比 C 端短:管理端能改配置、发稻米、下架内容,一把令牌泄漏的代价更大。
  """
  use Rice.Schema

  @rand_bytes 32
  @default_validity_days 7

  schema "admin_tokens" do
    field :token_hash, :binary
    field :expires_at, :utc_datetime_usec
    field :last_used_at, :utc_datetime_usec

    belongs_to :admin_user, Rice.Admin.AdminUser

    timestamps()
  end

  @doc "生成 `{明文, changeset}`。明文只此一次。"
  def build(admin, opts \\ []) do
    plaintext = :crypto.strong_rand_bytes(@rand_bytes) |> Base.url_encode64(padding: false)
    days = Keyword.get(opts, :validity_days, @default_validity_days)

    changeset =
      change(%__MODULE__{},
        admin_user_id: admin.id,
        token_hash: hash(plaintext),
        expires_at: DateTime.add(DateTime.utc_now(), days * 24 * 3600, :second)
      )

    {plaintext, changeset}
  end

  def hash(plaintext), do: :crypto.hash(:sha256, plaintext)
end

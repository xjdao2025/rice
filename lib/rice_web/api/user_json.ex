defmodule RiceWeb.Api.UserJSON do
  alias RiceWeb.Api.AttachmentJSON

  def show(%{user: user}), do: %{data: data(user)}

  @doc "自己看自己 —— 含手机、邮箱这类私有字段。"
  def data(user) do
    %{
      id: user.id,
      did: user.did,
      handle: user.handle,
      nickname: user.nickname,
      bio: user.bio,
      avatar: AttachmentJSON.embed(user.avatar),
      grain_balance: user.grain_balance,
      grain_frozen_balance: user.grain_frozen_balance,
      node_member: user.node_member,
      can_publish_tasks: user.can_publish_tasks,
      email: user.email,
      phone: user.phone,
      phone_region: user.phone_region,
      # Semi 登录用户的钱包地址(来自 semi_links,由 Accounts.put_semi_wallet/1
      # 填进虚拟字段)。非 Semi 用户是 null。**只在这里出现,不进 public/1** ——
      # 地址本身在链上是公开的,但和社交身份绑一起就把可关联性拉高了,
      # 该不该外露是产品决定,不是默认行为。
      wallet_address: user.wallet_address,
      inserted_at: user.inserted_at
    }
  end

  @doc "别人看你 —— 联系方式不外露。"
  def public(user) do
    %{
      id: user.id,
      did: user.did,
      handle: user.handle,
      nickname: user.nickname,
      bio: user.bio,
      avatar: AttachmentJSON.embed(user.avatar),
      node_member: user.node_member
    }
  end
end

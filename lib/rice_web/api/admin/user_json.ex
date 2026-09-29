defmodule RiceWeb.Api.Admin.UserJSON do
  @moduledoc """
  后台看到的用户。比 C 端的 public 视图多了手机、邮箱和停用状态 ——
  后台就是靠这些找人的。
  """
  alias RiceWeb.Api.AttachmentJSON

  def index(%{page: page}) do
    %{data: Enum.map(page.entries, &data/1), meta: Rice.Pagination.meta(page)}
  end

  def show(%{user: user}), do: %{data: data(user)}

  def data(user) do
    %{
      id: user.id,
      did: user.did,
      handle: user.handle,
      nickname: user.nickname,
      bio: user.bio,
      avatar: AttachmentJSON.embed(user.avatar),
      grain_balance: user.grain_balance,
      node_member: user.node_member,
      can_publish_tasks: user.can_publish_tasks,
      email: user.email,
      phone: user.phone,
      phone_region: user.phone_region,
      disabled: not is_nil(user.disabled_at),
      disabled_at: user.disabled_at,
      inserted_at: user.inserted_at
    }
  end
end

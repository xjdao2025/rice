defmodule RiceWeb.Api.ModerationController do
  @moduledoc """
  发帖前审核。帖子直接写进用户自己的 PDS,不经过 rice,所以由前端在写之前来问一次;
  图片是已经传上 PDS 的 blob,按 CID 给出,阿里云从 PDS 的公开地址取图。
  """
  use RiceWeb, :controller

  action_fallback RiceWeb.Api.FallbackController

  def check(conn, params) do
    user = conn.assigns.current_user
    pds = Application.fetch_env!(:rice, :pds)[:public_url]

    images =
      for cid <- List.wrap(params["images"]),
          is_binary(cid),
          do:
            "#{pds}/xrpc/com.atproto.sync.getBlob?" <>
              URI.encode_query(%{did: user.did, cid: cid})

    # 一帖最多 9 张图,和前端一致;多出来的不能悄悄跳过不审
    with true <- length(images) <= 9 || {:error, :unprocessable_entity},
         :ok <- Rice.RateLimit.hit({:moderation, user.id}, 120, 3600) do
      case Rice.Moderation.check(params["text"], images) do
        :ok -> json(conn, %{data: %{allowed: true}})
        {:blocked, _reasons} -> {:error, :content_blocked}
        {:error, :unavailable} -> {:error, :moderation_unavailable}
      end
    end
  end
end

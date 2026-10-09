defmodule RiceWeb.ThumbController do
  @moduledoc "帖子图片和头像的缩略图,见 `Rice.Thumbs`。公开,不需要登录。"
  use RiceWeb, :controller

  def show(conn, %{"preset" => preset, "did" => did, "cid" => cid}) do
    case Rice.Thumbs.fetch(preset, did, cid) do
      {:ok, path, type} ->
        conn
        |> put_resp_content_type(type, nil)
        # 内容按 CID 不可变;只缓存一周,给 PDS 下架留个上限
        |> put_resp_header("cache-control", "public, max-age=604800")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_file(200, path)

      {:error, :not_found} ->
        send_resp(conn, 404, "")
    end
  end
end

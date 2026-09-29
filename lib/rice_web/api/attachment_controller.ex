defmodule RiceWeb.Api.AttachmentController do
  @moduledoc """
  附件读取与上传。

  **上传必须认证。** core 的 `/api/v1/file/upload` 标着 `AllowAnonymous` ——
  任何人都能往服务器写文件,没有身份、没有配额。这里由路由上的
  `require_authenticated_user` 拦住,并且大小和类型都在 `Rice.Files` 里校验。
  """
  use RiceWeb, :controller

  alias Rice.Files

  action_fallback RiceWeb.Api.FallbackController

  @doc "上传。需要登录;大小上限 20MB,content-type 走白名单。"
  def create(conn, %{"file" => %Plug.Upload{} = upload} = params) do
    kind = if params["kind"] in ["file"], do: "file", else: "image"

    with {:ok, content} <- File.read(upload.path),
         {:ok, attachment} <-
           Files.create_attachment(
             content,
             %{
               kind: kind,
               # 只取 basename:客户端可以在 filename 里塞路径
               filename: Path.basename(upload.filename || "unnamed"),
               content_type: upload.content_type
             },
             if(conn.assigns[:current_user], do: conn.assigns.current_user.id)
           ) do
      conn
      |> put_status(:created)
      |> put_view(json: RiceWeb.Api.AttachmentJSON)
      |> render(:show, attachment: attachment)
    else
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset}
      {:error, _reason} -> {:error, :unprocessable_entity}
    end
  end

  def create(conn, _params) do
    conn |> put_status(:unprocessable_entity) |> json(%{errors: %{file: ["缺少上传文件"]}})
  end

  def show(conn, %{"id" => id}) do
    with {:ok, attachment} <- Files.fetch_attachment(id),
         {:ok, content} <- read(attachment) do
      conn
      |> put_resp_content_type(attachment.content_type || "application/octet-stream", nil)
      |> put_resp_header("content-disposition", disposition(conn, attachment))
      # 附件内容按 id 不可变(改内容就是新 id),可以放心长缓存
      |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
      |> put_resp_header("etag", etag(attachment))
      # 别让浏览器去猜类型 —— 猜出个 text/html 就等于绕过了下面那道防线
      |> put_resp_header("x-content-type-options", "nosniff")
      # 就算真被当页面打开了,这条也让脚本、取数、表单一律动不了
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> send_resp(200, content)
    end
  end

  # 元数据在但字节还没回填 —— 对客户端就是"还没有",不是 500
  defp read(attachment) do
    case Files.read(attachment) do
      {:ok, content} -> {:ok, content}
      {:error, :not_stored} -> {:error, :not_found}
      other -> other
    end
  end

  # 浏览器打开就会执行脚本的类型。附件是**公开可读**的,而上传只要登录 ——
  # 任何用户都能传一个 html 上去,再把链接发给别人。在 rice 同源下打开它,
  # 脚本就拿到了这个源(比如 Semi 登录交接用的会话 cookie)。
  @executable ~w(text/html application/xhtml+xml image/svg+xml)

  # 默认内联展示(banner 图要内联),`?download=1` 时强制下载。
  #
  # **可执行类型一律强制下载**,不管 `download` 传没传。这不影响任何人:
  # 公告正文两端都是 `fetch()` 之后自己渲染的,而 `fetch` 根本不看这个头;
  # `<img>` 也不看。受影响的只有"直接在浏览器地址栏里打开附件"这一种用法,
  # 而那正是要挡的。
  #
  # 文件名做 RFC 5987 编码 —— 线上文件名含中文、空格和全角括号,
  # 直接塞进头里会被截断甚至构造出额外的响应头。
  defp disposition(conn, attachment) do
    forced = attachment.content_type in @executable
    asked = conn.params["download"] in ~w(1 true)
    kind = if forced or asked, do: "attachment", else: "inline"

    "#{kind}; filename*=UTF-8''#{URI.encode(attachment.filename, &URI.char_unreserved?/1)}"
  end

  @doc false
  def executable_types, do: @executable

  defp etag(%{checksum: nil, id: id}), do: ~s("#{id}")
  defp etag(%{checksum: checksum}), do: ~s("#{checksum}")
end

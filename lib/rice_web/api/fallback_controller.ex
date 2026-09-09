defmodule RiceWeb.Api.FallbackController do
  @moduledoc """
  控制器返回非 `%Plug.Conn{}` 时的兜底。

  core 的做法是 HTTP 永远 200,靠信封里的 `{code, message}` 表达失败。这里回到
  HTTP 状态码本身,body 统一是 `{"errors": ...}`。
  """
  use Phoenix.Controller, formats: [:json]

  import Plug.Conn, only: [put_status: 2]

  alias RiceWeb.Api.ErrorJSON

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: ErrorJSON)
    |> render(:"404")
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> put_view(json: ErrorJSON)
    |> render(:"401")
  end

  def call(conn, {:error, :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> put_view(json: ErrorJSON)
    |> render(:"403")
  end

  def call(conn, {:error, reason})
      when reason in [
             :invalid_ticket,
             :missing_handle,
             :weak_password,
             :invalid_amount,
             :invalid_listed,
             :cannot_delete_superuser,
             :cannot_delete_self,
             :unprocessable_entity
           ] do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{detail: detail(reason)}})
  end

  # 服务端自己的问题,别伪装成客户端错误 —— 422 会让调用方以为换个文件就好了。
  def call(conn, {:error, :storage_unavailable}) do
    conn
    |> put_status(:internal_server_error)
    |> json(%{errors: %{detail: "文件存储暂时不可用,请稍后再试或联系管理员"}})
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:changeset, changeset: changeset)
  end

  defp detail(:invalid_ticket), do: "注册票据无效或已过期,请重新验证"
  defp detail(:missing_handle), do: "缺少 handle"
  defp detail(:weak_password), do: "密码至少 8 位"
  defp detail(:invalid_amount), do: "金额必须是正整数"
  defp detail(:invalid_listed), do: "listed 必须是 true 或 false"
  defp detail(:cannot_delete_superuser), do: "超级管理员不能删除"
  defp detail(:cannot_delete_self), do: "不能删除自己"
  defp detail(:unprocessable_entity), do: "请求无法处理"
end

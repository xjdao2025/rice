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

  def call(conn, {:error, :conflict}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "资源状态已经变化，请刷新后重试"}})
  end

  def call(conn, {:error, :capacity_full}) do
    conn |> put_status(:conflict) |> json(%{errors: %{detail: "活动已满，暂无可用名额"}})
  end

  def call(conn, {:error, :missing_request_id}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{client_request_id: ["缺少有效请求标识"]}})
  end

  def call(conn, {:error, :insufficient_balance}) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{errors: %{amount: ["可用稻米不足"]}})
  end

  def call(conn, {:error, :grain_reservation_missing}) do
    conn
    |> put_status(:conflict)
    |> json(%{errors: %{detail: "资金记录暂时无法处理，本次操作未生效"}})
  end

  def call(conn, {:error, reason})
      when reason in [
             :invalid_ticket,
             :invalid_username,
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

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:changeset, changeset: changeset)
  end

  defp detail(:invalid_ticket), do: "注册票据无效或已过期,请重新验证"
  defp detail(:invalid_username), do: "用户名须为 3–18 位字母、数字或连字符，首尾须为字母或数字"
  defp detail(:weak_password), do: "密码至少 8 位"
  defp detail(:invalid_amount), do: "金额必须是正整数"
  defp detail(:invalid_listed), do: "listed 必须是 true 或 false"
  defp detail(:cannot_delete_superuser), do: "超级管理员不能删除"
  defp detail(:cannot_delete_self), do: "不能删除自己"
  defp detail(:unprocessable_entity), do: "请求无法处理"
end

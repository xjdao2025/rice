defmodule RiceWeb.Api.FallbackController do
  @moduledoc """
  控制器返回非 `%Plug.Conn{}` 时的兜底。

  core 的做法是 HTTP 永远 200,靠信封里的 `{code, message}` 表达失败。这里回到
  HTTP 状态码本身,body 统一是 `{"errors": ...}`。
  """
  use Phoenix.Controller, formats: [:json]

  import Plug.Conn, only: [put_status: 2]

  alias RiceWeb.Api.ErrorJSON

  @rendered %{not_found: :"404", unauthorized: :"401", forbidden: :"403"}

  # 错误原因 → {状态码, errors}。文案是对外契约,改一个字前端就要跟着改。
  @errors %{
    conflict: {:conflict, %{detail: "资源状态已经变化，请刷新后重试"}},
    too_many_requests: {:too_many_requests, %{detail: "操作太频繁，请稍后再试"}},
    capacity_full: {:conflict, %{detail: "人数已满，暂无可用名额"}},
    grain_reservation_missing: {:conflict, %{detail: "资金记录暂时无法处理，本次操作未生效"}},
    missing_request_id: {:unprocessable_entity, %{client_request_id: ["缺少有效请求标识"]}},
    insufficient_balance: {:unprocessable_entity, %{amount: ["可用稻米不足"]}},
    invalid_ticket: {:unprocessable_entity, %{detail: "注册票据无效或已过期,请重新验证"}},
    invalid_username: {:unprocessable_entity, %{detail: "用户名须为 3–18 位字母、数字或连字符，首尾须为字母或数字"}},
    weak_password: {:unprocessable_entity, %{detail: "密码至少 8 位"}},
    invalid_amount: {:unprocessable_entity, %{detail: "金额必须是正整数"}},
    invalid_listed: {:unprocessable_entity, %{detail: "listed 必须是 true 或 false"}},
    cannot_delete_superuser: {:unprocessable_entity, %{detail: "超级管理员不能删除"}},
    cannot_delete_self: {:unprocessable_entity, %{detail: "不能删除自己"}},
    unprocessable_entity: {:unprocessable_entity, %{detail: "请求无法处理"}},
    # 验证码
    too_many_attempts: {:too_many_requests, %{detail: "尝试次数过多,请重新获取验证码"}},
    code_expired: {:unprocessable_entity, %{code: ["验证码已过期"]}},
    invalid_code: {:unprocessable_entity, %{code: ["验证码不正确"]}},
    # 转账收款人
    recipient_not_found: {:unprocessable_entity, %{to: ["接收用户不存在"]}},
    recipient_disabled: {:unprocessable_entity, %{to: ["接收用户已被禁用"]}},
    cannot_transfer_to_self: {:unprocessable_entity, %{to: ["不能转给自己"]}},
    invalid_reward_post: {:unprocessable_entity, %{subject_uri: ["赞赏帖子与接收人不匹配"]}}
  }

  def call(conn, {:error, reason}) when is_map_key(@rendered, reason) do
    conn
    |> put_status(reason)
    |> put_view(json: ErrorJSON)
    |> render(@rendered[reason])
  end

  def call(conn, {:error, reason}) when is_map_key(@errors, reason) do
    {status, errors} = @errors[reason]
    conn |> put_status(status) |> json(%{errors: errors})
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:changeset, changeset: changeset)
  end
end

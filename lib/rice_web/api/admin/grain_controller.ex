defmodule RiceWeb.Api.Admin.GrainController do
  @moduledoc """
  后台发放稻米与查明细。

  core 的 single / batch 在这里是同一个 POST —— 收款人永远是个数组,
  发一个人就是长度为 1。
  """
  use RiceWeb, :controller

  alias Rice.Admin.Grants

  action_fallback RiceWeb.Api.FallbackController

  def index(conn, params), do: render(conn, :index, page: Grants.list_grants(params))

  @doc """
  发一个发放验证码到当前管理员自己的手机上。

  发稻米动的是钱。令牌可能被人从浏览器里捞走,短信在管理员自己手上 ——
  core 就要求这一步,不能因为改成 REST 就丢掉。
  """
  def challenge(conn, _params) do
    case Rice.Admin.send_grant_code(conn.assigns.current_admin) do
      {:ok, _} ->
        send_resp(conn, :accepted, "")

      {:error, :too_many_requests} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{errors: %{detail: "操作过于频繁,请稍后再试"}})

      {:error, :contact_not_set} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{detail: "该管理员没有绑定手机号"}})

      {:error, _} ->
        conn |> put_status(:bad_gateway) |> json(%{errors: %{detail: "验证码发送失败"}})
    end
  end

  @doc """
  发放。顺序是**先校验参数,再验短信码,最后动账**。

  验证码是一次性的,而发放常常是从表格里粘几百个手机号 —— 先验码的话,
  一个笔误就把码烧掉了,还得等 60 秒重发。参数校验不写任何东西,放前面没有风险;
  码留到真要动账之前那一刻验。
  """
  def create(conn, params) do
    recipients = List.wrap(params["to"])
    amount = params["amount"]

    with {:ok, users} <- Grants.prepare(recipients, amount),
         :ok <- Rice.Admin.verify_grant_code(conn.assigns.current_admin, params["code"]),
         {:ok, count} <- Grants.credit(users, amount, memo: params["memo"]) do
      conn |> put_status(:created) |> json(%{data: %{granted: count}})
    else
      error -> handle(conn, error)
    end
  end

  @doc "向节点独立账户发放，使用与个人发放相同的管理员验证码。"
  def create_node(conn, %{"node_id" => node_id} = params) do
    case Grants.grant_node(
           conn.assigns.current_admin,
           node_id,
           params["amount"],
           params["client_request_id"],
           params["code"],
           memo: params["memo"]
         ) do
      {:ok, transfer, status} ->
        conn
        |> put_status(if(status == :created, do: :created, else: :ok))
        |> json(%{
          data: %{
            id: transfer.id,
            amount: transfer.amount,
            memo: transfer.memo,
            to_node_id: transfer.to_node_id,
            replayed: status == :replayed
          }
        })

      error ->
        handle(conn, error)
    end
  end

  defp handle(conn, error) do
    case error do
      # 验证码不对 / 过期,和登录时给的是同一类响应
      {:error, :too_many_attempts} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{errors: %{detail: "尝试次数过多,请重新获取验证码"}})

      {:error, reason} when reason in [:invalid_code, :code_expired, :contact_not_set] ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{code: [code_message(reason)]}})

      {:error, {:unknown_recipients, missing}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{to: ["这些收款人不存在: " <> Enum.join(missing, ", ")]}})

      {:error, {:invalid_recipients, bad}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          errors: %{to: ["收款人必须是字符串,这些不是: " <> Enum.map_join(bad, ", ", &inspect/1)]}
        })

      {:error, :no_recipients} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: %{to: ["至少要有一个收款人"]}})

      {:error, :invalid_amount} ->
        {:error, :invalid_amount}

      {:error, reason} when reason in [:not_found, :conflict, :missing_request_id] ->
        {:error, reason}

      {:error, %Ecto.Changeset{} = cs} ->
        {:error, cs}
    end
  end

  defp code_message(:code_expired), do: "验证码已过期"
  defp code_message(:contact_not_set), do: "该管理员没有绑定手机号"
  defp code_message(_), do: "验证码不正确"

  @doc "某个用户的稻米明细。core 是 /admin/score/user-sore-record-page。"
  def transfers(conn, %{"user_id" => user_id} = params) do
    with {:ok, user} <- Rice.Admin.Users.fetch_user(user_id) do
      render(conn, :transfers, page: Rice.Grains.list_transfers(user, params), user: user)
    end
  end
end

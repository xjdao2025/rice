defmodule RiceWeb.Api.Admin.GrainController do
  @moduledoc """
  后台发放稻米与查明细。

  单个和批量增发均进入节点钱包；历史个人增发记录仍可查询。
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

  节点、金额和备注验证通过后才消耗验证码；失败不会部分入账。
  """
  def create(conn, params) do
    # 明确拒绝旧版个人收款参数，不能静默将其解释成节点。
    if Map.has_key?(params, "to") do
      unprocessable(conn, %{to: ["稻米只能增发给节点，请选择节点"]})
    else
      with {:ok, count, status} <-
             Grants.grant_nodes(
               conn.assigns.current_admin,
               params["node_ids"],
               params["amount"],
               params["client_request_id"],
               params["code"],
               memo: params["memo"]
             ) do
        conn
        |> put_status(if(status == :created, do: :created, else: :ok))
        |> json(%{data: %{granted: count, replayed: status == :replayed}})
      else
        error -> grant_error(conn, error)
      end
    end
  end

  @doc "向单个节点增发，使用当前平台管理员的增发验证码。"
  def create_node(conn, %{"node_id" => node_id} = params) do
    with {:ok, transfer, status} <-
           Grants.grant_node(
             conn.assigns.current_admin,
             node_id,
             params["amount"],
             params["client_request_id"],
             params["code"],
             memo: params["memo"]
           ) do
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
    else
      error -> grant_error(conn, error)
    end
  end

  # 验证码错误(和登录同一类响应)、金额、冲突等交给 fallback;这里只管发放特有的几种
  defp grant_error(conn, {:error, :contact_not_set}),
    do: unprocessable(conn, %{code: ["该管理员没有绑定手机号"]})

  defp grant_error(_conn, error), do: error

  defp unprocessable(conn, errors),
    do: conn |> put_status(:unprocessable_entity) |> json(%{errors: errors})

  @doc "某个用户的稻米明细。core 是 /admin/score/user-sore-record-page。"
  def transfers(conn, %{"user_id" => user_id} = params) do
    with {:ok, user} <- Rice.Admin.Users.fetch_user(user_id) do
      render(conn, :transfers, page: Rice.Grains.list_transfers(user, params), user: user)
    end
  end
end

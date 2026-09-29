defmodule RiceWeb.Api.RegistrationController do
  @moduledoc """
  注册。替代 core 的 `/user/pre-register` + `/user/register`。

  core 把预注册票放在 Redis 的一个 hash 里(30 分钟 TTL),这里改成签名票据:
  验证码校验通过后签发,注册时验签。没有服务端状态,也就没有"Redis 重启后
  用户卡在注册中途"这种问题。
  """
  use RiceWeb, :controller

  alias Rice.Accounts

  action_fallback RiceWeb.Api.FallbackController

  @ticket_salt "registration ticket"
  @ticket_max_age 1800

  @doc "第一步:校验验证码,换一张注册票。"
  def verify(conn, params) do
    channel = params["channel"]
    {target, contact} = contact_for(channel, params)

    case Accounts.verify_code(channel, target, "register", params["code"] || "") do
      :ok ->
        ticket = Phoenix.Token.sign(RiceWeb.Endpoint, @ticket_salt, contact)
        json(conn, %{data: %{ticket: ticket, expires_in: @ticket_max_age}})

      {:error, :too_many_attempts} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{errors: %{detail: "尝试次数过多,请重新获取验证码"}})

      {:error, :code_expired} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{code: ["验证码已过期"]}})

      {:error, _} ->
        conn |> put_status(:unprocessable_entity) |> json(%{errors: %{code: ["验证码不正确"]}})
    end
  end

  @doc "第二步:凭票 + 用户名前缀 + 密码完成注册,完整账号标识由服务端拼接。"
  def create(conn, params) do
    with {:ok, contact} <- verify_ticket(params["ticket"]),
         {:ok, username} <- fetch_username(params),
         {:ok, password} <- fetch_password(params) do
      attrs =
        contact
        |> atomize()
        |> Map.merge(%{
          handle: "#{username}.#{Rice.PDS.Api.impl().handle_domain()}",
          password: password
        })

      case Accounts.register(attrs) do
        {:ok, result} ->
          conn
          |> put_status(:created)
          |> put_view(json: RiceWeb.Api.SessionJSON)
          |> render(:show, result)

        {:error, :contact_taken} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{errors: %{detail: "该手机号或邮箱已被使用"}})

        {:error, %Ecto.Changeset{} = changeset} ->
          {:error, changeset}

        {:error, reason} ->
          registration_error(conn, reason)
      end
    end
  end

  defp verify_ticket(ticket) when is_binary(ticket) do
    case Phoenix.Token.verify(RiceWeb.Endpoint, @ticket_salt, ticket, max_age: @ticket_max_age) do
      {:ok, contact} -> {:ok, contact}
      {:error, _} -> {:error, :invalid_ticket}
    end
  end

  defp verify_ticket(_), do: {:error, :invalid_ticket}

  # 与当前 PDS 服务子域规则一致;客户端只能选择前缀,不能覆盖域名。
  defp fetch_username(%{"username" => username}) when is_binary(username) do
    username = username |> String.trim() |> String.downcase()

    if byte_size(username) in 3..18 and
         Regex.match?(~r/\A[a-z0-9][a-z0-9-]*[a-z0-9]\z/, username),
       do: {:ok, username},
       else: {:error, :invalid_username}
  end

  defp fetch_username(_), do: {:error, :invalid_username}

  defp registration_error(conn, {:pds, "com.atproto.server.createAccount", 400, error})
       when is_binary(error) do
    if error == "HandleNotAvailable" or
         String.starts_with?(error, [
           "HandleNotAvailable:",
           "InvalidRequest: Handle already taken:"
         ]) do
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{errors: %{detail: "用户名已被使用，请换一个用户名"}})
    else
      registration_error(conn, :pds_error)
    end
  end

  defp registration_error(conn, _) do
    conn |> put_status(:bad_gateway) |> json(%{errors: %{detail: "创建账号失败"}})
  end

  # 密码不落 rice 的库,但长度还是要挡一道 —— PDS 那边的下限是 8
  defp fetch_password(%{"password" => password})
       when is_binary(password) and byte_size(password) >= 8,
       do: {:ok, password}

  defp fetch_password(_), do: {:error, :weak_password}

  defp contact_for("sms", params) do
    region = params["phone_region"] || "86"
    phone = params["phone"] || ""
    {Rice.Accounts.phone_target(region, phone), %{"phone" => phone, "phone_region" => region}}
  end

  defp contact_for("email", params) do
    email = params["email"] || ""
    {email, %{"email" => email}}
  end

  defp contact_for(_, _), do: {"", %{}}

  defp atomize(map), do: Map.new(map, fn {k, v} -> {String.to_existing_atom(k), v} end)
end

defmodule RiceWeb.Api.Admin.SettingsController do
  @moduledoc """
  全站配置。core 有 detail + modify-foundation-info + modify-proposal-config
  三个接口,改的却是同一行 —— 这里是 GET 和 PATCH 各一个。
  """
  use RiceWeb, :controller

  action_fallback RiceWeb.Api.FallbackController

  def show(conn, _params), do: render(conn, :show, site: Rice.Settings.get_site())

  # 提案配置运营也能改;金库公示只给 role=admin(管理端菜单同样只对 admin 开放)
  def update(conn, params) do
    fields =
      case conn.assigns.current_admin.role do
        "admin" -> ~w(fund_scale issued_grain_scale proposal_approval_votes document_ids)
        _ -> ~w(proposal_approval_votes)
      end

    attrs = Map.take(params, fields)

    with {:ok, site} <- Rice.Settings.update_site(attrs) do
      render(conn, :show, site: site)
    end
  end
end

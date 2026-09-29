defmodule RiceWeb.Router do
  use RiceWeb, :router

  import RiceWeb.Api.Auth
  import RiceWeb.Api.Admin.Auth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {RiceWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    plug :fetch_current_user
  end

  pipeline :api_authenticated do
    plug :require_authenticated_user
  end

  # 管理端。令牌和 C 端完全分开 —— 两套 token 互相换不过去。
  pipeline :admin_api do
    plug :accepts, ["json"]
    plug :fetch_current_admin
  end

  pipeline :admin_authenticated do
    plug :require_admin
  end

  # role=admin 才能进。core 只在前端隐藏菜单,接口本身不查。
  pipeline :admin_only do
    plug :require_admin_role
  end

  scope "/", RiceWeb do
    pipe_through :browser

    get "/", PageController, :home

    # "Login with Semi" (OAuth 2.0 Authorization Code + PKCE).
    # /callback is the redirect_uri registered with the Semi OAuth app.
    get "/login", SemiAuthController, :login
    get "/callback", SemiAuthController, :callback
    get "/logout", SemiAuthController, :logout
    get "/auth/semi/login", SemiAuthController, :login
    get "/auth/semi/callback", SemiAuthController, :callback
  end

  # One-time session-handoff redemption for the front-end (cross-origin JSON,
  # CORS handled in the action). No session/CSRF pipeline needed.
  scope "/", RiceWeb do
    pipe_through :api

    get "/session/:ticket", SemiAuthController, :session
    get "/auth/semi/session/:ticket", SemiAuthController, :session
    get "/auth/semi/options", SemiAuthController, :options
  end

  # 从 xiangjiandao-core 迁过来的业务接口。REST + HTTP 状态码,不套
  # core 那层 {code, message, data} 信封。见 docs/backend-migration-plan.md §4。
  scope "/api", RiceWeb.Api do
    pipe_through :api

    # 期 1:后台维护、C 端只读的内容位。无认证。
    get "/apps", AppController, :index
    get "/banners", BannerController, :index
    get "/announcements", AnnouncementController, :index
    get "/announcements/:id", AnnouncementController, :show
    get "/settings/foundation", SettingsController, :foundation

    # 期 2:附件读取(公开)。上传在下面的认证段里。
    get "/attachments/:id", AttachmentController, :show
    get "/v1/file/download", LegacyAttachmentController, :show

    # 期 3:注册 / 登录。这几个必须匿名可用。
    post "/verification_codes", VerificationCodeController, :create
    post "/registrations/verification", RegistrationController, :verify
    post "/registrations", RegistrationController, :create
    post "/session", SessionController, :create
    post "/passwords/reset", PasswordController, :create

    # 期 4:节点、勋章与发放记录(公开可读)
    get "/nodes", NodeController, :index

    # 某人的勋章墙。:user_id 认 "me" / rice id / DID / handle。
    get "/users/:user_id/badges", BadgeController, :index
    get "/nodes/members", NodeController, :members
    get "/nodes/:node_id/members", NodeController, :members
    get "/nodes/:id", NodeController, :show
    get "/users/search", UserController, :search
    get "/users/:identifier/profile", UserController, :profile
    get "/events", EventController, :index
    get "/events/:id", EventController, :show
    get "/grain_grants", GrainGrantController, :index

    # 期 5:提案。列表和详情公开可读,写操作在下面的认证段。
    get "/proposals", ProposalController, :index
    get "/proposals/:id", ProposalController, :show
    get "/proposals/:proposal_id/comments", ProposalCommentController, :index

    # Task V1。列表与详情公开可读，状态动作必须登录。
    get "/tasks", TaskController, :index
    get "/tasks/:id", TaskController, :show
  end

  # ── 管理端 ────────────────────────────────────────────────────────────
  # core 的 /api/v1/admin/* 是 56 个动词式 POST;这里换成 REST。
  # 映射表见 docs/backend-migration-plan.md §5.2。

  # 匿名可达的只有登录和找回密码
  scope "/api/admin", RiceWeb.Api.Admin do
    pipe_through :admin_api

    post "/session/challenge", SessionController, :challenge
    post "/session", SessionController, :create
    post "/passwords/challenge", PasswordController, :challenge
    post "/passwords", PasswordController, :create
  end

  # 登录即可(管理员和运营都能用)
  scope "/api/admin", RiceWeb.Api.Admin do
    pipe_through [:admin_api, :admin_authenticated]

    delete "/session", SessionController, :delete
    get "/me", AdminUserController, :me
    patch "/me", AdminUserController, :update_me
  end

  # 仅 role=admin
  scope "/api/admin", RiceWeb.Api.Admin do
    pipe_through [:admin_api, :admin_authenticated, :admin_only]

    get "/admin_users", AdminUserController, :index
    post "/admin_users", AdminUserController, :create
    delete "/admin_users/:id", AdminUserController, :delete
  end

  # 运营内容:四种资源同构,共用 CatalogController,资源类型走 assigns 传 ——
  # 不从 URL 参数推,免得把用户输入喂给 String.to_existing_atom/1。
  scope "/api/admin", RiceWeb.Api.Admin do
    pipe_through [:admin_api, :admin_authenticated]

    for {path, kind, view} <- [
          {"apps", :apps, RiceWeb.Api.Admin.AppJSON},
          {"banners", :banners, RiceWeb.Api.Admin.BannerJSON},
          {"announcements", :announcements, RiceWeb.Api.Admin.AnnouncementJSON},
          {"nodes", :nodes, RiceWeb.Api.Admin.NodeJSON}
        ] do
      assigns = %{kind: kind, json_view: view}

      get "/#{path}", CatalogController, :index, assigns: assigns
      post "/#{path}", CatalogController, :create, assigns: assigns
      # 排序要排在 /:id 前面,否则 "positions" 会被当成一个 id
      put "/#{path}/positions", CatalogController, :reorder, assigns: assigns
      get "/#{path}/:id", CatalogController, :show, assigns: assigns
      patch "/#{path}/:id", CatalogController, :update, assigns: assigns
      delete "/#{path}/:id", CatalogController, :delete, assigns: assigns
    end
  end

  # 用户、稻米、提案、勋章、全站配置
  scope "/api/admin", RiceWeb.Api.Admin do
    pipe_through [:admin_api, :admin_authenticated]

    # core 的 9 个用户接口在这里是 3 个:一个带过滤的列表、一个详情、
    # 一个改管理位的 PATCH(disabled / node_member)
    get "/users", UserController, :index
    get "/users/:id", UserController, :show
    patch "/users/:id", UserController, :update
    get "/users/:user_id/grain_transfers", GrainController, :transfers

    # single / batch 合成一个 —— 收款人永远是数组。
    # 发放动的是钱,要管理员自己手机上的验证码 —— core 也是这个要求。
    get "/grain_grants", GrainController, :index
    post "/grain_grants/challenge", GrainController, :challenge
    post "/grain_grants", GrainController, :create

    get "/proposals", ProposalController, :index
    get "/proposals/:id", ProposalController, :show
    patch "/proposals/:id", ProposalController, :update
    delete "/proposals/:proposal_id/comments/:id", ProposalController, :delete_comment

    get "/badges", BadgeController, :index
    post "/badges", BadgeController, :create
    get "/badges/:badge_id/holders", BadgeController, :holders
    # 给已有勋章补发持有人。core 没有这个入口 —— 建完就加不了人
    post "/badges/:badge_id/holders", BadgeController, :award

    # core 的 detail + modify-foundation-info + modify-proposal-config
    get "/settings", SettingsController, :show
    patch "/settings", SettingsController, :update

    # 批量操作的 Excel 模板
    get "/templates", TemplateController, :index

    # 贴文不在 rice 库里,这里只是把下架请求转给 post 服务 ——
    # uri 放 body 不放路径:AT URI 里有斜杠。
    post "/post_takedowns", PostController, :create
    delete "/post_takedowns", PostController, :delete
  end

  # 管理端也要能传附件(应用图标、轮播图、勋章图、公告正文)。
  #
  # 不能让管理端令牌去调 C 端那个 `/api/attachments` —— 两套令牌互不通用是
  # 有意的,为此专门写了测试。所以这里是同一个控制器挂在管理端管线上:
  # 认证方式不同,校验和落盘逻辑完全共用。
  #
  # 读不用管:附件本来就是公开的。
  scope "/api/admin", RiceWeb.Api do
    pipe_through [:admin_api, :admin_authenticated]

    post "/attachments", AttachmentController, :create
  end

  # 需要登录的接口
  scope "/api", RiceWeb.Api do
    pipe_through [:api, :api_authenticated]

    delete "/session", SessionController, :delete

    get "/users/me", UserController, :me
    patch "/users/me", UserController, :update
    delete "/users/me", UserController, :delete
    put "/users/me/phone", UserController, :update_phone
    put "/users/me/email", UserController, :update_email

    # 期 4:稻米。明细只能看自己的,转账当然要登录。
    get "/grain_transfers", GrainTransferController, :index
    post "/grain_transfers/recipient", GrainTransferController, :recipient
    post "/grain_transfers", GrainTransferController, :create

    # 期 5:提案的写操作
    post "/proposals", ProposalController, :create
    delete "/proposals/:id", ProposalController, :delete
    get "/proposals/:proposal_id/vote", ProposalVoteController, :show
    post "/proposals/:proposal_id/vote", ProposalVoteController, :create
    post "/proposals/:proposal_id/comments", ProposalCommentController, :create
    delete "/proposals/:proposal_id/comments/:id", ProposalCommentController, :delete

    get "/wallet", WalletController, :show
    get "/notifications", InboxController, :index
    post "/notifications/read", InboxController, :read
    post "/nodes/:node_id/applications", NodeController, :apply
    patch "/nodes/:node_id/members/:user_id", NodeController, :update_member
    get "/nodes/:node_id/wallet", NodeWalletController, :show
    post "/nodes/:node_id/fund", NodeWalletController, :fund
    post "/nodes/:node_id/applications/:application_id/approve", NodeController, :approve
    post "/nodes/:node_id/applications/:application_id/reject", NodeController, :reject
    post "/events", EventController, :create
    patch "/events/:event_id", EventController, :update
    post "/events/:event_id/publish", EventController, :publish
    post "/events/:event_id/cancel", EventController, :cancel
    post "/events/:event_id/finish", EventController, :finish
    post "/events/:event_id/applications", EventController, :apply
    post "/events/:event_id/applications/:application_id/approve", EventController, :approve
    post "/events/:event_id/applications/:application_id/reject", EventController, :reject
    post "/events/:event_id/applications/:application_id/remove", EventController, :remove
    post "/events/:event_id/applications/:application_id/withdraw", EventController, :withdraw
    post "/tasks", TaskController, :create
    patch "/tasks/:task_id", TaskController, :update
    post "/tasks/:task_id/publish", TaskController, :publish
    post "/tasks/:task_id/cancel", TaskController, :cancel
    post "/tasks/:task_id/applications", TaskController, :apply
    post "/tasks/:task_id/applications/:application_id/appoint", TaskController, :appoint

    post "/tasks/:task_id/applications/:application_id/reject",
         TaskController,
         :reject_application

    post "/tasks/:task_id/submissions", TaskController, :submit
    post "/tasks/:task_id/submissions/:submission_id/approve", TaskController, :approve

    post "/tasks/:task_id/submissions/:submission_id/request_changes",
         TaskController,
         :request_changes

    get "/task_notifications", TaskController, :notifications
    post "/task_notifications/read", TaskController, :read_notifications

    # core 的 /file/upload 是匿名的;这里必须登录
    post "/attachments", AttachmentController, :create
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:rice, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: RiceWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end

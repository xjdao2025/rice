defmodule RiceWeb.SemiAuthControllerTest do
  use RiceWeb.ConnCase, async: false
  import Mox
  setup :verify_on_exit!

  setup do
    for key <- [:semi, :handoff, :notifications] do
      previous = Application.get_env(:rice, key)
      on_exit(fn -> Application.put_env(:rice, key, previous) end)
    end

    Application.put_env(:rice, :semi,
      client_id: "mock-client",
      client_secret: "mock-secret",
      redirect_uri: "https://app.example/auth/semi/callback",
      authorize_base: "https://semi.example",
      issuer: "https://semi-api.example",
      plug: {Req.Test, __MODULE__}
    )

    Application.put_env(:rice, :handoff,
      target_url: "https://app.example/semi-callback",
      allowed_origin: "https://app.example"
    )

    :ok
  end

  test "OAuth uses PKCE, redeems one ticket, and keeps Rice and PDS identities together", %{
    conn: conn
  } do
    login = get(conn, "/auth/semi/login", %{returnTo: "/events/example"})

    authorization =
      login |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()

    assert authorization["code_challenge_method"] == "S256"
    assert authorization["redirect_uri"] == "https://app.example/auth/semi/callback"
    refute Map.has_key?(authorization, "client_secret")

    Req.Test.stub(__MODULE__, fn request ->
      case request.request_path do
        "/oauth/token" ->
          {:ok, body, request} = Plug.Conn.read_body(request)
          body = Jason.decode!(body)
          assert body["code"] == "provider-code"
          assert body["client_secret"] == "mock-secret"

          assert Rice.SemiOAuth.code_challenge(body["code_verifier"]) ==
                   authorization["code_challenge"]

          Req.Test.json(request, %{access_token: "provider-token"})

        "/oauth/userinfo" ->
          assert Plug.Conn.get_req_header(request, "authorization") == ["Bearer provider-token"]
          Req.Test.json(request, %{sub: "mock-sub", handle: "semi-user"})
      end
    end)

    expect(Rice.PDSMock, :handle_domain, fn -> "pds.test" end)
    expect(Rice.PDSMock, :email_domain, fn -> "pds.test" end)

    expect(Rice.PDSMock, :create_account, fn _ ->
      {:ok,
       %{
         "did" => "did:plc:semimock",
         "handle" => "semi-user.pds.test",
         "accessJwt" => "pds-access",
         "refreshJwt" => "pds-refresh"
       }}
    end)

    expect(Rice.PDSMock, :get_profile, fn _, _ -> {:ok, %{}} end)

    callback =
      login
      |> recycle()
      |> get("/auth/semi/callback", %{code: "provider-code", state: authorization["state"]})

    destination = callback |> redirected_to() |> URI.parse()
    query = URI.decode_query(destination.query)
    assert destination.path == "/semi-callback"
    assert query["returnTo"] == "/events/example"
    refute Map.has_key?(query, "accessJwt")
    ticket = query["ticket"]
    payload = build_conn() |> get("/auth/semi/session/#{ticket}") |> json_response(200)
    assert payload["accessJwt"] == "pds-access"
    assert %{did: "did:plc:semimock"} = Rice.Accounts.user_by_token(payload["riceToken"])
    assert build_conn() |> get("/auth/semi/session/#{ticket}") |> json_response(404)
  end

  test "mismatched state never calls provider and rejects external return targets", %{conn: conn} do
    login = get(conn, "/auth/semi/login", %{returnTo: "//outside.example"})
    callback = login |> recycle() |> get("/auth/semi/callback", %{code: "unused", state: "wrong"})
    query = callback |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert query["returnTo"] == "/"
    assert query["error"] == "登录校验失败，请重新发起登录。"
    refute Map.has_key?(query, "ticket")
  end

  test "public options only expose availability; log mode is explicit", %{conn: conn} do
    Application.put_env(:rice, :notifications, Rice.Notifications.Log)
    options = conn |> get("/auth/semi/options") |> json_response(200)
    assert options["verification_mode"] == "log"
    assert options["registration_channels"] == ["sms", "email"]
    assert options["semi_enabled"]
    refute inspect(options) =~ "mock-secret"
    Application.put_env(:rice, :semi, [])

    refute build_conn()
           |> get("/auth/semi/options")
           |> json_response(200)
           |> Map.fetch!("semi_enabled")
  end
end

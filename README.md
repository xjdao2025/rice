# Rice

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Registration and Semi login

The existing registration flow verifies SMS/email, creates a PDS account, and returns
both Rice and PDS sessions.
Registration accepts a `username` prefix (3–18 letters, digits or hyphens, beginning
and ending with a letter or digit); the server appends `PDS_HANDLE_DOMAIN` and
initializes the nickname from that prefix. The routes and request handling are in
[`router.ex`](lib/rice_web/router.ex) and
[`registration_controller.ex`](lib/rice_web/api/registration_controller.ex).

Production defaults to `RICE_VERIFICATION_MODE=live`:
unconfigured delivery channels fail explicitly. `log` is an opt-in isolated-test mode;
it does not send real messages. SMS uses `ALIYUN_SMS_ACCESS_KEY_ID`,
`ALIYUN_SMS_ACCESS_KEY_SECRET`, `ALIYUN_SMS_SIGN_NAME`, `ALIYUN_SMS_TEMPLATE_CODE`.
Email uses `SMTP_RELAY`, `SMTP_PORT` (STARTTLS, default 587), `SMTP_USERNAME`,
`SMTP_PASSWORD`, and `SMTP_SENDER_ADDRESS`.

Semi reuses Authorization Code + PKCE, the existing PDS bridge, and one-time handoff
tickets. No new login framework or runtime fake-success fallback is introduced.

| Variable | Meaning |
| --- | --- |
| `SEMI_CLIENT_ID`, `SEMI_CLIENT_SECRET` | Semi OAuth app credentials; server only |
| `SEMI_REDIRECT_URI` | Registered callback, e.g. `https://<host>/auth/semi/callback` |
| `SEMI_FRONTEND_URL` | Consent page origin, default `https://www.semi.im` |
| `SEMI_ISSUER` | Token/userinfo origin, default `https://api.semi.im` |
| `HANDOFF_URL` | Frontend `https://<host>/semi-callback` |
| `HANDOFF_ALLOWED_ORIGIN` | Frontend origin |
| `RICE_LINK_ENC_KEY` | Base64-encoded 32-byte encryption key; keep the original key with existing `semi_links` |
| `PDS_BASE_URL`, `PDS_PUBLIC_URL`, `PDS_HANDLE_DOMAIN`, `PDS_EMAIL_DOMAIN` | Internal PDS endpoint, public endpoint, handle and provisioning email domains |

`GET /auth/semi/options` exposes availability flags and handle domain, never secrets.
The app uses `/auth/semi/login`, `/auth/semi/callback`, `/auth/semi/session/:ticket`;
the legacy `/login`, `/callback`, `/session/:ticket` routes remain available.
`returnTo` is restricted to an in-app path and survives authorization. Failed callbacks
return to the frontend with an error; no half-complete session is installed.

Run the focused protocol tests with `mix test test/rice_web/semi_auth_controller_test.exs
test/rice_web/api/registration_controller_test.exs test/rice/notifications_test.exs
test/rice/bridge_test.exs`. Req.Test replaces Semi HTTP and Mox replaces external PDS
and message delivery only inside tests. Real-provider validation follows deployment
configuration; test success is not proof that a real SMS/email was delivered.

## API source

[`router.ex`](lib/rice_web/router.ex) lists the HTTP endpoints. Controllers in
[`lib/rice_web/api`](lib/rice_web/api), their JSON modules, and matching
[`test/rice_web`](test/rice_web) files define request, response, and permission
behavior. Shared authentication is in [`auth.ex`](lib/rice_web/api/auth.ex);
error responses are in [`fallback_controller.ex`](lib/rice_web/api/fallback_controller.ex).

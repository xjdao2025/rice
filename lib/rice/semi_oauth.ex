defmodule Rice.SemiOAuth do
  @moduledoc """
  Client for Semi's OAuth 2.0 / OpenID Connect provider
  (Authorization Code flow + PKCE, S256).

  `rice` acts as a *confidential* client: it holds the `client_secret` and
  performs the code→token exchange and the userinfo lookup server-side, so the
  browser never sees either. This module is transport-only — it builds the
  authorize URL, swaps a code for tokens, and reads userinfo. PKCE `state` /
  `code_verifier` persistence is the caller's job (we keep them in the signed
  Phoenix session).

  Endpoints and scopes follow the Semi integration guide and the `hola`
  reference client. The token endpoint is sent as JSON to match `hola` (the
  working reference); the guide also documents `x-www-form-urlencoded`, which
  is a one-line change here if ever needed.
  """

  @scopes "openid profile wallet"

  @doc "Space-delimited scope string requested from Semi."
  def scopes, do: @scopes

  defp config, do: Application.fetch_env!(:rice, :semi)

  @doc "True once the OAuth app credentials are configured."
  def configured? do
    cfg = config()

    is_binary(cfg[:client_id]) and cfg[:client_id] != "" and
      is_binary(cfg[:client_secret]) and cfg[:client_secret] != "" and
      byte_size(Application.get_env(:rice, Rice.Vault, [])[:key] || "") == 32
  end

  # ── PKCE ────────────────────────────────────────────────────────────────

  @doc "Random 32-byte base64url code_verifier (kept by the caller, secret)."
  def gen_code_verifier, do: random_b64(32)

  @doc "S256 challenge = base64url(sha256(verifier))."
  def code_challenge(verifier) do
    :crypto.hash(:sha256, verifier) |> Base.url_encode64(padding: false)
  end

  @doc "Random anti-CSRF state value."
  def gen_state, do: random_b64(16)

  defp random_b64(n), do: :crypto.strong_rand_bytes(n) |> Base.url_encode64(padding: false)

  # ── Authorize URL ───────────────────────────────────────────────────────

  @doc "Build the Semi authorize URL to redirect the browser to."
  def authorize_url(state, code_challenge) do
    cfg = config()

    query =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => cfg[:client_id],
        "redirect_uri" => cfg[:redirect_uri],
        "scope" => @scopes,
        "state" => state,
        "code_challenge" => code_challenge,
        "code_challenge_method" => "S256"
      })

    # Browser must hit the frontend consent page, NOT the API (which returns
    # JSON metadata instead of rendering the consent UI).
    trim(cfg[:authorize_base]) <> "/oauth/authorize?" <> query
  end

  # ── Token exchange ──────────────────────────────────────────────────────

  @doc """
  Exchange an authorization `code` (+ the original `code_verifier`) for tokens.
  Returns `{:ok, %{"access_token" => _, "refresh_token" => _, ...}}` or
  `{:error, reason}`.
  """
  def exchange_code(code, code_verifier) do
    cfg = config()

    post_token(cfg, %{
      "grant_type" => "authorization_code",
      "code" => code,
      "redirect_uri" => cfg[:redirect_uri],
      "client_id" => cfg[:client_id],
      "client_secret" => cfg[:client_secret],
      "code_verifier" => code_verifier
    })
  end

  @doc "Exchange a refresh token for a fresh token pair (rotation)."
  def refresh(refresh_token) do
    cfg = config()

    post_token(cfg, %{
      "grant_type" => "refresh_token",
      "refresh_token" => refresh_token,
      "client_id" => cfg[:client_id],
      "client_secret" => cfg[:client_secret]
    })
  end

  defp post_token(cfg, body) do
    case Req.post(
           trim(cfg[:issuer]) <> "/oauth/token",
           [json: body, receive_timeout: 15_000] ++ Keyword.take(cfg, [:plug])
         ) do
      {:ok, %{status: 200, body: %{"access_token" => _} = tokens}} ->
        {:ok, tokens}

      {:ok, %{status: status, body: body}} ->
        {:error, {:token_endpoint, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  # ── UserInfo ────────────────────────────────────────────────────────────

  @doc """
  Fetch the OIDC userinfo for an access token. Returns the claims map
  (`sub`, `handle`, `wallet_address`, verified flags, `scopes_granted`, ...)
  or `{:error, reason}`.
  """
  def fetch_userinfo(access_token) do
    cfg = config()

    case Req.get(
           trim(cfg[:issuer]) <> "/oauth/userinfo",
           [auth: {:bearer, access_token}, receive_timeout: 15_000] ++ Keyword.take(cfg, [:plug])
         ) do
      {:ok, %{status: 200, body: %{"sub" => _} = user}} ->
        {:ok, user}

      {:ok, %{status: status, body: body}} ->
        {:error, {:userinfo, status, body}}

      {:error, reason} ->
        {:error, {:transport, reason}}
    end
  end

  defp trim(url), do: String.trim_trailing(url, "/")
end

defmodule Rice.Handoff do
  @moduledoc """
  One-time, short-lived tickets for handing a freshly minted PDS session to the
  front-end (social-app at together.li). rice redirects the browser to
  `…/semi-callback?ticket=<t>`; the app redeems `<t>` exactly once via
  `GET /session/:ticket` and installs the session.

  In-memory (single node); tickets are ephemeral (default 120s TTL) so losing
  them on restart just means re-logging in.
  """
  use GenServer

  @ttl_ms 120_000
  @sweep_ms 30_000

  # ── API ─────────────────────────────────────────────────────────────────

  @spec start_link(term()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Store a session payload, return an opaque single-use ticket."
  @spec put(map()) :: String.t()
  def put(payload) when is_map(payload) do
    ticket = :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
    GenServer.call(__MODULE__, {:put, ticket, payload})
    ticket
  end

  @doc "Redeem a ticket exactly once. `{:ok, payload}` or `:error`."
  @spec take(term()) :: {:ok, map()} | :error
  def take(ticket) when is_binary(ticket), do: GenServer.call(__MODULE__, {:take, ticket})
  def take(_), do: :error

  # ── Server ──────────────────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_call({:put, ticket, payload}, _from, state) do
    {:reply, :ok, Map.put(state, ticket, {payload, now() + @ttl_ms})}
  end

  def handle_call({:take, ticket}, _from, state) do
    case Map.pop(state, ticket) do
      {{payload, expires_at}, rest} ->
        if now() <= expires_at, do: {:reply, {:ok, payload}, rest}, else: {:reply, :error, rest}

      {nil, _} ->
        {:reply, :error, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    now = now()
    schedule_sweep()
    {:noreply, Map.reject(state, fn {_k, {_payload, exp}} -> now > exp end)}
  end

  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_ms)
  defp now, do: System.monotonic_time(:millisecond)
end

defmodule DpExchange.Coinbase.Socket do
  @moduledoc """
  This venue's WebSocket connection — internal. A consumer never sees this module, never
  holds this pid, and cannot tell from the facade that it exists.

  ## The venue dials its own socket

  This used to be injected: shared code opened the connection and handed the adapter an
  `open`/`subscribe` pair, because the connection machinery lived in a boundary the
  adapters could not reference. That constraint was an artefact of one application's
  module layout, and it cost more than it saved — shared code was making transport
  decisions with information only the venue has.

  The venue keeps the **policy** either way: how many connections, which channels, how
  many pairs each carries, in what order and at what pace. What changed is that it now
  also owns the mechanism, so there is no seam for the two to disagree across.

  ## Public channels take no JWT, and attaching one is actively harmful

  Coinbase answers a bogus token with `{"type":"error","message":"authentication
  failure"}` — measured 2026-08-07. An earlier version attached a token to every channel
  on the theory that it could not hurt. It could: the token was a stub returning the raw
  API key, so `level2` produced nothing while `ticker`, which is public, worked fine.
  A venue half-delivering looks like a quiet market rather than a broken credential.

  Authenticated channels get a real JWT from `DpExchange.Coinbase.Auth`, built fresh per
  subscribe rather than cached — its window is two minutes, and a token that outlives it
  fails the same silent way.

  ## Every frame goes through `FrameSender`

  Never `WebSockex.send_frame/2` directly. See that module for why; the short version is
  that it exits rather than returning, and the exit kills this connection.
  """

  use WebSockex

  alias DpExchange.Coinbase.{Auth, FrameSender, SymbolFormat}
  alias DpExchange.Core.{Notice, Types}

  require Logger

  @endpoint "wss://advanced-trade-ws.coinbase.com"

  # `ticker` is public. `level2` and `user` require a token; nothing else does, and
  # attaching one where it is not required is the incident above.
  @authenticated_channels ~w(level2 user)

  @doc """
  Starts a connection.

  ## Options

    * `:subscriber` — the process events are delivered to. Required.
    * `:credentials` — only needed for authenticated channels.
    * `:url` — override the endpoint, for tests that stand up a local socket.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    state = %{
      subscriber: Keyword.fetch!(opts, :subscriber),
      credentials: Keyword.get(opts, :credentials),
      # Observed delivery, not intended: a symbol enters this set when a payload for it
      # arrives, never when it is subscribed.
      delivering: MapSet.new()
    }

    WebSockex.start_link(Keyword.get(opts, :url, @endpoint), __MODULE__, state, opts)
  end

  @doc """
  Subscribes `symbols` on `channel`.

  Returns `{:error, :send_timeout}` rather than dying when the socket is too busy to
  accept the frame — see `DpExchange.Coinbase.FrameSender`.
  """
  @spec subscribe(pid(), String.t(), [String.t()], map() | nil) :: :ok | {:error, term()}
  def subscribe(socket, channel, symbols, credentials \\ nil) do
    products = Enum.map(symbols, &SymbolFormat.to_exchange_symbol/1)

    with {:ok, message} <- subscription_message(channel, products, credentials) do
      FrameSender.send(socket, {:text, Jason.encode!(message)}, "coinbase subscribe #{channel}")
    end
  end

  @doc "Unsubscribes `symbols` from `channel`."
  @spec unsubscribe(pid(), String.t(), [String.t()]) :: :ok | {:error, term()}
  def unsubscribe(socket, channel, symbols) do
    message = %{
      type: "unsubscribe",
      product_ids: Enum.map(symbols, &SymbolFormat.to_exchange_symbol/1),
      channel: channel
    }

    FrameSender.send(socket, {:text, Jason.encode!(message)}, "coinbase unsubscribe #{channel}")
  end

  # --- WebSockex callbacks -----------------------------------------------

  @impl true
  def handle_connect(_conn, state) do
    notify(state, Notice.new(:link_up, :coinbase))
    {:ok, state}
  end

  @impl true
  def handle_disconnect(%{reason: reason}, state) do
    notify(state, Notice.new(:link_down, :coinbase, details: %{reason: inspect(reason)}))
    {:reconnect, state}
  end

  @impl true
  def handle_frame({:text, payload}, state) do
    case Jason.decode(payload) do
      {:ok, decoded} -> {:ok, dispatch(decoded, state)}
      # A payload that did not parse is reported, not swallowed and not fatal.
      {:error, _reason} -> {:ok, report_quality(state, payload)}
    end
  end

  def handle_frame(_frame, state), do: {:ok, state}

  # --- internal ----------------------------------------------------------

  defp subscription_message(channel, products, credentials) do
    base = %{type: "subscribe", product_ids: products, channel: channel}

    cond do
      channel not in @authenticated_channels ->
        {:ok, base}

      is_nil(credentials) ->
        {:error, {:credentials_required, channel}}

      true ->
        with {:ok, token} <- Auth.jwt(credentials) do
          {:ok, Map.put(base, :jwt, token)}
        end
    end
  end

  defp dispatch(%{"channel" => "ticker", "events" => events}, state) do
    Enum.reduce(events, state, fn event, acc ->
      Enum.reduce(Map.get(event, "tickers", []), acc, &deliver_ticker/2)
    end)
  end

  defp dispatch(%{"type" => "error", "message" => message}, state) do
    # Coinbase reports an auth failure this way, and it is the shape the stub-token
    # incident produced. Surfaced as a condition rather than counted as a metric.
    notify(state, Notice.new(:credentials_rejected, :coinbase, message: message))
    state
  end

  defp dispatch(_other, state), do: state

  defp deliver_ticker(%{"product_id" => product} = ticker, state) do
    symbol = SymbolFormat.to_canonical_symbol(product)

    case build_quote(ticker, symbol) do
      {:ok, quote_struct} ->
        send(state.subscriber, {:dp_exchange, :coinbase, quote_struct})
        %{state | delivering: MapSet.put(state.delivering, symbol)}

      {:error, _reason} ->
        report_quality(state, product)
    end
  end

  defp deliver_ticker(_ticker, state), do: state

  # FAILS CLOSED on the timestamp, exactly as the REST path does. A tick whose freshness
  # we cannot state is a tick we must not deliver, and substituting `now` would make a
  # stale one indistinguishable from a live one.
  defp build_quote(%{"price" => price} = ticker, symbol) do
    with {:ok, at} <- parse_time(ticker["time"]) do
      {:ok,
       %Types.Quote{
         symbol: symbol,
         price: Decimal.new(price),
         volume: decimal(ticker["volume_24_h"]),
         timestamp: at,
         provider: :coinbase
       }}
    end
  end

  defp build_quote(_ticker, _symbol), do: {:error, :unexpected_payload}

  defp parse_time(nil), do: {:error, :missing_venue_timestamp}

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, {:unparseable_venue_timestamp, reason}}
    end
  end

  defp parse_time(other), do: {:error, {:unparseable_venue_timestamp, other}}

  defp decimal(nil), do: nil
  defp decimal(value) when is_binary(value), do: Decimal.new(value)

  defp report_quality(state, detail) do
    notify(
      state,
      Notice.new(:data_quality, :coinbase,
        details: %{payload: String.slice(to_string(detail), 0, 120)}
      )
    )

    state
  end

  # Lossy by contract: a notice that cannot be delivered is dropped rather than retried.
  # Reporting on the work must never become the reason the work does not happen.
  defp notify(%{subscriber: subscriber}, notice) when is_pid(subscriber) do
    send(subscriber, {:dp_exchange, :coinbase, notice})
    :ok
  end

  defp notify(_state, _notice), do: :ok
end

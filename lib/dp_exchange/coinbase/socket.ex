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

  ## `level2` is a maintained book, not a series of standalone facts

  Unlike `ticker`, one `l2_data` frame does not carry enough to answer "what does the
  book look like right now" — a `snapshot` event seeds it and `update` events carry only
  the price levels that changed, with `new_quantity: "0"` meaning the level is gone.
  **This socket holds that state**, one map of price → quantity per side per symbol, and
  every `Core.Types.OrderBook` delivered is built from the maintained state, never from a
  single frame's rows alone — a caller reading one delta as the whole book would see a
  handful of prices and nothing else, which is a book with everything but two levels
  simply missing rather than a partial update.

  A **reconnect loses this state**, because the venue's own session is gone with it —
  `handle_disconnect/2` clears every symbol's book, and the next `snapshot` this socket
  receives after resubscribing rebuilds it from what the venue sends fresh. There is no
  way to reconcile a stale local book against a venue that has moved on.
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
      delivering: MapSet.new(),
      # symbol => %{bids: %{price => quantity}, asks: %{price => quantity}}. Maintained
      # across `update` frames; wiped on every reconnect, because the venue's session —
      # and the guarantee that our deltas are contiguous with its book — is gone with it.
      books: %{}
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
    # The venue's session is gone, and every maintained book with it — see the moduledoc.
    # `delivering` is left alone: a symbol that was streaming is reasonably still "was
    # covered a moment ago" until the coordinator's resubscribe timer either revives it
    # or its own staleness ages it out of whatever freshness a caller applies downstream.
    {:reconnect, %{state | books: %{}}}
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

  # v3 nests the rows under a per-channel key, and the key differs per channel. Only the
  # channels this package actually delivers are expanded; anything else yields nothing
  # rather than a half-populated message, because a message with nil fields is exactly
  # what made an outage invisible in the adapter this was ported from.
  #
  # Note `l2_data`: v3 names the level2 channel that way on the RESPONSE side while the
  # subscribe still says `level2`. A parser keyed on the subscribe name silently drops
  # every book update — and a venue delivering nothing on one channel while another works
  # reads as a quiet market.
  #
  # **The timestamp lives on the envelope, not the row.** Every v3 channel message
  # carries its own top-level `timestamp` (server time the message was sent); neither a
  # `tickers` row nor a `level2` `updates` row repeats it. An earlier version of this
  # module read a `ticker["time"]` field that does not exist in the venue's own
  # documented schema — every single `ticker` decode failed against the real venue as a
  # result, silently, because the fake and hand-written tests both encoded the same wrong
  # assumption and agreed with each other. Confirmed against Coinbase's own CDP API
  # reference for both channels before fixing, not assumed a second time.
  defp dispatch(%{"channel" => "ticker", "events" => events} = payload, state)
       when is_list(events) do
    timestamp = Map.get(payload, "timestamp")

    Enum.reduce(events, state, fn event, acc ->
      Enum.reduce(Map.get(event, "tickers", []), acc, &deliver_ticker(&1, &2, timestamp))
    end)
  end

  defp dispatch(%{"channel" => "l2_data", "events" => events} = payload, state)
       when is_list(events) do
    timestamp = Map.get(payload, "timestamp")
    Enum.reduce(events, state, &apply_book_event(&1, &2, timestamp))
  end

  defp dispatch(%{"channel" => "subscriptions"}, state) do
    # The venue acknowledging a subscribe. Not data, and deliberately NOT recorded as
    # coverage: a confirmation is intent, and coverage reports what arrived.
    state
  end

  defp dispatch(%{"channel" => "heartbeats"}, state), do: state

  defp dispatch(%{"channel" => channel, "events" => _events}, state)
       when channel in ["market_trades", "candles", "user"] do
    # Recognised, and not delivered. This package declares `streamable: [:quotes,
    # :order_book]`, so these channels are never subscribed — arriving means the venue
    # sent something this package did not ask for, which is worth noticing rather than
    # silently dropping.
    notify(
      state,
      Notice.new(:data_quality, :coinbase,
        message: "received an unsubscribed channel",
        details: %{channel: channel}
      )
    )

    state
  end

  defp dispatch(%{"type" => "error", "message" => message}, state) do
    notify(state, Notice.new(error_kind(message), :coinbase, message: message))
    state
  end

  defp dispatch(_other, state), do: state

  # Coinbase reports both an auth failure and a capacity refusal through the identical
  # `{"type":"error","message":...}` shape, and they mean nothing alike: one says a
  # credential is wrong, the other says this package opened more `level2` sessions than
  # the venue allows under it. Collapsing both into `:credentials_rejected` (the auth
  # failure's own shape, from the stub-token incident this clause was originally written
  # for) reported a capacity condition as a credential problem — DpCryptoManagement's
  # issue #22, where "too many L2 streams requested in a single session" surfaced only
  # once the consumer wired `subscribe_notices/1` and still read as an auth error until
  # traced. `:rate_limited` is Core's own kind for exactly this: pressure, not identity.
  defp error_kind(message) do
    if String.contains?(String.downcase(message), "too many"),
      do: :rate_limited,
      else: :credentials_rejected
  end

  defp deliver_ticker(%{"product_id" => product} = ticker, state, timestamp) do
    symbol = SymbolFormat.to_canonical_symbol(product)

    case build_quote(ticker, symbol, timestamp) do
      {:ok, quote_struct} ->
        send(state.subscriber, {:dp_exchange, :coinbase, quote_struct})
        %{state | delivering: MapSet.put(state.delivering, symbol)}

      {:error, _reason} ->
        report_quality(state, product)
    end
  end

  defp deliver_ticker(_ticker, state, _timestamp), do: state

  # FAILS CLOSED on the timestamp, exactly as the REST path does. A tick whose freshness
  # we cannot state is a tick we must not deliver, and substituting `now` would make a
  # stale one indistinguishable from a live one. The price fails closed the same way:
  # `Decimal.new/1` used to raise directly here, and a `Quote` with a nil price would be
  # the same substitution wearing a quieter shape — refused instead, through the same
  # {:error, _} path deliver_ticker/3 already reports as a data-quality notice.
  defp build_quote(%{"price" => price} = ticker, symbol, timestamp) do
    with {:ok, at} <- parse_time(timestamp),
         {:ok, parsed_price} <- required_decimal(price, :price) do
      {:ok,
       %Types.Quote{
         symbol: symbol,
         price: parsed_price,
         volume: decimal(ticker["volume_24_h"]),
         timestamp: at,
         provider: :coinbase
       }}
    end
  end

  defp build_quote(_ticker, _symbol, _timestamp), do: {:error, :unexpected_payload}

  # --- level2 / order book -------------------------------------------------

  # `type` is `"snapshot"` once per subscribe (or resubscribe) and `"update"` after —
  # both carry rows in the same shape, and the ONLY difference in how they are applied
  # is that a snapshot replaces the book outright while an update patches it. Folding
  # them into one clause would let a delayed snapshot silently merge into stale state
  # instead of replacing it.
  defp apply_book_event(
         %{"type" => "snapshot", "product_id" => product, "updates" => rows},
         state,
         timestamp
       )
       when is_list(rows) do
    symbol = SymbolFormat.to_canonical_symbol(product)
    book = rows |> Enum.reduce(%{bids: %{}, asks: %{}}, &apply_book_row/2)

    state
    |> put_in([Access.key(:books), symbol], book)
    |> deliver_book(symbol, timestamp)
  end

  defp apply_book_event(
         %{"type" => "update", "product_id" => product, "updates" => rows},
         state,
         timestamp
       )
       when is_list(rows) do
    symbol = SymbolFormat.to_canonical_symbol(product)
    book = Map.get(state.books, symbol, %{bids: %{}, asks: %{}})
    book = Enum.reduce(rows, book, &apply_book_row/2)

    state
    |> put_in([Access.key(:books), symbol], book)
    |> deliver_book(symbol, timestamp)
  end

  defp apply_book_event(_other, state, _timestamp), do: state

  # A price level's quantity is the venue's CURRENT total at that price, not a delta to
  # add — replacing the map entry is correct; summing it would double every level that
  # appears in two update frames in a row. `new_quantity: "0"` removes the level: it is
  # not a price of zero, it is the level no longer existing, and leaving a zero-quantity
  # entry in the book would make it a phantom best price the moment nothing outranks it.
  defp apply_book_row(%{"side" => side, "price_level" => price, "new_quantity" => quantity}, book) do
    key = book_side(side)

    case {decimal(price), decimal(quantity)} do
      {nil, _ignored} -> book
      {_ignored, nil} -> book
      {price, quantity} -> update_level(book, key, price, quantity)
    end
  end

  defp apply_book_row(_row, book), do: book

  defp book_side("bid"), do: :bids
  defp book_side(_offer_or_other), do: :asks

  defp update_level(book, side, price, quantity) do
    if Decimal.compare(quantity, 0) == :eq do
      remove_level(book, side, price)
    else
      Map.update!(book, side, &Map.put(&1, price, quantity))
    end
  end

  defp remove_level(book, side, price), do: Map.update!(book, side, &Map.delete(&1, price))

  # FAILS CLOSED on the timestamp, same as `build_quote/3` — this used to substitute
  # `DateTime.utc_now/0` unconditionally, which is the exact substitution the moduledoc
  # already warned against for the ticker path while doing it anyway here. The venue's
  # own `timestamp` is real and available on every `l2_data` message; a book whose
  # freshness cannot be stated is refused rather than stamped with whenever this process
  # happened to process the frame.
  defp deliver_book(state, symbol, timestamp) do
    book = Map.fetch!(state.books, symbol)

    case parse_time(timestamp) do
      {:ok, at} ->
        order_book = %Types.OrderBook{
          symbol: symbol,
          bids: sorted_levels(book.bids, :desc),
          asks: sorted_levels(book.asks, :asc),
          timestamp: at,
          provider: :coinbase
        }

        send(state.subscriber, {:dp_exchange, :coinbase, order_book})
        %{state | delivering: MapSet.put(state.delivering, symbol)}

      {:error, _reason} ->
        report_quality(state, symbol)
    end
  end

  defp sorted_levels(levels, :desc),
    do: Enum.sort_by(levels, fn {price, _qty} -> price end, {:desc, Decimal})

  defp sorted_levels(levels, :asc),
    do: Enum.sort_by(levels, fn {price, _qty} -> price end, {:asc, Decimal})

  defp parse_time(nil), do: {:error, :missing_venue_timestamp}

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, {:unparseable_venue_timestamp, reason}}
    end
  end

  defp parse_time(other), do: {:error, {:unparseable_venue_timestamp, other}}

  defp decimal(nil), do: nil

  # `Decimal.new/1` raises on a string that is not a number. `Decimal.parse/1`, requiring
  # the whole string be consumed, does not.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} -> parsed
      _unparsable -> nil
    end
  end

  defp decimal(_other), do: nil

  defp required_decimal(nil, field), do: {:error, {:missing_required_field, field}}

  defp required_decimal(value, field) do
    case decimal(value) do
      nil -> {:error, {:invalid_decimal, field, value}}
      parsed -> {:ok, parsed}
    end
  end

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

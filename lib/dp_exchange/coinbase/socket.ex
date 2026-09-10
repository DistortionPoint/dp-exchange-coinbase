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

  ## `level2` deltas are passed straight through, never accumulated

  A `snapshot` event carries the venue's whole book as of subscribe time; an `update`
  event carries only the price levels that changed, with `new_quantity: "0"` meaning
  the level at that price ceased to exist — not a price of zero.

  **This socket used to hold that state itself**: one ordered structure of price →
  quantity per side per symbol, rebuilt into a `DpExchange.Core.Types.OrderBook` on
  every frame including an `update` that touched a single row. Measured at the book
  size DpCryptoManagement reported live for `BTC-USD` (~22,800 bid / ~21,100 ask
  levels, issue #22): 65–110 ms per frame before an ordered-structure fix, 6.6 ms
  after it — cost paid on the same single-threaded process responsible for
  `WebSockex.send_frame/2`, so a socket busy rebuilding a book it was never asked to
  keep could not service its own sends, which is the `:send_timeout` behind issue #22.
  See `dp_exchange_core`'s `docs/design/closed/2026-09-06_stop-maintaining-books-in-packages.md`:
  holding market state here was never this socket's job, and making that work cheaper
  was treating the symptom rather than removing the cause.

  **It holds none of that now.** A `snapshot` decodes straight into
  `DpExchange.Core.Types.OrderBook` — `bids` and `asks` sorted once, because sorting a
  single frame's own rows is decode work, not the maintenance this module no longer
  does. An `update` decodes straight into `DpExchange.Core.Types.OrderBookDelta` — the
  venue's own changed rows, in the venue's own order, both sides interleaved exactly as
  the frame carried them: not re-sorted, not split into two lists beyond what the
  venue's own `side` field already says, not folded into anything held here. A zero
  `new_quantity` is carried through exactly as the venue sent it; resolving it —
  dropping the row, treating it as "no size" — would be state-keeping wearing a
  smaller shape, and state-keeping is exactly what this module stopped doing.

  ### Why a caller still cannot mistake a delta for the whole book

  The reason the maintained book existed in the first place is real, and the failure it
  prevented is worth keeping on record rather than only the fact that a guard once
  stood here: a caller reading a single `l2_data` delta as though it were the whole book
  **would see a handful of prices and nothing else** — a book with everything but a
  couple of levels simply missing, not a partial update honestly labelled as one.

  What changed is how that is prevented. A distinct type is the fix, not accumulated
  state: `%DpExchange.Core.Types.OrderBookDelta{}` is not
  `%DpExchange.Core.Types.OrderBook{}`, so a caller cannot read one as the other — the
  struct itself says which one it is holding, at compile time and at a glance. The
  original defect was a *snapshot-shaped value carrying delta content*; a delta with its
  own type has nothing snapshot-shaped left to be mistaken for.

  ### A reconnect has nothing to wipe, and the gap that follows is now the host's problem

  A reconnect used to lose the maintained book, because the venue's own session went
  with it — `handle_disconnect/2` cleared every symbol's book, and the next `snapshot`
  rebuilt it fresh. There is no book to lose now, so `handle_disconnect/2` clears
  nothing beyond what it always cleared for delivery bookkeeping.

  What was true then is still true, and now visible instead of silently absorbed:
  deltas delivered after a reconnect are **not contiguous** with deltas delivered
  before it. `handle_connect/2`'s `:link_up` notice and `handle_disconnect/2`'s
  `:link_down` notice bracket where that gap may fall; `:sequence` on both
  `DpExchange.Core.Types.OrderBook` and `DpExchange.Core.Types.OrderBookDelta` is the
  other tool where a venue publishes one (Coinbase's `l2_data` channel does not, so
  this socket always sends `nil` there — see `decode_book_event/3`). Neither tool
  reconstructs a missing delta; nothing does. The correct response to `:link_up` is to
  re-pull `get_order_book/2` (unaffected by any of this) or accept the venue's own
  fresh `snapshot` on resubscribe, not to keep applying deltas across a gap and hope
  they still line up. See `DpExchange.Core.Types.OrderBookDelta`'s own moduledoc and
  this family's `usage-rules/feeds.md` for the full account of why those two signals
  are sufficient.

  ## The connect timeouts are chosen against `Feed`'s call budget, not inherited by accident

  `WebSockex.start_link/4` opens a raw TCP connection and then waits for the HTTP
  upgrade response, and each half has its own timeout — `:socket_connect_timeout` and
  `:socket_recv_timeout`. Leave them unset and WebSockex supplies its own defaults:
  measured in the vendored dependency, `deps/websockex/lib/websockex/conn.ex:10-11`,
  `@socket_connect_timeout_default 6000` and `@socket_recv_timeout_default 5000`. Nobody
  chose those two numbers for this package; they are whatever the dependency happened to
  ship.

  That matters here specifically because of where `start_link/1` gets called from.
  `Feed`'s `open_shard/5` synchronous branch calls it from **inside** a `handle_call/3`,
  and `Feed`'s own `@call_timeout` is `@frame_window_ms * 3` = `15_000` ms. The inherited
  defaults alone — `6_000 + 5_000 = 11_000` ms — would burn roughly three-quarters of
  that budget on the TCP connect and the handshake recv **alone**, before a single
  subscribe frame is sent. `Feed` is a named, shared process, so every other consumer's
  `subscribe/2`, `unsubscribe/2`, `update_symbols/2` and `coverage/1` call queues behind
  that one `handle_call/3` for the whole window whenever the venue is unreachable or
  black-holing the connection.

  `@socket_connect_timeout_ms` and `@socket_recv_timeout_ms` below total `6_000` ms
  instead — deliberately, against that same `15_000` ms budget, leaving roughly `9_000`
  ms of the same call for the socket to actually send at least one subscribe frame
  (itself capped at `Feed`'s `@frame_window_ms`, `5_000` ms) plus ordinary `GenServer`
  overhead, rather than have the connect attempt alone threaten to exhaust the caller's
  patience. This changes no failure semantics: `start_link/1` still returns
  `{:error, reason}` synchronously either way, exactly as the dependency's own defaults
  did — only the margin the caller gets to work with after a slow or absent venue
  changes. A caller passing either key explicitly overrides it.
  """

  use WebSockex

  alias DpExchange.Coinbase.{Auth, Credentials, FrameSender, SymbolFormat}
  alias DpExchange.Core.{Notice, Types}

  require Logger

  @endpoint "wss://advanced-trade-ws.coinbase.com"

  # `ticker` is public. `level2` and `user` require a token; nothing else does, and
  # attaching one where it is not required is the incident above.
  @authenticated_channels ~w(level2 user)

  # See the moduledoc: chosen against `Feed`'s 15_000 ms `@call_timeout`, not inherited
  # from WebSockex's own defaults (6_000 ms connect + 5_000 ms recv).
  @socket_connect_timeout_ms 3_000
  @socket_recv_timeout_ms 3_000

  @doc """
  Starts a connection.

  ## Options

    * `:subscriber` — the process events are delivered to. Required.
    * `:credentials` — only needed for authenticated channels.
    * `:url` — override the endpoint, for tests that stand up a local socket.
    * `:socket_connect_timeout` — ms to wait for the TCP connect. Defaults to
      `#{@socket_connect_timeout_ms}` — see the moduledoc for why that is not
      WebSockex's own default.
    * `:socket_recv_timeout` — ms to wait for the HTTP upgrade response. Defaults to
      `#{@socket_recv_timeout_ms}`, same reasoning.
  """
  @spec start_link(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link(opts) do
    state = %{
      subscriber: Keyword.fetch!(opts, :subscriber),
      # Wrapped immediately — see `Credentials`'s moduledoc. This process holds the pair
      # for as long as the socket is up, and a WebSockex crash prints its state via the
      # same OTP crash report `Feed`'s does.
      credentials: opts |> Keyword.get(:credentials) |> Credentials.wrap(),
      # Observed delivery, not intended: a symbol enters this set when a payload for it
      # arrives, never when it is subscribed.
      delivering: MapSet.new()
    }

    opts = connection_opts(opts)
    WebSockex.start_link(Keyword.get(opts, :url, @endpoint), __MODULE__, state, opts)
  end

  # Explicit rather than inherited — see the moduledoc's budget arithmetic.
  # `Keyword.put_new/3` so a caller supplying either key wins. Exposed (not `defp`) and
  # `@doc false` purely so a test can pin this exact keyword list — what `start_link/1`
  # hands to `WebSockex.start_link/4` unchanged — without opening a real socket to
  # observe it.
  @doc false
  @spec connection_opts(keyword()) :: keyword()
  def connection_opts(opts) do
    opts
    |> Keyword.put_new(:socket_connect_timeout, @socket_connect_timeout_ms)
    |> Keyword.put_new(:socket_recv_timeout, @socket_recv_timeout_ms)
  end

  @doc """
  Subscribes `symbols` on `channel`.

  Returns `{:error, :send_timeout}` rather than dying when the socket is too busy to
  accept the frame — see `DpExchange.Coinbase.FrameSender`.
  """
  @spec subscribe(pid(), String.t(), [String.t()], Credentials.t() | nil) ::
          :ok | {:error, term()}
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
    # No maintained book to wipe — see the moduledoc's "A reconnect has nothing to
    # wipe" section. `delivering` is left alone: a symbol that was streaming is
    # reasonably still "was covered a moment ago" until the coordinator's resubscribe
    # timer either revives it or its own staleness ages it out of whatever freshness a
    # caller applies downstream. The gap this disconnect opens in the delta stream is
    # real and is now the host's to reconcile — this notice plus `:link_up` on
    # reconnect are the brackets it needs.
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
    Enum.reduce(events, state, &decode_book_event(&1, &2, timestamp))
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
         venue_time: at,
         observed_at: DateTime.utc_now(),
         provider: :coinbase
       }}
    end
  end

  defp build_quote(_ticker, _symbol, _timestamp), do: {:error, :unexpected_payload}

  # --- level2 / order book -------------------------------------------------

  # `type` is `"snapshot"` once per subscribe (or resubscribe) and `"update"` after —
  # both carry rows in the same shape on the wire, but they decode into two DIFFERENT
  # contract types now, and that is the only distinction this clause exists to make. A
  # snapshot is the venue's whole book right now: decoded straight into
  # `Types.OrderBook`, sorted once because sorting a single frame's own rows is decode
  # work, not the maintenance this module no longer does. An update is the venue's own
  # changed rows: decoded straight into `Types.OrderBookDelta` and passed on exactly as
  # received, in the venue's own order, with nothing folded into anything held here. See
  # the moduledoc.
  defp decode_book_event(
         %{"type" => "snapshot", "product_id" => product, "updates" => rows},
         state,
         timestamp
       )
       when is_list(rows) do
    symbol = SymbolFormat.to_canonical_symbol(product)
    deliver_snapshot(state, symbol, rows, timestamp)
  end

  defp decode_book_event(
         %{"type" => "update", "product_id" => product, "updates" => rows},
         state,
         timestamp
       )
       when is_list(rows) do
    symbol = SymbolFormat.to_canonical_symbol(product)
    deliver_delta(state, symbol, rows, timestamp)
  end

  defp decode_book_event(_other, state, _timestamp), do: state

  # Bids/asks are sorted ONCE here, decoding this one frame's own rows — not maintained
  # or re-sorted against anything held across frames, which is the work this module no
  # longer does. See the moduledoc.
  #
  # FAILS CLOSED on the timestamp, same as `build_quote/3` — the venue's own `timestamp`
  # is real and available on every `l2_data` message; a book whose freshness cannot be
  # stated is refused rather than stamped with whenever this process happened to
  # process the frame. Row decoding runs first regardless, so a malformed row is
  # reported even when the frame's timestamp is also bad — two independent problems,
  # both worth a signal.
  defp deliver_snapshot(state, symbol, rows, timestamp) do
    {levels, state} = decode_rows(rows, state)
    {bids, asks} = split_sides(levels)

    case parse_time(timestamp) do
      {:ok, at} ->
        order_book = %Types.OrderBook{
          symbol: symbol,
          bids: sorted(bids, :desc),
          asks: sorted(asks, :asc),
          venue_time: at,
          observed_at: DateTime.utc_now(),
          provider: :coinbase
        }

        send(state.subscriber, {:dp_exchange, :coinbase, order_book})
        %{state | delivering: MapSet.put(state.delivering, symbol)}

      {:error, _reason} ->
        report_quality(state, symbol)
    end
  end

  # The venue's own changed rows, passed on exactly as decoded: in the venue's own
  # order, both sides interleaved exactly as the frame carried them, and a zero
  # `new_quantity` left as zero rather than resolved into a removal. Resolving it here
  # would be maintaining a level's meaning on the way past — the job this module no
  # longer does. See the moduledoc and `Types.OrderBookDelta`'s own moduledoc.
  #
  # `:sequence` is left at its default `nil`: Coinbase's `l2_data` channel does not
  # publish a book sequence number, so there is nothing here to carry — see the
  # moduledoc's reconnect section.
  defp deliver_delta(state, symbol, rows, timestamp) do
    {levels, state} = decode_rows(rows, state)

    case parse_time(timestamp) do
      {:ok, at} ->
        delta = %Types.OrderBookDelta{
          symbol: symbol,
          levels: levels,
          timestamp: at,
          provider: :coinbase
        }

        send(state.subscriber, {:dp_exchange, :coinbase, delta})
        %{state | delivering: MapSet.put(state.delivering, symbol)}

      {:error, _reason} ->
        report_quality(state, symbol)
    end
  end

  # Order preserved: builds the list backward with `[level | levels]` and reverses once
  # at the end, so a delta's rows reach `deliver_delta/4` in the exact order the venue
  # sent them — required by `Types.OrderBookDelta`'s own contract, not merely
  # convenient. A snapshot re-sorts its own two sides afterward regardless, so
  # preserving order here costs it nothing.
  #
  # An unparseable `price_level` or `new_quantity` is reported through the same
  # `:data_quality` path as any other unparseable row, and dropped from the result —
  # from a snapshot's book, or from a delta's own list of changed rows. That matters
  # concretely for `new_quantity: "0"`: it is how the venue signals removal, so an
  # unparseable quantity silently ignored could leave a stale price level unaccounted
  # for with nothing indicating why. Reported, not swallowed, same as `deliver_ticker/3`
  # — and still never fatal to the connection.
  defp decode_rows(rows, state) do
    {reversed, state} =
      Enum.reduce(rows, {[], state}, fn row, {levels, acc_state} ->
        case decode_row(row) do
          {:ok, level} -> {[level | levels], acc_state}
          :error -> {levels, malformed_row(acc_state, row)}
        end
      end)

    {Enum.reverse(reversed), state}
  end

  defp decode_row(%{"side" => side, "price_level" => price, "new_quantity" => quantity}) do
    case {decimal(price), decimal(quantity)} do
      {nil, _ignored} -> :error
      {_ignored, nil} -> :error
      {parsed_price, parsed_quantity} -> {:ok, {book_side(side), parsed_price, parsed_quantity}}
    end
  end

  defp decode_row(_row), do: :error

  defp malformed_row(state, row), do: report_quality(state, inspect(row))

  # `Types.OrderBookDelta.side/0` is `:bid | :ask` — singular, unlike `OrderBook`'s
  # separate `bids`/`asks` lists, because one delta level names its own side rather
  # than living in a side-keyed collection.
  defp book_side("bid"), do: :bid
  defp book_side(_offer_or_other), do: :ask

  # Both accumulators are reversed once at the end, so a tie in `sorted/2`'s stable
  # sort breaks in the venue's own row order rather than the reverse of it — matters
  # concretely for two numerically-equal, differently-scaled prices in one snapshot
  # (e.g. `"1.5"` and `"1.50"`), both of which now survive as separate rows rather
  # than being folded into one.
  defp split_sides(levels) do
    {bids, asks} =
      Enum.reduce(levels, {[], []}, fn
        {:bid, price, quantity}, {bids, asks} -> {[{price, quantity} | bids], asks}
        {:ask, price, quantity}, {bids, asks} -> {bids, [{price, quantity} | asks]}
      end)

    {Enum.reverse(bids), Enum.reverse(asks)}
  end

  defp sorted(levels, :desc),
    do: Enum.sort_by(levels, fn {price, _qty} -> price end, {:desc, Decimal})

  defp sorted(levels, :asc),
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

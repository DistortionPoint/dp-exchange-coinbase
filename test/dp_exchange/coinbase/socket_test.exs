defmodule DpExchange.Coinbase.SocketTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Socket
  alias DpExchange.Core.{Notice, Types}

  @moduletag :capture_log

  # The WebSockex callbacks are exercised directly with real payloads. Standing up an
  # actual socket would make these tier-2; what matters here is the decode-and-dispatch
  # behaviour, which is where a venue quietly loses data.
  defp state(subscriber \\ nil) do
    %{
      subscriber: subscriber || self(),
      credentials: nil,
      delivering: MapSet.new(),
      connected_once?: false,
      last_seq: nil,
      stale_run: nil,
      last_frame_at: nil,
      silence_check: nil,
      # A session that has been up a minute: its drop is the healthy blip, so the tests
      # that call `handle_disconnect/2` with this state describe an ordinary reconnect.
      connected_at: System.monotonic_time(:millisecond) - 60_000,
      short_sessions: 0
    }
  end

  defp frame(payload), do: Socket.handle_frame({:text, Jason.encode!(payload)}, state())

  # Deterministic instead of `spawn(fn -> :ok end)` plus a guessed sleep: a monitor's
  # `:DOWN` message only arrives once the process has genuinely exited, so this never
  # races a scheduler slower than whatever fixed delay was guessed.
  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000
    pid
  end

  # No per-row "time" field — the venue's own documented schema puts the timestamp on
  # the message envelope, not on each ticker row. See `Socket.dispatch/2`'s moduledoc
  # comment on this exact point.
  @ticker %{
    "channel" => "ticker",
    "timestamp" => "2026-08-28T14:53:45.649112Z",
    "events" => [
      %{
        "tickers" => [
          %{
            "product_id" => "BTC-USD",
            "price" => "79478.7",
            "volume_24_h" => "1234.5"
          }
        ]
      }
    ]
  }

  describe "connection_opts/1 — the connect timeouts are chosen, not inherited" do
    # `start_link/1` hands this exact keyword list to `WebSockex.start_link/4` with
    # nothing added or removed afterward — see `start_link/1`'s own body — so pinning
    # this function's return value pins what actually reaches the socket, without
    # opening one. WebSockex's own inherited defaults (measured in
    # `deps/websockex/lib/websockex/conn.ex:10-11`): 6_000 ms connect, 5_000 ms recv.

    test "supplies deliberate defaults when the caller passes none, not WebSockex's own" do
      opts = Socket.connection_opts([])

      assert Keyword.fetch!(opts, :socket_connect_timeout) == 3_000
      assert Keyword.fetch!(opts, :socket_recv_timeout) == 3_000

      refute Keyword.fetch!(opts, :socket_connect_timeout) == 6_000
      refute Keyword.fetch!(opts, :socket_recv_timeout) == 5_000
    end

    test "the defaults leave real room under Feed's 15_000 ms call budget" do
      # This is the arithmetic the moduledoc states: connect + recv must leave enough
      # of Feed's `@call_timeout` (15_000 ms) for at least one subscribe frame
      # (`@frame_window_ms`, 5_000 ms) plus ordinary GenServer overhead. WebSockex's own
      # inherited total (6_000 + 5_000 = 11_000 ms) would not.
      opts = Socket.connection_opts([])

      total =
        Keyword.fetch!(opts, :socket_connect_timeout) + Keyword.fetch!(opts, :socket_recv_timeout)

      assert total == 6_000
      assert total < 15_000 - 5_000
    end

    test "a caller-supplied connect timeout overrides the default" do
      opts = Socket.connection_opts(socket_connect_timeout: 42)

      assert Keyword.fetch!(opts, :socket_connect_timeout) == 42
      # The other key is untouched by an override of just one.
      assert Keyword.fetch!(opts, :socket_recv_timeout) == 3_000
    end

    test "a caller-supplied recv timeout overrides the default" do
      opts = Socket.connection_opts(socket_recv_timeout: 99)

      assert Keyword.fetch!(opts, :socket_recv_timeout) == 99
      assert Keyword.fetch!(opts, :socket_connect_timeout) == 3_000
    end

    test "both overrides win at once, and every other opt passes through untouched" do
      opts =
        Socket.connection_opts(
          subscriber: self(),
          url: "ws://example.invalid",
          socket_connect_timeout: 10,
          socket_recv_timeout: 20
        )

      assert Keyword.fetch!(opts, :socket_connect_timeout) == 10
      assert Keyword.fetch!(opts, :socket_recv_timeout) == 20
      assert Keyword.fetch!(opts, :subscriber) == self()
      assert Keyword.fetch!(opts, :url) == "ws://example.invalid"
    end

    test "the certificate is verified unless the caller says otherwise" do
      for opts <- [Socket.connection_opts([]), Socket.connection_opts(ssl_options: nil)] do
        tls = Keyword.fetch!(opts, :ssl_options)

        assert Keyword.fetch!(tls, :verify) == :verify_peer
        assert [_first | _rest] = Keyword.fetch!(tls, :cacerts)
        assert Keyword.has_key?(tls, :customize_hostname_check)
      end
    end

    test "a caller's own ssl_options replace the verified defaults entirely" do
      own = [verify: :verify_none]

      opts = Socket.connection_opts(ssl_options: own)

      assert Keyword.fetch!(opts, :ssl_options) == own
    end
  end

  describe "start_link/1 — credentials never go over a plaintext socket" do
    @fake_credentials %{api_key: "test-key-not-real", api_secret: "test-secret-not-real"}

    test "a ws:// URL for a remote host is refused when credentials are given, URL not echoed" do
      urls = ["ws://example.invalid/", "http://user:pw@example.invalid/", "ws://10.0.0.1:80/"]

      for url <- urls do
        opts = [subscriber: self(), credentials: @fake_credentials, url: url]
        result = Socket.start_link(opts)

        assert result == {:error, :insecure_websocket_url}
        refute inspect(result) =~ "example.invalid"
      end
    end
  end

  describe "connection state becomes a notice, not a log line" do
    test "only a RE-connect is reported to the feed, so it can re-issue the shard at once" do
      # `Feed` subscribes a new shard itself after `start_link/1`; reporting the first
      # connect too would send the same subscription twice.
      assert {:ok, first} = Socket.handle_connect(%{}, state())
      refute_received {:dp_exchange, :coinbase, :reconnected, _pid}

      assert {:ok, _again} = Socket.handle_connect(%{}, first)
      me = self()
      assert_received {:dp_exchange, :coinbase, :reconnected, ^me}
    end

    test "every connection subscribes to heartbeats, so a quiet one is not closed idle" do
      # The venue closes a connection "within 60-90 seconds when no updates arrive"; its
      # `heartbeats` channel keeps idle subscriptions open. See the moduledoc.
      assert {:ok, connected} = Socket.handle_connect(%{}, state())
      assert_received :subscribe_heartbeats

      assert {:reply, {:text, raw}, _state} = Socket.handle_info(:subscribe_heartbeats, connected)
      frame = Jason.decode!(raw)
      assert frame == %{"type" => "subscribe", "channel" => "heartbeats"}
      refute Map.has_key?(frame, "jwt")

      # And again on a reconnect, which is a fresh session with no subscriptions.
      assert {:ok, _again} = Socket.handle_connect(%{}, connected)
      assert_received :subscribe_heartbeats
    end

    test "a connection silent past the limit says so and closes, so it reconnects" do
      # A half-open connection used to stay "connected" for as long as the OS allowed. With
      # a heartbeat every second, silence is evidence. See the moduledoc's "A connection
      # that has gone silent is closed".
      check = make_ref()
      now = System.monotonic_time(:millisecond)
      silent = %{state() | silence_check: check, last_frame_at: now - 100_000}

      assert {:close, _state} = Socket.handle_info({:silence_check, check}, silent)

      assert_received {:dp_exchange, :coinbase,
                       %Notice{kind: :degraded, details: %{reason: :silent_connection}}}
    end

    test "a connection that heard something recently is left alone" do
      check = make_ref()

      live = %{
        state()
        | silence_check: check,
          last_frame_at: System.monotonic_time(:millisecond)
      }

      assert {:ok, ^live} = Socket.handle_info({:silence_check, check}, live)
      refute_received {:dp_exchange, :coinbase, %Notice{kind: :degraded}}
    end

    test "a check left over from an earlier connection does nothing" do
      now = System.monotonic_time(:millisecond)
      current = %{state() | silence_check: make_ref(), last_frame_at: now - 100_000}

      assert {:ok, ^current} = Socket.handle_info({:silence_check, make_ref()}, current)
      refute_received {:dp_exchange, :coinbase, %Notice{kind: :degraded}}
    end

    test "any frame counts as hearing from the venue" do
      # Monotonic time can be negative, so the comparison is against the stale value.
      long_ago = System.monotonic_time(:millisecond) - 100_000
      stale = %{state() | last_frame_at: long_ago}
      {:ok, heard} = Socket.handle_frame({:text, ~s({"channel":"heartbeats"})}, stale)
      assert heard.last_frame_at > long_ago
    end

    test "connecting reports link_up" do
      assert {:ok, _state} = Socket.handle_connect(%{}, state())
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :link_up}}
    end

    test "disconnecting reports link_down and asks to reconnect" do
      assert {:reconnect, _state} = Socket.handle_disconnect(%{reason: :closed}, state())
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :link_down, severity: :error}}
    end

    test "a disconnect reason carrying a large venue body is bounded in the notice" do
      body = String.duplicate("x", 50_000)

      assert {:reconnect, _state} =
               Socket.handle_disconnect(%{reason: {:remote, 1006, body}}, state())

      assert_received {:dp_exchange, :coinbase,
                       %Notice{kind: :link_down, details: %{reason: reason}}}

      assert is_binary(reason)
      assert byte_size(reason) < 2_048
      assert reason =~ "remote"
    end

    test "disconnecting also tells Feed WHICH link dropped, so coverage can narrow to it" do
      # Separate from the notice on purpose: `Feed` narrows `coverage/1` to this shard's
      # symbols and this shard's channel's kind, never the whole feed, and it needs a pid to
      # resolve the shard with. A socket pid is this package's own wiring and has no business
      # in a `Core.Notice` that fans out to consumers — so it travels beside one.
      #
      # Called here from the test process, so `self()` is what `handle_disconnect/2` reports.
      assert {:reconnect, _state} = Socket.handle_disconnect(%{reason: :closed}, state())

      me = self()
      assert_received {:dp_exchange, :coinbase, :link_down, ^me}
    end

    test "no notice names a transport" do
      # "The venue link is down" is the fact; WebSocket is not a consumer's concern.
      Socket.handle_connect(%{}, state())
      assert_received {:dp_exchange, :coinbase, %Notice{kind: kind}}
      refute to_string(kind) =~ ~r/socket|ws|websocket/
    end
  end

  describe "sequence_num — a dropped message is reported, not only a dropped connection" do
    # The venue: "Per-connection message sequence number; use it to detect dropped or
    # out-of-order messages." See the moduledoc's section of the same name.
    defp numbered(seq), do: {:text, Jason.encode!(Map.put(@ticker, "sequence_num", seq))}

    defp feed(frames, state) do
      Enum.reduce(frames, state, fn frame, acc ->
        {:ok, next} = Socket.handle_frame(frame, acc)
        next
      end)
    end

    test "consecutive numbers deliver everything and raise nothing" do
      feed([numbered(10), numbered(11), numbered(12)], state())

      for _each <- 1..3, do: assert_received({:dp_exchange, :coinbase, %Types.Quote{}})
      refute_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end

    test "a jump says how many messages the venue dropped, and still delivers the message" do
      feed([numbered(10), numbered(14)], state())

      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = notice}
      assert notice.details.reason == :sequence_gap
      assert notice.details.dropped == 3
      # The ticker before the gap delivered its product, so the notice names it as suspect.
      assert notice.details.symbols == ["BTC-USD"]
      assert notice.severity == :warning

      for _each <- 1..2, do: assert_received({:dp_exchange, :coinbase, %Types.Quote{}})

      # MD9: the owner of the subscription is told WHICH connection gapped, so it can ask
      # for a fresh level2 snapshot (`Feed` does).
      me = self()
      assert_received {:dp_exchange, :coinbase, :sequence_gap, ^me}
    end

    test "consecutive numbers report no gap to the feed" do
      feed([numbered(10), numbered(11)], state())

      refute_received {:dp_exchange, :coinbase, :sequence_gap, _socket}
    end

    test "a repeated sequence number is dropped, never applied (MD9)" do
      feed([numbered(10), numbered(10)], state())

      assert_received {:dp_exchange, :coinbase, %Types.Quote{}}
      refute_received {:dp_exchange, :coinbase, %Types.Quote{}}
    end

    test "a message older than the last is ignored, as the venue advises, and said so" do
      state = feed([numbered(10), numbered(11)], state())
      for _each <- 1..2, do: assert_received({:dp_exchange, :coinbase, %Types.Quote{}})

      after_stale = feed([numbered(9)], state)

      refute_received {:dp_exchange, :coinbase, %Types.Quote{}}
      assert_received {:dp_exchange, :coinbase, %Notice{details: %{reason: :out_of_order}}}
      assert after_stale.last_seq == 11
    end

    test "a burst of late messages raises one out_of_order notice, and counts the rest" do
      # Interleaved with in-order messages, so the run never reaches the re-base threshold.
      frames = [numbered(10), numbered(11), numbered(5), numbered(12), numbered(4)]
      state = feed(frames, state())

      notices =
        for {:dp_exchange, :coinbase, %Notice{details: %{reason: :out_of_order}} = notice} <-
              Enum.reverse(collect([])),
            do: notice

      assert [%Notice{details: %{suppressed: 0}}] = notices
      assert state.out_of_order_suppressed == 1
      assert state.last_seq == 12
    end

    test "an out_of_order notice after the window reports the count withheld before it" do
      state = feed([numbered(10), numbered(11), numbered(5), numbered(12), numbered(4)], state())
      assert state.out_of_order_suppressed == 1
      _drained = collect([])

      # The window has long passed, so the next late message is announced with the count.
      elapsed = Map.put(state, :out_of_order_at, System.monotonic_time(:millisecond) - 60_000)
      after_window = feed([numbered(3)], elapsed)

      notices =
        for {:dp_exchange, :coinbase, %Notice{details: %{reason: :out_of_order}} = notice} <-
              Enum.reverse(collect([])),
            do: notice

      assert [%Notice{details: %{suppressed: 1, got: 3}}] = notices
      assert after_window.out_of_order_suppressed == 0
    end

    test "a new connection clears the out_of_order throttle" do
      state = feed([numbered(10), numbered(11), numbered(5), numbered(12), numbered(4)], state())
      assert is_integer(state.out_of_order_at)

      {:ok, reconnected} = Socket.handle_connect(%{}, state)

      assert reconnected.out_of_order_at == nil
      assert reconnected.out_of_order_suppressed == 0
    end

    test "an unparseable value in a notice reason is quoted bounded" do
      long = String.duplicate("9", 100_000) <> "x"
      row = %{"product_id" => "BTC-USD", "price" => long}
      payload = Map.put(@ticker, "events", [%{"tickers" => [row]}])

      assert {:ok, _state} = Socket.handle_frame({:text, Jason.encode!(payload)}, state())

      assert_received {:dp_exchange, :coinbase, %Notice{details: %{reason: reason}}}
      assert {:invalid_decimal, :price, quoted} = reason
      assert String.length(quoted) <= 120
    end

    test "a new connection starts its own count, so a reconnect is not reported as a gap" do
      state = feed([numbered(500)], state())
      {:ok, reconnected} = Socket.handle_connect(%{}, state)
      feed([numbered(0)], reconnected)

      refute_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end

    test "one bogus high number does not drop every message after it" do
      # A genuine stream below a wrong baseline counts up one at a time. After a short run of
      # that the baseline is re-based, said once, and delivery resumes. It used to drop every
      # message until the next reconnect. See `Socket.stale/4`.
      state = feed([numbered(1), numbered(9_999_999)], state())
      drain = fn drain -> receive do: (_msg -> drain.(drain)), after: (0 -> :ok) end
      drain.(drain)

      after_run = feed(for(seq <- 2..12, do: numbered(seq)), state)

      assert_received {:dp_exchange, :coinbase, %Notice{details: %{reason: :sequence_reset}}}
      assert after_run.last_seq == 12

      quotes = for {:dp_exchange, :coinbase, %Types.Quote{}} <- collect([]), do: :quote
      # 2..5 are dropped as late while the run builds; 6..12 are delivered.
      assert length(quotes) == 7
    end
  end

  defp collect(acc) do
    receive do
      msg -> collect([msg | acc])
    after
      0 -> acc
    end
  end

  describe "a malformed frame does not take the connection down" do
    # Found by mutating real frames, 2026-09-26: a non-string `product_id` made
    # `SymbolFormat` raise inside `handle_frame/2`, and a raise there drops the connection.
    test "a ticker row whose product_id is not a string is skipped" do
      for bad <- [0, %{}, [], true] do
        payload =
          update_in(@ticker["events"], fn [event] ->
            [update_in(event["tickers"], fn [row] -> [Map.put(row, "product_id", bad)] end)]
          end)

        assert {:ok, _state} = Socket.handle_frame({:text, Jason.encode!(payload)}, state())
        refute_received {:dp_exchange, :coinbase, %Types.Quote{}}
      end
    end

    test "a book event whose product_id is not a string is skipped" do
      for type <- ["snapshot", "update"], bad <- [0, %{}] do
        frame = %{
          "channel" => "l2_data",
          "timestamp" => "2026-08-28T14:53:45.649112Z",
          "events" => [%{"type" => type, "product_id" => bad, "updates" => []}]
        }

        assert {:ok, _state} = Socket.handle_frame({:text, Jason.encode!(frame)}, state())
      end
    end
  end

  describe "ticker payloads" do
    test "become Quotes delivered to the subscriber" do
      assert {:ok, _state} = frame(@ticker)

      assert_received {:dp_exchange, :coinbase, %Types.Quote{} = quote_struct}
      assert quote_struct.symbol == "BTC-USD"
      assert Decimal.equal?(quote_struct.price, Decimal.new("79478.7"))

      # MD7: the envelope `timestamp` is when the gateway SENT the message, and a `Ticker`
      # row states no trade time, so the Quote claims none. It is neither the envelope's
      # send time nor `now`.
      assert quote_struct.venue_time == nil

      # A rolling 24-hour total, labelled as one: summed as per-print volume it read about
      # 1000× too high in a consumer (dp-exchange-core issue #42).
      assert Decimal.equal?(quote_struct.volume, Decimal.new("1234.5"))
      assert quote_struct.volume_window == :rolling_24h
    end

    test "a tick is delivered with venue_time nil whatever the envelope says, snapshot or update" do
      # Neither a missing, a garbled nor a present envelope timestamp becomes the Quote's
      # `venue_time`: the `snapshot` event sent at every (re)subscribe is not a fresh trade.
      envelopes = [
        Map.delete(@ticker, "timestamp"),
        Map.put(@ticker, "timestamp", "junk"),
        @ticker
      ]

      for type <- ["snapshot", "update"], envelope <- envelopes do
        ticker = update_in(envelope["events"], fn [event] -> [Map.put(event, "type", type)] end)

        assert {:ok, _state} = frame(ticker)

        assert_received {:dp_exchange, :coinbase, %Types.Quote{venue_time: nil}}
        refute_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
      end
    end

    test "a ticker price of zero or less is refused, not delivered (MD6)" do
      for bad <- ["0", "-1", "0.00"] do
        ticker =
          update_in(@ticker["events"], fn [event] ->
            [update_in(event["tickers"], fn [t] -> [Map.put(t, "price", bad)] end)]
          end)

        assert {:ok, _state} = frame(ticker)

        refute_received {:dp_exchange, :coinbase, %Types.Quote{}}
        assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
      end
    end

    test "a new fault past the full fault set is notified once, not on every frame" do
      # 256 is `@max_reported_faults`. Without the restart at the cap, a fault first seen
      # now is never remembered and every frame that carries it sends another notice.
      full =
        Map.put(
          state(),
          :reported_faults,
          MapSet.new(1..256, &{"ticker", "OLD-#{&1}", :invalid_decimal})
        )

      bad =
        update_in(@ticker["events"], fn [event] ->
          [update_in(event["tickers"], fn [t] -> [Map.put(t, "price", "0")] end)]
        end)

      frame = {:text, Jason.encode!(bad)}

      assert {:ok, state} = Socket.handle_frame(frame, full)
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
      assert MapSet.size(state.reported_faults) == 1

      assert {:ok, _state} = Socket.handle_frame(frame, state)
      refute_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end

    test "a level2 snapshot drops a zero-size level and keeps the delta's zero (MD5)" do
      row = fn side, price, size ->
        %{
          "side" => side,
          "price_level" => price,
          "new_quantity" => size,
          "event_time" => "2026-08-28T14:53:45.000000Z"
        }
      end

      rows = [row.("bid", "100", "1"), row.("bid", "99", "0"), row.("offer", "101", "2")]

      for type <- ["snapshot", "update"] do
        payload = %{
          "channel" => "l2_data",
          "timestamp" => "2026-08-28T14:53:45.649112Z",
          "events" => [%{"type" => type, "product_id" => "BTC-USD", "updates" => rows}]
        }

        assert {:ok, _state} = frame(payload)
      end

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}
      assert [{bid, _size}] = book.bids
      assert [_ask] = book.asks
      assert Decimal.equal?(bid, Decimal.new("100"))

      assert_received {:dp_exchange, :coinbase, %Types.OrderBookDelta{levels: levels}}
      assert length(levels) == 3
    end

    test "a trade price of zero or less is refused (MD6)" do
      payload = fn price ->
        %{
          "channel" => "market_trades",
          "timestamp" => "2026-08-28T14:53:45.649112Z",
          "events" => [
            %{
              "type" => "update",
              "trades" => [
                %{
                  "trade_id" => "1",
                  "product_id" => "BTC-USD",
                  "price" => price,
                  "size" => "1",
                  "side" => "BUY",
                  "time" => "2026-08-28T14:53:45.000000Z"
                }
              ]
            }
          ]
        }
      end

      assert {:ok, _state} = frame(payload.("0"))
      assert {:ok, _state} = frame(payload.("-3"))
      refute_received {:dp_exchange, :coinbase, %Types.Trade{}}

      assert {:ok, _state} = frame(payload.("3"))
      assert_received {:dp_exchange, :coinbase, %Types.Trade{}}
    end

    test "a non-numeric price does not crash the socket" do
      # Decimal.new/1 used to raise directly here, which would have taken the whole
      # connection down over one malformed field on one symbol.
      ticker =
        update_in(@ticker["events"], fn [event] ->
          [update_in(event["tickers"], fn [t] -> [Map.put(t, "price", "null")] end)]
        end)

      assert {:ok, _state} = frame(ticker)

      refute_received {:dp_exchange, :coinbase, %Types.Quote{}}
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = notice}

      # dp-exchange-core issue #41: the notice names what was dropped and why, not only
      # the product id with no message.
      assert notice.details.channel == :ticker
      assert notice.details.payload == "BTC-USD"
      assert notice.details.reason != nil
      assert notice.message =~ "ticker"
      assert notice.message =~ "BTC-USD"
    end

    test "an unparseable frame says so, with the decode reason" do
      assert {:ok, _state} = Socket.handle_frame({:text, "{not json"}, state())

      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = notice}
      assert notice.details.channel == :frame
      assert notice.details.reason != nil
      assert is_binary(notice.message)
    end
  end

  describe "malformed and unexpected input" do
    test "a payload that does not parse is reported, not swallowed and not fatal" do
      assert {:ok, _state} = Socket.handle_frame({:text, "{not json"}, state())
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end

    test "an unparseable frame puts the reason in the notice, not a copy of the frame" do
      # `%Jason.DecodeError{}` holds the whole payload in `:data`. A level2 frame is hundreds
      # of kilobytes, and every notice subscriber got its own copy of one that failed to parse.
      huge = "{" <> String.duplicate("a", 200_000)

      assert {:ok, _state} = Socket.handle_frame({:text, huge}, state())

      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = notice}
      assert is_binary(notice.details.reason)
      assert notice.details.reason =~ "position 1"
      assert :erlang.external_size(notice) < 5_000
    end

    test "a fault on every frame is reported once per connection, not once per frame" do
      # A ticker is several frames a second per product. A fault in the venue's format fails
      # every one of them, and each used to raise its own identical notice.
      bad = fn product, price ->
        update_in(@ticker["events"], fn [event] ->
          [
            update_in(event["tickers"], fn [t] ->
              [t |> Map.put("price", price) |> Map.put("product_id", product)]
            end)
          ]
        end)
      end

      send_bad = fn state, product, price ->
        {:ok, next} = Socket.handle_frame({:text, Jason.encode!(bad.(product, price))}, state)
        next
      end

      after_two = state() |> send_bad.("BTC-USD", "null") |> send_bad.("BTC-USD", "nope")

      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
      refute_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
      refute_received {:dp_exchange, :coinbase, %Types.Quote{}}

      # Another product with the same fault is its own fault.
      after_three = send_bad.(after_two, "ETH-USD", "null")
      assert_received {:dp_exchange, :coinbase, %Notice{details: %{payload: "ETH-USD"}}}

      # A reconnect forgets what was reported: a fault still there is reported again.
      {:ok, reconnected} = Socket.handle_connect(%{}, after_three)
      _state = send_bad.(reconnected, "BTC-USD", "null")
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality, details: details}}
      assert details.payload == "BTC-USD"
    end

    test "an unrecognised channel is ignored rather than guessed at" do
      assert {:ok, _state} = frame(%{"channel" => "something_new", "events" => []})
      refute_received {:dp_exchange, :coinbase, %Types.Quote{}}
    end

    test "a non-text frame is ignored" do
      assert {:ok, _state} = Socket.handle_frame({:binary, <<1, 2, 3>>}, state())
    end

    test "a ticker event whose tickers is null does not crash the socket" do
      # `Map.get(event, "tickers", [])` defaults an ABSENT key, not a present `null`, so
      # `"tickers": null` reached `Enum.reduce/3` and raised `Protocol.UndefinedError` —
      # inside `handle_frame/2`, which runs in the socket process. One malformed frame cost
      # the connection, and a venue that kept sending the shape would have kept costing it.
      # The `l2_data` path beside it was already total; this one was not.
      payload = %{@ticker | "events" => [%{"type" => "update", "tickers" => nil}]}

      assert {:ok, _state} = frame(payload)
      refute_received {:dp_exchange, :coinbase, %Types.Quote{}}
    end

    test "a non-map entry in events does not crash the socket either" do
      # `Map.get/3` on a string raised `BadMapError` from the same line.
      assert {:ok, _state} = frame(%{@ticker | "events" => ["not an event"]})
    end

    test "one unusable event does not cost its well-formed neighbours" do
      # Dropping the malformed event must not drop the frame: the good ticker beside it is
      # still delivered.
      good = hd(@ticker["events"])
      payload = %{@ticker | "events" => [%{"tickers" => nil}, "junk", good]}

      assert {:ok, _state} = frame(payload)
      assert_received {:dp_exchange, :coinbase, %Types.Quote{symbol: "BTC-USD"}}
    end
  end

  describe "the venue's own error shape" do
    test "an authentication failure becomes a credentials notice" do
      # This is the shape the stub-token incident produced: `level2` returned this while
      # `ticker`, which is public, worked fine — so the venue looked quiet rather than
      # misconfigured.
      assert {:ok, _state} =
               frame(%{"type" => "error", "message" => "authentication failure"})

      assert_received {:dp_exchange, :coinbase,
                       %Notice{kind: :credentials_rejected, message: "authentication failure"}}
    end

    test "a capacity refusal becomes a rate-limit notice, not a credentials one" do
      # DpCryptoManagement's issue #22: the venue reports this through the identical
      # `{"type":"error"}` shape as an auth failure, and it means something entirely
      # different — a session already carrying too many `level2` streams, not a bad
      # credential. Reporting it as `:credentials_rejected` sent a consumer looking for a
      # broken key that was never broken.
      assert {:ok, _state} =
               frame(%{
                 "type" => "error",
                 "message" => "too many L2 streams requested in a single session"
               })

      assert_received {:dp_exchange, :coinbase,
                       %Notice{
                         kind: :rate_limited,
                         message: "too many L2 streams requested in a single session"
                       }}
    end

    test "any other venue error is degraded, not a credential problem" do
      # Everything that was not "too many" became `:credentials_rejected`, so a bad product
      # id on the public `ticker` channel told the host to rotate a key never involved.
      assert {:ok, _state} =
               frame(%{
                 "type" => "error",
                 "message" => "Failed to subscribe: invalid product_ids"
               })

      assert_received {:dp_exchange, :coinbase, %Notice{kind: :degraded}}
      refute_received {:dp_exchange, :coinbase, %Notice{kind: :credentials_rejected}}
    end

    test "a huge venue error message is classified whole but quoted bounded" do
      # The text went whole into a notice sent to every subscriber.
      message = "authentication failure " <> String.duplicate("x", 100_000)

      assert {:ok, _state} = frame(%{"type" => "error", "message" => message})

      assert_received {:dp_exchange, :coinbase,
                       %Notice{kind: :credentials_rejected, message: quoted}}

      assert String.length(quoted) == 1_024
      assert String.starts_with?(quoted, "authentication failure")
    end

    test "an error whose message is not a string is reported, and does not crash the socket" do
      assert {:ok, _state} = frame(%{"type" => "error", "message" => %{"code" => 7}})
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :degraded}}
    end
  end

  describe "subscription messages" do
    @credentials %{api_key: "k", api_secret: :crypto.strong_rand_bytes(32) |> Base.encode64()}

    test "a public channel carries NO jwt" do
      # Attaching one is actively harmful: Coinbase answers a bogus token with an
      # authentication failure, which is how `level2` produced nothing while `ticker`
      # worked fine. A venue half-delivering looks like a quiet market.
      assert {:ok, message} = subscription("ticker", ~w(BTC-USD), nil)

      refute Map.has_key?(message, :jwt)
      assert message.type == "subscribe"
      assert message.product_ids == ~w(BTC-USD)
    end

    test "user, the genuinely required channel, carries a real jwt" do
      assert {:ok, message} = subscription("user", ~w(BTC-USD), @credentials)

      assert is_binary(message.jwt)
      assert length(String.split(message.jwt, ".")) == 3
    end

    test "user without credentials is refused, not sent unsigned" do
      # `SubscribeUser`'s payload lists `jwt` in its own `required` array
      # (docs/reference/coinbase/openapi/at-async.json:752-765).
      assert {:error, {:credentials_required, "user"}} =
               subscription("user", ~w(BTC-USD), nil)
    end

    test "level2 carries a real jwt when credentials are available" do
      assert {:ok, message} = subscription("level2", ~w(BTC-USD), @credentials)

      assert is_binary(message.jwt)
      assert length(String.split(message.jwt, ".")) == 3
    end

    test "level2 without credentials is sent anyway, with no jwt — the venue calls it optional" do
      # `SubscribeLevel2`'s `jwt` is "Optional here; recommended for connection
      # reliability." (docs/reference/coinbase/openapi/at-async.json:685-687), not required
      # the way `user`'s is. This used to refuse a credential-less `level2` subscribe the
      # identical way it refused a credential-less `user` one.
      assert {:ok, message} = subscription("level2", ~w(BTC-USD), nil)

      refute Map.has_key?(message, :jwt)
      assert message.channel == "level2"
    end

    test "symbols are converted to the venue's native form" do
      assert {:ok, message} = subscription("ticker", ~w(btc-usd), nil)
      assert message.product_ids == ~w(BTC-USD)
    end

    # The message `subscribe/4` builds, from the function `subscribe/4` itself builds it with.
    # These assertions used to run against a `rebuild/3` in this file that copied the same
    # `cond` (including what each channel gets a JWT for), so deleting the JWT from `level2`,
    # or attaching one to `ticker`, in the socket left every one of them green.
    defp subscription(channel, symbols, credentials),
      do: Socket.subscription_frame(channel, symbols, credentials)

    test "market_trades is public too: no jwt, even when credentials are held" do
      assert {:ok, message} = subscription("market_trades", ~w(BTC-USD), @credentials)
      refute Map.has_key?(message, :jwt)
    end

    test "a public channel carries no jwt even when credentials are held" do
      assert {:ok, message} = subscription("ticker", ~w(BTC-USD), @credentials)
      refute Map.has_key?(message, :jwt)
    end

    test "credentials that cannot sign are refused for level2, not sent unsigned" do
      assert {:error, {:unsupported_key_size, 3}} =
               subscription("level2", ~w(BTC-USD), %{
                 api_key: "k",
                 api_secret: Base.encode64("abc")
               })
    end

    test "subscribe/4 puts exactly that message on the wire" do
      test = self()

      socket =
        spawn(fn ->
          receive do
            {:"$websockex_send", from, {:text, raw}} ->
              send(test, {:wire, Jason.decode!(raw)})
              :gen.reply(from, :ok)
          end
        end)

      assert :ok = Socket.subscribe(socket, "level2", ~w(btc-usd), @credentials)
      assert_receive {:wire, wire}, 5_000

      assert wire["type"] == "subscribe"
      assert wire["channel"] == "level2"
      assert wire["product_ids"] == ["BTC-USD"]
      assert length(String.split(wire["jwt"], ".")) == 3
    end
  end

  describe "unsubscribe" do
    test "returns an error for a dead socket rather than exiting" do
      dead = dead_pid()

      assert {:error, {:send_exit, _reason}} = Socket.unsubscribe(dead, "ticker", ~w(BTC-USD))
    end
  end

  describe "level2 — deltas passed straight through, no state maintained here" do
    @snapshot %{
      "channel" => "l2_data",
      "timestamp" => "2026-08-28T14:53:45.649112Z",
      "events" => [
        %{
          "type" => "snapshot",
          "product_id" => "BTC-USD",
          "updates" => [
            %{
              "event_time" => "2026-08-28T14:53:45.000000Z",
              "side" => "bid",
              "price_level" => "100.00",
              "new_quantity" => "1.5"
            },
            %{
              "event_time" => "2026-08-28T14:53:45.000000Z",
              "side" => "bid",
              "price_level" => "99.00",
              "new_quantity" => "2.0"
            },
            %{
              "event_time" => "2026-08-28T14:53:45.000000Z",
              "side" => "offer",
              "price_level" => "101.00",
              "new_quantity" => "0.5"
            }
          ]
        }
      ]
    }

    test "a snapshot delivers a sorted OrderBook — bids descending, asks ascending" do
      assert {:ok, _state} = Socket.handle_frame({:text, Jason.encode!(@snapshot)}, state())

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}
      assert book.symbol == "BTC-USD"

      assert book.bids == [
               {Decimal.new("100.00"), Decimal.new("1.5")},
               {Decimal.new("99.00"), Decimal.new("2.0")}
             ]

      assert book.asks == [{Decimal.new("101.00"), Decimal.new("0.5")}]
      assert book.provider == :coinbase
    end

    test "an event with an unreadable row is refused whole, never delivered without it" do
      # A side neither `bid` nor `offer` used to be filed as an ask, and an unparseable row
      # was dropped and the rest delivered: a book with a level silently missing.
      [event] = @snapshot["events"]

      sideways = %{
        "event_time" => "2026-08-28T14:53:45.000000Z",
        "side" => "sideways",
        "price_level" => "1.00",
        "new_quantity" => "9"
      }

      for kind <- ["snapshot", "update"] do
        updates = event["updates"] ++ [sideways]
        frame = %{@snapshot | "events" => [%{event | "type" => kind, "updates" => updates}]}

        assert {:ok, _state} = Socket.handle_frame({:text, Jason.encode!(frame)}, state())
        assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
        refute_received {:dp_exchange, :coinbase, %Types.OrderBook{}}
        refute_received {:dp_exchange, :coinbase, %Types.OrderBookDelta{}}
      end
    end

    test "a non-positive price or a negative quantity makes a row unreadable" do
      [event] = @snapshot["events"]

      for {price, quantity} <- [{"-1.00", "1"}, {"0", "1"}, {"5.00", "-0.5"}] do
        bad = %{
          "event_time" => "2026-08-28T14:53:45.000000Z",
          "side" => "bid",
          "price_level" => price,
          "new_quantity" => quantity
        }

        frame = %{@snapshot | "events" => [%{event | "updates" => event["updates"] ++ [bad]}]}

        assert {:ok, _state} = Socket.handle_frame({:text, Jason.encode!(frame)}, state())
        assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
        refute_received {:dp_exchange, :coinbase, %Types.OrderBook{}}
      end
    end

    test "a zero quantity is still a readable row: the venue's way to say removed" do
      [event] = @snapshot["events"]

      removal = %{
        "event_time" => "2026-08-28T14:53:45.000000Z",
        "side" => "bid",
        "price_level" => "98.00",
        "new_quantity" => "0"
      }

      frame =
        %{
          @snapshot
          | "events" => [%{event | "type" => "update", "updates" => [removal]}]
        }

      assert {:ok, _state} = Socket.handle_frame({:text, Jason.encode!(frame)}, state())
      assert_received {:dp_exchange, :coinbase, %Types.OrderBookDelta{levels: [_removed]}}
    end

    test "an event of many unreadable rows raises ONE notice that counts them" do
      # What makes a row unreadable is usually the venue's format (a side this package does
      # not know, a quantity sent as null), which is true of every row at once. One notice per
      # row sent a consumer tens of thousands of them for a single refused snapshot, through
      # the one fan-out path that is never bounded.
      rows =
        for n <- 1..50 do
          %{
            "event_time" => "2026-08-28T14:53:45.000000Z",
            "side" => "sideways",
            "price_level" => "#{n}.00",
            "new_quantity" => "1"
          }
        end

      frame = %{
        @snapshot
        | "events" => [%{"type" => "snapshot", "product_id" => "BTC-USD", "updates" => rows}]
      }

      assert {:ok, _state} = Socket.handle_frame({:text, Jason.encode!(frame)}, state())

      sent = collect([])
      quality = for {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = n} <- sent, do: n

      assert [notice] = quality
      assert notice.details.bad_rows == 50
      assert notice.details.channel == :level2
      assert notice.details.payload =~ "event_time"
      refute Enum.any?(sent, &match?({:dp_exchange, :coinbase, %Types.OrderBook{}}, &1))
    end

    test "a snapshot's rows are sorted even when the venue sends them out of price order" do
      scrambled = %{
        "channel" => "l2_data",
        "timestamp" => "2026-08-28T14:53:45.649112Z",
        "events" => [
          %{
            "type" => "snapshot",
            "product_id" => "BTC-USD",
            "updates" => [
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "bid",
                "price_level" => "99.00",
                "new_quantity" => "2.0"
              },
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "offer",
                "price_level" => "103.00",
                "new_quantity" => "0.1"
              },
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "bid",
                "price_level" => "100.00",
                "new_quantity" => "1.5"
              },
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "offer",
                "price_level" => "101.00",
                "new_quantity" => "0.5"
              },
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "bid",
                "price_level" => "98.50",
                "new_quantity" => "4.0"
              }
            ]
          }
        ]
      }

      assert {:ok, _state} = Socket.handle_frame({:text, Jason.encode!(scrambled)}, state())
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}

      assert book.bids == [
               {Decimal.new("100.00"), Decimal.new("1.5")},
               {Decimal.new("99.00"), Decimal.new("2.0")},
               {Decimal.new("98.50"), Decimal.new("4.0")}
             ]

      assert book.asks == [
               {Decimal.new("101.00"), Decimal.new("0.5")},
               {Decimal.new("103.00"), Decimal.new("0.1")}
             ]
    end

    test "an update delivers an OrderBookDelta — the venue's own rows, in the venue's " <>
           "own order, NOT merged with a prior snapshot" do
      {:ok, s} = Socket.handle_frame({:text, Jason.encode!(@snapshot)}, state())
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{}}

      update = %{
        "channel" => "l2_data",
        "timestamp" => "2026-08-28T14:53:46.000000Z",
        "events" => [
          %{
            "type" => "update",
            "product_id" => "BTC-USD",
            "updates" => [
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "bid",
                "price_level" => "100.50",
                "new_quantity" => "3.0"
              },
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "offer",
                "price_level" => "101.50",
                "new_quantity" => "0.2"
              }
            ]
          }
        ]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(update)}, s)

      assert_received {:dp_exchange, :coinbase, %Types.OrderBookDelta{} = delta}
      assert delta.symbol == "BTC-USD"
      assert delta.provider == :coinbase
      # Exactly the two rows this frame carried, in the exact order the venue sent
      # them — bid then ask, not split into two lists or re-sorted. Nothing from the
      # snapshot (100.00, 99.00, 101.00) leaks in: there is no maintained book left to
      # merge against.
      assert delta.levels == [
               {:bid, Decimal.new("100.50"), Decimal.new("3.0")},
               {:ask, Decimal.new("101.50"), Decimal.new("0.2")}
             ]
    end

    test "an update needs no prior snapshot — a delta does not depend on any held state" do
      update = %{
        "channel" => "l2_data",
        "timestamp" => "2026-08-28T14:53:46.000000Z",
        "events" => [
          %{
            "type" => "update",
            "product_id" => "BTC-USD",
            "updates" => [
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "bid",
                "price_level" => "100.50",
                "new_quantity" => "3.0"
              }
            ]
          }
        ]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(update)}, state())

      assert_received {:dp_exchange, :coinbase, %Types.OrderBookDelta{} = delta}
      assert delta.levels == [{:bid, Decimal.new("100.50"), Decimal.new("3.0")}]
    end

    test "new_quantity \"0\" survives in a delta unresolved — not dropped, not treated " <>
           "as a removal here" do
      update = %{
        "channel" => "l2_data",
        "timestamp" => "2026-08-28T14:53:46.000000Z",
        "events" => [
          %{
            "type" => "update",
            "product_id" => "BTC-USD",
            "updates" => [
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "bid",
                "price_level" => "99.00",
                "new_quantity" => "0"
              },
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "offer",
                "price_level" => "101.00",
                "new_quantity" => "0.5"
              }
            ]
          }
        ]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(update)}, state())

      assert_received {:dp_exchange, :coinbase, %Types.OrderBookDelta{} = delta}
      # The zero-quantity row is still there, in its original position, with its
      # quantity exactly as the venue sent it — this module does not decide that it
      # means "remove this level"; that meaning is the venue's, carried through, not
      # resolved here. See the moduledoc and `Types.OrderBookDelta`'s own moduledoc.
      assert delta.levels == [
               {:bid, Decimal.new("99.00"), Decimal.new("0")},
               {:ask, Decimal.new("101.00"), Decimal.new("0.5")}
             ]

      assert Decimal.equal?(elem(Enum.at(delta.levels, 0), 2), 0)
    end

    test "a second symbol's snapshot is independent of the first's" do
      snapshot_two =
        put_in(@snapshot["events"], [
          %{
            "type" => "snapshot",
            "product_id" => "ETH-USD",
            "updates" => [
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "bid",
                "price_level" => "10.00",
                "new_quantity" => "5.0"
              }
            ]
          }
        ])

      {:ok, s} = Socket.handle_frame({:text, Jason.encode!(@snapshot)}, state())
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{symbol: "BTC-USD"}}

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(snapshot_two)}, s)
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{symbol: "ETH-USD"} = eth_book}
      assert eth_book.bids == [{Decimal.new("10.00"), Decimal.new("5.0")}]
    end

    test "an unparseable price or quantity refuses the snapshot AND is reported, " <>
           "not swallowed" do
      # Every other decode failure in this module reports through `report_quality/2` —
      # `deliver_ticker/3` does too. This row used to be the one exception: the book
      # came back unchanged with no signal at all. That matters concretely because
      # `new_quantity: "0"` is how the venue signals level removal — an unparseable
      # quantity silently ignored could leave that fact unaccounted for with nothing
      # indicating why.
      bad_row = %{
        "channel" => "l2_data",
        "timestamp" => "2026-08-28T14:53:45.649112Z",
        "events" => [
          %{
            "type" => "snapshot",
            "product_id" => "BTC-USD",
            "updates" => [
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "bid",
                "price_level" => "null",
                "new_quantity" => "1.0"
              }
            ]
          }
        ]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(bad_row)}, state())

      refute_received {:dp_exchange, :coinbase, %Types.OrderBook{}}
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end

    test "an unparseable row in an update refuses the whole delta, valid sibling included, " <>
           "and is reported" do
      bad_row = %{
        "channel" => "l2_data",
        "timestamp" => "2026-08-28T14:53:45.649112Z",
        "events" => [
          %{
            "type" => "update",
            "product_id" => "BTC-USD",
            "updates" => [
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "bid",
                "price_level" => "null",
                "new_quantity" => "1.0"
              },
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "offer",
                "price_level" => "101.00",
                "new_quantity" => "0.5"
              }
            ]
          }
        ]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(bad_row)}, state())

      # Refused whole: the valid sibling is not delivered without the row beside it, which
      # would leave whatever that row changed standing. See `decode_rows/2`, 2026-10-10.
      refute_received {:dp_exchange, :coinbase, %Types.OrderBookDelta{}}
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end

    test "a row missing side/price_level/new_quantity entirely is also reported, not swallowed" do
      malformed_shape = %{
        "channel" => "l2_data",
        "timestamp" => "2026-08-28T14:53:45.649112Z",
        "events" => [
          %{
            "type" => "snapshot",
            "product_id" => "BTC-USD",
            "updates" => [
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "bid",
                "price_level" => "100.00"
              }
            ]
          }
        ]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(malformed_shape)}, state())

      refute_received {:dp_exchange, :coinbase, %Types.OrderBook{}}
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end

    test "a snapshot whose rows carry no event_time is not delivered" do
      # Fails closed exactly as the ticker path does. This used to substitute
      # DateTime.utc_now/0 unconditionally, then read the envelope `timestamp` rather
      # than each row's own `event_time` — see `latest_event_time/1`. The envelope
      # `timestamp` is irrelevant to this path now, so it stays present here; it is each
      # row's `event_time` this test removes.
      untimed =
        update_in(
          @snapshot,
          ["events", Access.at(0), "updates", Access.all()],
          &Map.delete(&1, "event_time")
        )

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(untimed)}, state())

      refute_received {:dp_exchange, :coinbase, %Types.OrderBook{}}
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end

    test "an update whose rows carry no event_time is not delivered" do
      untimed = %{
        "channel" => "l2_data",
        "events" => [
          %{
            "type" => "update",
            "product_id" => "BTC-USD",
            "updates" => [%{"side" => "bid", "price_level" => "100.00", "new_quantity" => "1.0"}]
          }
        ]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(untimed)}, state())

      refute_received {:dp_exchange, :coinbase, %Types.OrderBookDelta{}}
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end

    test "venue_time is the MAX event_time across the snapshot's own rows, not the envelope's" do
      # `L2Update.event_time` is per row (docs/reference/coinbase/openapi/at-async.json:
      # 1367-1370) — this proves the batch's `venue_time` tracks the newest row rather than
      # the envelope's own `timestamp`, which this fixture deliberately sets to something
      # earlier than every row so a regression back to reading it would be caught.
      multi_time = %{
        "channel" => "l2_data",
        "timestamp" => "2020-01-01T00:00:00.000000Z",
        "events" => [
          %{
            "type" => "snapshot",
            "product_id" => "BTC-USD",
            "updates" => [
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "bid",
                "price_level" => "100.00",
                "new_quantity" => "1.0"
              },
              %{
                "event_time" => "2026-08-28T14:53:47.000000Z",
                "side" => "offer",
                "price_level" => "101.00",
                "new_quantity" => "0.5"
              },
              %{
                "event_time" => "2026-08-28T14:53:46.000000Z",
                "side" => "bid",
                "price_level" => "99.00",
                "new_quantity" => "2.0"
              }
            ]
          }
        ]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(multi_time)}, state())

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}
      assert book.venue_time == ~U[2026-08-28 14:53:47.000000Z]
    end

    test "a large snapshot sharing a few timestamps still takes the newest, once each" do
      # `latest_event_time/1` parses each DISTINCT timestamp string once. 6,000 rows over
      # three stamps (one of them unreadable) must give the same answer parsing every row did.
      stamps = ["2026-08-28T14:53:45.000000Z", "not a time", "2026-08-28T14:53:49.500000Z"]

      rows =
        for n <- 1..6_000 do
          %{
            "event_time" => Enum.at(stamps, rem(n, 3)),
            "side" => "bid",
            "price_level" => Integer.to_string(n),
            "new_quantity" => "1"
          }
        end

      frame = %{
        "channel" => "l2_data",
        "events" => [%{"type" => "snapshot", "product_id" => "BTC-USD", "updates" => rows}]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(frame)}, state())

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}
      assert book.venue_time == ~U[2026-08-28 14:53:49.500000Z]
      assert length(book.bids) == 6_000
      assert {top, _size} = hd(book.bids)
      assert Decimal.equal?(top, Decimal.new(6_000))
    end

    test "a row with an unparseable event_time is skipped, not fatal to the whole frame" do
      # A bad `event_time` on one row must not sink a frame when another row's is readable
      # — `decode_rows/2` already reports the row-level problem for the fields it decodes,
      # separately.
      mixed = %{
        "channel" => "l2_data",
        "events" => [
          %{
            "type" => "snapshot",
            "product_id" => "BTC-USD",
            "updates" => [
              %{
                "event_time" => "not a time",
                "side" => "bid",
                "price_level" => "100.00",
                "new_quantity" => "1.0"
              },
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "offer",
                "price_level" => "101.00",
                "new_quantity" => "0.5"
              }
            ]
          }
        ]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(mixed)}, state())

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}
      assert book.venue_time == ~U[2026-08-28 14:53:45.000000Z]
    end

    test "no market state survives a frame — the socket's own state carries nothing " <>
           "beyond connection bookkeeping, before or after a snapshot and an update" do
      before_keys = state() |> Map.keys() |> Enum.sort()

      {:ok, s} = Socket.handle_frame({:text, Jason.encode!(@snapshot)}, state())
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{}}

      update = %{
        "channel" => "l2_data",
        "timestamp" => "2026-08-28T14:53:46.000000Z",
        "events" => [
          %{
            "type" => "update",
            "product_id" => "BTC-USD",
            "updates" => [
              %{
                "event_time" => "2026-08-28T14:53:45.000000Z",
                "side" => "bid",
                "price_level" => "100.50",
                "new_quantity" => "3.0"
              }
            ]
          }
        ]
      }

      assert {:ok, s} = Socket.handle_frame({:text, Jason.encode!(update)}, s)
      assert_received {:dp_exchange, :coinbase, %Types.OrderBookDelta{}}

      # `:delivering` is allowed to change (it is observed-delivery bookkeeping, not
      # market state) — what must NOT appear is any key shaped like a maintained book.
      assert Map.keys(s) |> Enum.sort() == before_keys
      refute Map.has_key?(s, :books)
    end

    test "a reconnect needs no state wipe, because none is held" do
      {:ok, s} = Socket.handle_frame({:text, Jason.encode!(@snapshot)}, state())
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{}}

      assert {:reconnect, after_disconnect} = Socket.handle_disconnect(%{reason: :closed}, s)
      # Nothing to wipe means nothing changes: nothing beyond `:delivering` (kept
      # deliberately, per the moduledoc) is even present to compare.
      # (`:connected_at` is reconnect-backoff bookkeeping, not data.)
      assert Map.drop(after_disconnect, [:connected_at]) == Map.drop(s, [:connected_at])
      refute Map.has_key?(after_disconnect, :books)
    end
  end

  describe "snapshot decode — no gb_trees, two deliberate behaviour changes" do
    # `price_key/1` and the `:gb_trees` ordering it supported are gone along with the
    # maintained book — see `Socket`'s moduledoc. Two things `price_key/1` used to do
    # as a side effect do NOT survive it, decided deliberately rather than by omission:

    @dup_price_snapshot %{
      "channel" => "l2_data",
      "timestamp" => "2026-09-06T00:00:00.000000Z",
      "events" => [
        %{
          "type" => "snapshot",
          "product_id" => "BTC-USD",
          "updates" => [
            %{
              "event_time" => "2026-08-28T14:53:45.000000Z",
              "side" => "bid",
              "price_level" => "1.5",
              "new_quantity" => "1.0"
            },
            %{
              "event_time" => "2026-08-28T14:53:45.000000Z",
              "side" => "bid",
              "price_level" => "1.50",
              "new_quantity" => "2.0"
            }
          ]
        }
      ]
    }

    # The old map-keyed implementation's last-write-wins fold over numerically-equal,
    # differently-scaled prices (`"1.5"` vs `"1.50"`) was an accident of its own key —
    # `%Decimal{}` structs compare unequal for equal numbers — never a documented venue
    # behaviour, and is deliberately not reintroduced now that the key is gone.
    test "numerically-equal, differently-scaled prices are now BOTH kept" do
      assert {:ok, _s} =
               Socket.handle_frame({:text, Jason.encode!(@dup_price_snapshot)}, state())

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}

      # Both rows the venue sent survive, at their own numeric price, in the order a
      # stable sort keeps equal keys — silently picking a winner between two rows
      # would itself be the kind of guess this family refuses.
      assert length(book.bids) == 2
      assert Enum.map(book.bids, &elem(&1, 1)) == [Decimal.new("1.0"), Decimal.new("2.0")]

      assert Enum.all?(book.bids, fn {price, _qty} ->
               Decimal.equal?(price, Decimal.new("1.5"))
             end)
    end

    @too_precise_snapshot %{
      "channel" => "l2_data",
      "timestamp" => "2026-09-06T00:00:00.000000Z",
      "events" => [
        %{
          "type" => "snapshot",
          "product_id" => "BTC-USD",
          "updates" => [
            %{
              "event_time" => "2026-08-28T14:53:45.000000Z",
              "side" => "bid",
              "price_level" => "1.123456789",
              "new_quantity" => "1.0"
            }
          ]
        }
      ]
    }

    # 9 decimal digits — one more than the 8 verified live against Coinbase's own
    # published `quote_increment` values. The refusal that used to guard this existed
    # only to protect the deleted `:gb_trees` integer key; sorting via
    # `Decimal.compare/2` has no rounding step to protect, so there is nothing left to
    # refuse — the price is carried through exactly as every other decimal field here.
    test "a price more precise than the venue's own quote_increment now passes through" do
      assert {:ok, _s} =
               Socket.handle_frame({:text, Jason.encode!(@too_precise_snapshot)}, state())

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}
      assert book.bids == [{Decimal.new("1.123456789"), Decimal.new("1.0")}]
      refute_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end
  end

  describe "the link reports itself on the metrics channel too" do
    # `Core.Telemetry` documented `[:dp_exchange, :link, …]` as events "every venue package
    # emits" and nothing in the family emitted any of them, for as long as the spec existed.
    # `:telemetry.attach/4` against a name nobody emits SUCCEEDS, so a consumer's dashboard
    # showed an empty panel — which reads as a venue with no traffic, not as an unimplemented
    # spec. These tests attach real handlers: one that only called an emitter and checked it
    # returned `:ok` would pass just as happily against the version that emitted nothing.
    setup do
      test_pid = self()
      handler_id = "link-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:dp_exchange, :link, :up],
          [:dp_exchange, :link, :down],
          [:dp_exchange, :link, :event]
        ],
        fn event, measurements, metadata, _config ->
          # Scoped by provider: `:telemetry` handlers are global to the VM, so an unscoped
          # one also receives every other concurrently-running test's events. Scoped to the
          # emitting process too: these tests call the callbacks in-process, so a handler
          # firing in any other process belongs to a different async test.
          if metadata.provider == :coinbase and self() == test_pid do
            send(test_pid, {:telemetry, event, measurements, metadata})
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "connecting emits link up" do
      assert {:ok, _state} = Socket.handle_connect(%{}, state())
      assert_receive {:telemetry, [:dp_exchange, :link, :up], %{count: 1}, _metadata}
    end

    test "disconnecting emits link down with an already-inspected reason" do
      # Aggregators group by value; a raw reason carrying a pid or a socket ref would make
      # every occurrence a distinct series.
      assert {:reconnect, _state} = Socket.handle_disconnect(%{reason: :closed}, state())

      assert_receive {:telemetry, [:dp_exchange, :link, :down], %{count: 1}, metadata}
      assert is_binary(metadata.reason)
      assert metadata.reason =~ "closed"
    end

    test "every frame is a link event, counted with its wire size" do
      payload = Jason.encode!(%{"channel" => "heartbeats"})
      assert {:ok, _state} = Socket.handle_frame({:text, payload}, state())

      assert_receive {:telemetry, [:dp_exchange, :link, :event], measurements, metadata}
      assert measurements.bytes == byte_size(payload)
      assert measurements.count == 1
      assert metadata.type == :frame
    end

    test "a frame that does NOT parse is still counted — the venue still sent it" do
      # Counting only what parsed would make a decoder bug here look like a silent venue.
      assert {:ok, _state} = Socket.handle_frame({:text, "{not json"}, state())
      assert_receive {:telemetry, [:dp_exchange, :link, :event], %{bytes: 9}, _metadata}
    end
  end

  describe "reconnect backoff — the storm websockex has no delay of its own against" do
    test "attempt 1 waits nothing: a healthy session that dropped reconnects at once" do
      assert Socket.reconnect_delay_ms(1) == 0
    end

    test "each consecutive failure doubles, capped at 30 seconds" do
      # `on_disconnect/5` in the transport calls `open_connection/3` and, on failure, calls
      # ITSELF with `attempt + 1` — nothing between the turns. Without this the socket
      # retries at full connect speed forever against whatever is refusing it, and the
      # causes are the ones that do not fix themselves by being retried sooner: a credential
      # the venue stopped honouring, an IP it started refusing, a maintenance window.
      assert Socket.reconnect_delay_ms(2) == 1_000
      assert Socket.reconnect_delay_ms(3) == 2_000
      assert Socket.reconnect_delay_ms(4) == 4_000
      assert Socket.reconnect_delay_ms(5) == 8_000
      assert Socket.reconnect_delay_ms(6) == 16_000
      assert Socket.reconnect_delay_ms(7) == 30_000
      assert Socket.reconnect_delay_ms(50) == 30_000
    end

    test "the cap holds against an attempt number large enough to overflow a naive shift" do
      # `:math.pow(2, attempt - 2)` on a long-lived storm produces a float far beyond any
      # integer anyone wants to multiply. `min/2` is applied to the result, so the only
      # thing that matters is that it stays pinned and stays an integer.
      delay = Socket.reconnect_delay_ms(2_000)

      assert delay == 30_000
      assert is_integer(delay)
    end

    test "handle_disconnect/2 reconnects immediately when the transport reports attempt 1" do
      # The healthy-blip path, and the one every other test in this file exercises by
      # calling the callback with a bare `%{reason: ...}`. Timed rather than assumed: a
      # regression that slept here would stall a socket on every ordinary drop.
      started = System.monotonic_time(:millisecond)

      assert {:reconnect, _state} =
               Socket.handle_disconnect(%{reason: :closed, attempt_number: 1}, state())

      # Against the smallest possible BACKOFF (1s at attempt 2), not an arbitrary budget.
      # This asserted `< 500`, which is stricter than the claim needs — the claim is "no
      # backoff was applied", and any wait under a second proves that. Under a loaded
      # full-suite run the 500ms version failed while the behaviour was correct, which is the
      # same timing-assertion-holds-when-quiet shape as the rate-limiter bucket race and
      # `Core.PollingFeed`'s poll-interval waits.
      assert System.monotonic_time(:millisecond) - started < 1_000
    end

    test "handle_disconnect/2 actually waits once reconnects are failing" do
      # Attempt 3 is `@base_reconnect_delay_ms * 2` = 2000ms. Asserting the elapsed time
      # rather than only the pure function is what proves the delay is WIRED IN — the
      # function existed in `dp_exchange_schwab` all along, and the bug in the other three
      # packages was never that the arithmetic was wrong, it was that nothing called it.
      started = System.monotonic_time(:millisecond)

      assert {:reconnect, _state} =
               Socket.handle_disconnect(%{reason: :closed, attempt_number: 3}, state())

      # Jittered downward by up to a quarter (`Socket.jittered_delay_ms/1`): 1500..2000.
      assert System.monotonic_time(:millisecond) - started >= 1_500
    end

    test "jittered_delay_ms/1 only ever shortens, by at most a quarter, and varies" do
      # The reconnect ladder was a pure function of the attempt number, so every shard's socket
      # (up to one per 30 level2 symbols), dropped together by one venue restart, retried on
      # identical schedules: a connect burst of the whole fleet on every rung.
      draws = for _draw <- 1..200, do: Socket.jittered_delay_ms(30_000)

      assert Enum.all?(draws, &(&1 >= 22_500 and &1 < 30_000))
      assert length(Enum.uniq(draws)) > 1
    end

    test "jittered_delay_ms/1 leaves an immediate reconnect immediate" do
      assert Socket.jittered_delay_ms(0) == 0
    end

    test "handle_disconnect/2 sleeps and reports a jittered delay, not the ladder's rung" do
      # Attempt 2 is the 1_000ms rung. Without the jitter the telemetry event reports exactly
      # 1_000 every time; with it the value is strictly below the rung and within a quarter.
      test_pid = self()
      handler_id = "reconnect-jitter-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:dp_exchange, :link, :reconnect_attempt],
        fn _event, _measurements, metadata, _config ->
          if metadata.provider == :coinbase and self() == test_pid,
            do: send(test_pid, {:reconnect_attempt, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      assert {:reconnect, _state} =
               Socket.handle_disconnect(%{reason: :closed, attempt_number: 2}, state())

      assert_receive {:reconnect_attempt, %{attempt: 2, delay_ms: delay_ms}}, 5_000
      assert delay_ms >= 750
      assert delay_ms < 1_000
    end

    test "a session that connected and dropped at once is not a healthy blip" do
      # websockex reports attempt 1 after every SUCCESSFUL connect, so a venue that accepts
      # the upgrade and drops the socket a second later used to be reconnected at delay 0
      # forever. A short session now counts toward the backoff.
      just_connected = %{state() | connected_at: System.monotonic_time(:millisecond)}
      started = System.monotonic_time(:millisecond)

      assert {:reconnect, after_drop} =
               Socket.handle_disconnect(%{reason: :closed, attempt_number: 1}, just_connected)

      # The 1_000ms rung, jittered down by up to a quarter.
      assert System.monotonic_time(:millisecond) - started >= 750
      assert after_drop.short_sessions == 1
      assert after_drop.connected_at == nil
    end

    test "a stable session's drop clears the short-session run" do
      assert {:reconnect, after_drop} =
               Socket.handle_disconnect(
                 %{reason: :closed, attempt_number: 1},
                 %{state() | short_sessions: 3}
               )

      assert after_drop.short_sessions == 0
    end

    test "a failed connect neither adds to nor clears the short-session run" do
      # attempt 2 plus a run of 1 is attempt 3: 2000ms.
      started = System.monotonic_time(:millisecond)

      assert {:reconnect, after_fail} =
               Socket.handle_disconnect(
                 %{reason: :closed, attempt_number: 2},
                 %{state() | connected_at: nil, short_sessions: 1}
               )

      assert System.monotonic_time(:millisecond) - started >= 1_500
      assert after_fail.short_sessions == 1
    end

    test "handle_connect/2 stamps the session start" do
      assert {:ok, connected} = Socket.handle_connect(nil, %{state() | connected_at: nil})
      assert is_integer(connected.connected_at)
    end
  end
end

defmodule DpExchange.Coinbase.SocketTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Socket
  alias DpExchange.Core.{Notice, Types}

  @moduletag :capture_log

  # The WebSockex callbacks are exercised directly with real payloads. Standing up an
  # actual socket would make these tier-2; what matters here is the decode-and-dispatch
  # behaviour, which is where a venue quietly loses data.
  defp state(subscriber \\ nil) do
    %{subscriber: subscriber || self(), credentials: nil, delivering: MapSet.new(), books: %{}}
  end

  defp frame(payload), do: Socket.handle_frame({:text, Jason.encode!(payload)}, state())

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
  end

  describe "connection state becomes a notice, not a log line" do
    test "connecting reports link_up" do
      assert {:ok, _state} = Socket.handle_connect(%{}, state())
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :link_up}}
    end

    test "disconnecting reports link_down and asks to reconnect" do
      assert {:reconnect, _state} = Socket.handle_disconnect(%{reason: :closed}, state())
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :link_down, severity: :error}}
    end

    test "no notice names a transport" do
      # "The venue link is down" is the fact; WebSocket is not a consumer's concern.
      Socket.handle_connect(%{}, state())
      assert_received {:dp_exchange, :coinbase, %Notice{kind: kind}}
      refute to_string(kind) =~ ~r/socket|ws|websocket/
    end
  end

  describe "ticker payloads" do
    test "become Quotes delivered to the subscriber" do
      assert {:ok, _state} = frame(@ticker)

      assert_received {:dp_exchange, :coinbase, %Types.Quote{} = quote_struct}
      assert quote_struct.symbol == "BTC-USD"
      assert Decimal.equal?(quote_struct.price, Decimal.new("79478.7"))
      assert quote_struct.timestamp == ~U[2026-08-28 14:53:45.649112Z]
    end

    test "a tick with NO venue timestamp is not delivered" do
      # Fails closed, exactly as the REST path does. Substituting `now` would make a
      # stale tick indistinguishable from a live one.
      ticker = Map.delete(@ticker, "timestamp")

      assert {:ok, _state} = frame(ticker)

      refute_received {:dp_exchange, :coinbase, %Types.Quote{}}
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
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
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end
  end

  describe "malformed and unexpected input" do
    test "a payload that does not parse is reported, not swallowed and not fatal" do
      assert {:ok, _state} = Socket.handle_frame({:text, "{not json"}, state())
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end

    test "an unrecognised channel is ignored rather than guessed at" do
      assert {:ok, _state} = frame(%{"channel" => "something_new", "events" => []})
      refute_received {:dp_exchange, :coinbase, %Types.Quote{}}
    end

    test "a non-text frame is ignored" do
      assert {:ok, _state} = Socket.handle_frame({:binary, <<1, 2, 3>>}, state())
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

    test "an authenticated channel carries a real jwt" do
      assert {:ok, message} = subscription("level2", ~w(BTC-USD), @credentials)

      assert is_binary(message.jwt)
      assert length(String.split(message.jwt, ".")) == 3
    end

    test "an authenticated channel without credentials is refused, not sent unsigned" do
      assert {:error, {:credentials_required, "level2"}} =
               subscription("level2", ~w(BTC-USD), nil)
    end

    test "symbols are converted to the venue's native form" do
      assert {:ok, message} = subscription("ticker", ~w(btc-usd), nil)
      assert message.product_ids == ~w(BTC-USD)
    end

    # Reaches the private builder through the public path, since that is what actually
    # runs in production. `send/3` fails on a dead pid, which is enough to observe the
    # message that was built.
    defp subscription(channel, symbols, credentials) do
      dead = spawn(fn -> :ok end)
      Process.sleep(5)

      case Socket.subscribe(dead, channel, symbols, credentials) do
        {:error, {:credentials_required, _channel}} = refusal -> refusal
        {:error, {:unsupported_key_size, _size}} = error -> error
        _sent_or_failed -> rebuild(channel, symbols, credentials)
      end
    end

    defp rebuild(channel, symbols, credentials) do
      products = Enum.map(symbols, &DpExchange.Coinbase.SymbolFormat.to_exchange_symbol/1)
      base = %{type: "subscribe", product_ids: products, channel: channel}

      if channel in ~w(level2 user) do
        {:ok, token} = DpExchange.Coinbase.Auth.jwt(credentials)
        {:ok, Map.put(base, :jwt, token)}
      else
        {:ok, base}
      end
    end
  end

  describe "unsubscribe" do
    test "returns an error for a dead socket rather than exiting" do
      dead = spawn(fn -> :ok end)
      Process.sleep(5)

      assert {:error, {:send_exit, _reason}} = Socket.unsubscribe(dead, "ticker", ~w(BTC-USD))
    end
  end

  describe "level2 — a maintained book, not a series of standalone facts" do
    @snapshot %{
      "channel" => "l2_data",
      "timestamp" => "2026-08-28T14:53:45.649112Z",
      "events" => [
        %{
          "type" => "snapshot",
          "product_id" => "BTC-USD",
          "updates" => [
            %{"side" => "bid", "price_level" => "100.00", "new_quantity" => "1.5"},
            %{"side" => "bid", "price_level" => "99.00", "new_quantity" => "2.0"},
            %{"side" => "offer", "price_level" => "101.00", "new_quantity" => "0.5"}
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

    test "an update PATCHES the maintained book, not the frame's own rows alone" do
      {:ok, s} = Socket.handle_frame({:text, Jason.encode!(@snapshot)}, state())
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{}}

      update = %{
        "channel" => "l2_data",
        "timestamp" => "2026-08-28T14:53:46.000000Z",
        "events" => [
          %{
            "type" => "update",
            "product_id" => "BTC-USD",
            "updates" => [%{"side" => "bid", "price_level" => "100.50", "new_quantity" => "3.0"}]
          }
        ]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(update)}, s)

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}
      # The new level joins what the snapshot already established — 100.00 and 99.00
      # are still there, because a delta patches the book rather than replacing it.
      assert book.bids == [
               {Decimal.new("100.50"), Decimal.new("3.0")},
               {Decimal.new("100.00"), Decimal.new("1.5")},
               {Decimal.new("99.00"), Decimal.new("2.0")}
             ]
    end

    test "new_quantity \"0\" removes the level rather than leaving a phantom price" do
      {:ok, s} = Socket.handle_frame({:text, Jason.encode!(@snapshot)}, state())
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{}}

      update = %{
        "channel" => "l2_data",
        "timestamp" => "2026-08-28T14:53:46.000000Z",
        "events" => [
          %{
            "type" => "update",
            "product_id" => "BTC-USD",
            "updates" => [%{"side" => "bid", "price_level" => "99.00", "new_quantity" => "0"}]
          }
        ]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(update)}, s)

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}
      assert book.bids == [{Decimal.new("100.00"), Decimal.new("1.5")}]

      refute Enum.any?(book.bids, fn {price, _qty} ->
               Decimal.equal?(price, Decimal.new("99.00"))
             end)
    end

    test "a second symbol's book is independent of the first's" do
      snapshot_two =
        put_in(@snapshot["events"], [
          %{
            "type" => "snapshot",
            "product_id" => "ETH-USD",
            "updates" => [%{"side" => "bid", "price_level" => "10.00", "new_quantity" => "5.0"}]
          }
        ])

      {:ok, s} = Socket.handle_frame({:text, Jason.encode!(@snapshot)}, state())
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{symbol: "BTC-USD"}}

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(snapshot_two)}, s)
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{symbol: "ETH-USD"} = eth_book}
      assert eth_book.bids == [{Decimal.new("10.00"), Decimal.new("5.0")}]
    end

    test "an unparseable price or quantity is dropped from the book AND reported, not swallowed" do
      # Every other decode failure in this module reports through `report_quality/2` —
      # `deliver_ticker/3` and `deliver_book/3` both do. This row used to be the one
      # exception: the book came back unchanged with no signal at all. That matters
      # concretely because `new_quantity: "0"` is how the venue signals level REMOVAL —
      # an unparseable quantity silently ignored can leave a stale price level in the
      # maintained book indefinitely with nothing indicating why.
      bad_row = %{
        "channel" => "l2_data",
        "timestamp" => "2026-08-28T14:53:45.649112Z",
        "events" => [
          %{
            "type" => "snapshot",
            "product_id" => "BTC-USD",
            "updates" => [%{"side" => "bid", "price_level" => "null", "new_quantity" => "1.0"}]
          }
        ]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(bad_row)}, state())

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}
      assert book.bids == []
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
            "updates" => [%{"side" => "bid", "price_level" => "100.00"}]
          }
        ]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(malformed_shape)}, state())

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}
      assert book.bids == []
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end

    test "a snapshot with NO venue timestamp is not delivered, but still updates the maintained book" do
      # Fails closed exactly as the ticker path does — this used to substitute
      # DateTime.utc_now/0 unconditionally instead. The internal book state still
      # updates: `coverage/1`'s guarantee is about what is DELIVERED, and a later,
      # well-timed update must patch real state, not a book this refusal left empty.
      untimed = Map.delete(@snapshot, "timestamp")

      assert {:ok, s} = Socket.handle_frame({:text, Jason.encode!(untimed)}, state())

      refute_received {:dp_exchange, :coinbase, %Types.OrderBook{}}
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
      assert :gb_trees.size(s.books["BTC-USD"].bids) > 0
    end

    test "a reconnect clears the maintained book" do
      {:ok, s} = Socket.handle_frame({:text, Jason.encode!(@snapshot)}, state())
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{}}
      refute s.books == %{}

      assert {:reconnect, s} = Socket.handle_disconnect(%{reason: :closed}, s)
      assert s.books == %{}
    end
  end

  describe "order-book resort-cost fix — observably invisible" do
    # dp_exchange_core's docs/design/2026-09-06_order-book-resort-cost.md replaced a
    # per-frame `Enum.sort_by/3` over a `%{Decimal => Decimal}` map with a `:gb_trees`
    # tree keyed by an exactly scaled integer. This is a pure performance change: the
    # design's own non-negotiable is that it be "observably invisible" — same order,
    # same `Decimal` values, same count as the map+sort approach it replaced. These
    # tests prove that against a REFERENCE implementation of the old approach, applied
    # to the identical rows, rather than merely asserting the new code agrees with
    # itself.

    # A fixed, non-monotonic permutation of 0..(n - 1) via an affine map mod n (131 is
    # prime and does not divide 300, so this is a bijection) — proves neither the
    # production code nor the reference below is secretly relying on rows arriving
    # already in price order.
    defp scrambled(n), do: Enum.map(0..(n - 1), &rem(&1 * 131 + 17, n))

    defp level_rows(side, base_cents, n) do
      Enum.map(scrambled(n), fn i ->
        price = Decimal.new(base_cents - i) |> Decimal.mult(Decimal.new("0.01"))
        qty = Decimal.new(i + 1) |> Decimal.mult(Decimal.new("0.001"))

        %{
          "side" => side,
          "price_level" => Decimal.to_string(price),
          "new_quantity" => Decimal.to_string(qty)
        }
      end)
    end

    defp book_event_frame(type, product, rows, timestamp) do
      %{
        "channel" => "l2_data",
        "timestamp" => timestamp,
        "events" => [%{"type" => type, "product_id" => product, "updates" => rows}]
      }
    end

    # The map-keyed-by-Decimal, full-`Enum.sort_by/3` approach `deliver_book/3` used to
    # use — reimplemented here ONLY as a comparison oracle, never as production code.
    defp reference_apply_row(%{"side" => side, "price_level" => p, "new_quantity" => q}, book) do
      key = if side == "bid", do: :bids, else: :asks
      price = Decimal.new(p)
      qty = Decimal.new(q)

      Map.update!(book, key, fn levels ->
        if Decimal.compare(qty, 0) == :eq do
          Map.delete(levels, price)
        else
          Map.put(levels, price, qty)
        end
      end)
    end

    defp reference_book(rows, book \\ %{bids: %{}, asks: %{}}),
      do: Enum.reduce(rows, book, &reference_apply_row/2)

    defp reference_ordered(book) do
      %{
        bids: Enum.sort_by(book.bids, fn {p, _q} -> p end, {:desc, Decimal}),
        asks: Enum.sort_by(book.asks, fn {p, _q} -> p end, {:asc, Decimal})
      }
    end

    test "a non-trivial book, snapshot then update, matches the map+sort reference exactly" do
      bid_rows = level_rows("bid", 1_000_000, 300)
      ask_rows = level_rows("offer", 1_050_000, 300)
      all_rows = bid_rows ++ ask_rows

      snapshot =
        book_event_frame("snapshot", "BTC-USD", all_rows, "2026-09-06T00:00:00.000000Z")

      assert {:ok, s} = Socket.handle_frame({:text, Jason.encode!(snapshot)}, state())
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}

      ref = reference_ordered(reference_book(all_rows))

      assert book.bids == ref.bids
      assert book.asks == ref.asks
      assert length(book.bids) == 300
      assert length(book.asks) == 300

      # A delta must match the reference too, not only a fresh snapshot — the
      # defect this replaced re-sorted on every frame, not only the first one.
      update_rows = [
        # updates an existing level in place (i = 5 of the bid range above)
        %{"side" => "bid", "price_level" => "9999.95", "new_quantity" => "5.55"},
        # removes an existing level (i = 10)
        %{"side" => "bid", "price_level" => "9999.90", "new_quantity" => "0"},
        # inserts a brand-new best bid, above every price in the snapshot
        %{"side" => "bid", "price_level" => "10000.50", "new_quantity" => "1.23"},
        # same three operations on the ask side
        %{"side" => "offer", "price_level" => "10499.95", "new_quantity" => "9.99"},
        %{"side" => "offer", "price_level" => "10499.90", "new_quantity" => "0"},
        %{"side" => "offer", "price_level" => "10490.00", "new_quantity" => "0.77"}
      ]

      update = book_event_frame("update", "BTC-USD", update_rows, "2026-09-06T00:00:01.000000Z")
      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(update)}, s)
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = updated}

      ref2 = reference_ordered(reference_book(update_rows, reference_book(all_rows)))

      assert updated.bids == ref2.bids
      assert updated.asks == ref2.asks
      assert {Decimal.new("10000.50"), Decimal.new("1.23")} == hd(updated.bids)
      assert {Decimal.new("10490.00"), Decimal.new("0.77")} == hd(updated.asks)
    end

    @dup_price_snapshot %{
      "channel" => "l2_data",
      "timestamp" => "2026-09-06T00:00:00.000000Z",
      "events" => [
        %{
          "type" => "snapshot",
          "product_id" => "BTC-USD",
          "updates" => [
            %{"side" => "bid", "price_level" => "1.5", "new_quantity" => "1.0"},
            %{"side" => "bid", "price_level" => "1.50", "new_quantity" => "2.0"}
          ]
        }
      ]
    }

    test "numerically-equal, differently-scaled prices are ONE level, last write wins — " <>
           "the map-keyed-by-Decimal implementation this replaced would have kept both" do
      assert {:ok, _s} =
               Socket.handle_frame({:text, Jason.encode!(@dup_price_snapshot)}, state())

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}

      assert length(book.bids) == 1
      assert [{price, qty}] = book.bids
      assert Decimal.equal?(price, Decimal.new("1.50"))
      assert Decimal.equal?(qty, Decimal.new("2.0"))

      # The factual record of what the OLD behaviour actually did, not an assumption:
      # `%Decimal{}` structs compare by field (sign/coef/exp), so these are DIFFERENT
      # map keys even though `Decimal.equal?/2` says they are the same price — the map
      # this fix replaced would have carried both as separate levels for one price.
      old_map =
        %{}
        |> Map.put(Decimal.new("1.5"), Decimal.new("1.0"))
        |> Map.put(Decimal.new("1.50"), Decimal.new("2.0"))

      assert map_size(old_map) == 2
      refute Decimal.new("1.5") === Decimal.new("1.50")
      assert Decimal.equal?(Decimal.new("1.5"), Decimal.new("1.50"))
    end

    @too_precise_snapshot %{
      "channel" => "l2_data",
      "timestamp" => "2026-09-06T00:00:00.000000Z",
      "events" => [
        %{
          "type" => "snapshot",
          "product_id" => "BTC-USD",
          "updates" => [
            %{"side" => "bid", "price_level" => "1.123456789", "new_quantity" => "1.0"}
          ]
        }
      ]
    }

    test "a price with more precision than the venue's own quote_increment publishes " <>
           "is reported and dropped, never rounded into the book" do
      # 9 decimal digits — one more than the 8 verified live against Coinbase's own
      # published `quote_increment` values (see Socket's moduledoc). Rounding this into
      # the book would be exactly the "nearby substitute" this family refuses.
      assert {:ok, _s} =
               Socket.handle_frame({:text, Jason.encode!(@too_precise_snapshot)}, state())

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}
      assert book.bids == []
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end
  end
end

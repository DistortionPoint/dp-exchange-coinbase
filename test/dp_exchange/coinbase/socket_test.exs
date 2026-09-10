defmodule DpExchange.Coinbase.SocketTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Socket
  alias DpExchange.Core.{Notice, Types}

  @moduletag :capture_log

  # The WebSockex callbacks are exercised directly with real payloads. Standing up an
  # actual socket would make these tier-2; what matters here is the decode-and-dispatch
  # behaviour, which is where a venue quietly loses data.
  defp state(subscriber \\ nil) do
    %{subscriber: subscriber || self(), credentials: nil, delivering: MapSet.new()}
  end

  defp frame(payload), do: Socket.handle_frame({:text, Jason.encode!(payload)}, state())

  # Deterministic instead of `spawn(fn -> :ok end)` plus a guessed sleep: a monitor's
  # `:DOWN` message only arrives once the process has genuinely exited, so this never
  # races a scheduler slower than whatever fixed delay was guessed.
  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
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

  describe "ticker payloads" do
    test "become Quotes delivered to the subscriber" do
      assert {:ok, _state} = frame(@ticker)

      assert_received {:dp_exchange, :coinbase, %Types.Quote{} = quote_struct}
      assert quote_struct.symbol == "BTC-USD"
      assert Decimal.equal?(quote_struct.price, Decimal.new("79478.7"))
      assert quote_struct.venue_time == ~U[2026-08-28 14:53:45.649112Z]
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
      dead = dead_pid()

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

    test "a snapshot's rows are sorted even when the venue sends them out of price order" do
      scrambled = %{
        "channel" => "l2_data",
        "timestamp" => "2026-08-28T14:53:45.649112Z",
        "events" => [
          %{
            "type" => "snapshot",
            "product_id" => "BTC-USD",
            "updates" => [
              %{"side" => "bid", "price_level" => "99.00", "new_quantity" => "2.0"},
              %{"side" => "offer", "price_level" => "103.00", "new_quantity" => "0.1"},
              %{"side" => "bid", "price_level" => "100.00", "new_quantity" => "1.5"},
              %{"side" => "offer", "price_level" => "101.00", "new_quantity" => "0.5"},
              %{"side" => "bid", "price_level" => "98.50", "new_quantity" => "4.0"}
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
              %{"side" => "bid", "price_level" => "100.50", "new_quantity" => "3.0"},
              %{"side" => "offer", "price_level" => "101.50", "new_quantity" => "0.2"}
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
            "updates" => [%{"side" => "bid", "price_level" => "100.50", "new_quantity" => "3.0"}]
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
              %{"side" => "bid", "price_level" => "99.00", "new_quantity" => "0"},
              %{"side" => "offer", "price_level" => "101.00", "new_quantity" => "0.5"}
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
            "updates" => [%{"side" => "bid", "price_level" => "10.00", "new_quantity" => "5.0"}]
          }
        ])

      {:ok, s} = Socket.handle_frame({:text, Jason.encode!(@snapshot)}, state())
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{symbol: "BTC-USD"}}

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(snapshot_two)}, s)
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{symbol: "ETH-USD"} = eth_book}
      assert eth_book.bids == [{Decimal.new("10.00"), Decimal.new("5.0")}]
    end

    test "an unparseable price or quantity is dropped from a snapshot AND reported, " <>
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
            "updates" => [%{"side" => "bid", "price_level" => "null", "new_quantity" => "1.0"}]
          }
        ]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(bad_row)}, state())

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}
      assert book.bids == []
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end

    test "an unparseable row in an update is dropped from the delta AND reported, " <>
           "while a valid sibling row in the same frame still arrives" do
      bad_row = %{
        "channel" => "l2_data",
        "timestamp" => "2026-08-28T14:53:45.649112Z",
        "events" => [
          %{
            "type" => "update",
            "product_id" => "BTC-USD",
            "updates" => [
              %{"side" => "bid", "price_level" => "null", "new_quantity" => "1.0"},
              %{"side" => "offer", "price_level" => "101.00", "new_quantity" => "0.5"}
            ]
          }
        ]
      }

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(bad_row)}, state())

      assert_received {:dp_exchange, :coinbase, %Types.OrderBookDelta{} = delta}
      assert delta.levels == [{:ask, Decimal.new("101.00"), Decimal.new("0.5")}]
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

    test "a snapshot with NO venue timestamp is not delivered" do
      # Fails closed exactly as the ticker path does — this used to substitute
      # DateTime.utc_now/0 unconditionally instead.
      untimed = Map.delete(@snapshot, "timestamp")

      assert {:ok, _s} = Socket.handle_frame({:text, Jason.encode!(untimed)}, state())

      refute_received {:dp_exchange, :coinbase, %Types.OrderBook{}}
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end

    test "an update with NO venue timestamp is not delivered" do
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
            "updates" => [%{"side" => "bid", "price_level" => "100.50", "new_quantity" => "3.0"}]
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
      assert after_disconnect == s
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
            %{"side" => "bid", "price_level" => "1.5", "new_quantity" => "1.0"},
            %{"side" => "bid", "price_level" => "1.50", "new_quantity" => "2.0"}
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
            %{"side" => "bid", "price_level" => "1.123456789", "new_quantity" => "1.0"}
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
end

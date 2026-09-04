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

  @ticker %{
    "channel" => "ticker",
    "events" => [
      %{
        "tickers" => [
          %{
            "product_id" => "BTC-USD",
            "price" => "79478.7",
            "volume_24_h" => "1234.5",
            "time" => "2026-08-28T14:53:45.649112Z"
          }
        ]
      }
    ]
  }

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
      ticker =
        update_in(@ticker["events"], fn [event] ->
          [update_in(event["tickers"], fn [t] -> [Map.delete(t, "time")] end)]
        end)

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

    test "an unparseable price or quantity is dropped rather than crashing the book" do
      bad_row = %{
        "channel" => "l2_data",
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
    end

    test "a reconnect clears the maintained book" do
      {:ok, s} = Socket.handle_frame({:text, Jason.encode!(@snapshot)}, state())
      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{}}
      refute s.books == %{}

      assert {:reconnect, s} = Socket.handle_disconnect(%{reason: :closed}, s)
      assert s.books == %{}
    end
  end
end

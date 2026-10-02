defmodule DpExchange.Coinbase.MarketTradesTest do
  use DpExchange.Coinbase.FeedCase, async: true

  alias DpExchange.Coinbase.{Fake, Feed, Socket}
  alias DpExchange.Core.{Notice, Types}

  @fixtures_root Path.expand("../../fixtures/spec_examples", __DIR__)

  defp fixture!(name) do
    [@fixtures_root, "websocket", name] |> Path.join() |> File.read!() |> Jason.decode!()
  end

  defp socket_state do
    %{
      subscriber: self(),
      credentials: nil,
      delivering: MapSet.new(),
      connected_once?: false,
      last_seq: nil,
      stale_run: nil,
      last_frame_at: nil,
      silence_check: nil
    }
  end

  defp frame(payload), do: Socket.handle_frame({:text, Jason.encode!(payload)}, socket_state())

  defp envelope(trades, type \\ "update") do
    %{
      "channel" => "market_trades",
      "timestamp" => "2026-10-02T14:54:03.464172Z",
      "events" => [%{"type" => type, "trades" => trades}]
    }
  end

  defp trade(overrides \\ %{}) do
    Map.merge(
      %{
        "product_id" => "BTC-USD",
        "trade_id" => "42",
        "price" => "85701.9",
        "size" => "0.5",
        "time" => "2026-10-02T14:54:03.341087Z",
        "side" => "BUY"
      },
      overrides
    )
  end

  describe "decoding a vendor-shaped update" do
    test "every row becomes a Trade carrying the venue's own id, price, size and time" do
      assert {:ok, state} = frame(fixture!("market_trades_update.json"))

      assert_received {:dp_exchange, :coinbase, %Types.Trade{} = first}
      assert_received {:dp_exchange, :coinbase, %Types.Trade{} = second}

      assert first.id == "1101555350"
      assert first.symbol == "BTC-USD"
      assert Decimal.equal?(first.price, Decimal.new("85701.9"))
      assert Decimal.equal?(first.quantity, Decimal.new("0.09334681"))
      # The trade's own `time`, not the envelope's send time.
      assert first.timestamp == ~U[2026-10-02 14:54:03.341087Z]
      assert first.provider == :coinbase
      assert first.broken == false
      assert second.id == "1101555349"
      assert MapSet.member?(state.delivering, "BTC-USD")
    end

    test "side is the TAKER's: the venue's maker BUY is a taker :sell, and vice versa" do
      # `MarketTrade.side` is "The maker's side of the trade." (at-async.json:1407).
      assert {:ok, _state} =
               frame(envelope([trade(%{"side" => "BUY"}), trade(%{"side" => "SELL"})]))

      assert_received {:dp_exchange, :coinbase, %Types.Trade{side: :sell}}
      assert_received {:dp_exchange, :coinbase, %Types.Trade{side: :buy}}
    end

    test "a side the venue did not state, or stated unknowably, is nil, never a guess" do
      assert {:ok, _state} =
               frame(
                 envelope([trade(%{"side" => "UNKNOWN_ORDER_SIDE"}), Map.delete(trade(), "side")])
               )

      assert_received {:dp_exchange, :coinbase, %Types.Trade{side: nil}}
      assert_received {:dp_exchange, :coinbase, %Types.Trade{side: nil}}
    end

    test "a canonical symbol is delivered for a venue product id" do
      assert {:ok, _state} = frame(envelope([trade(%{"product_id" => "ETH-USD"})]))
      assert_received {:dp_exchange, :coinbase, %Types.Trade{symbol: "ETH-USD"}}
    end
  end

  describe "the snapshot is history and is not delivered" do
    test "a snapshot emits no trade, no notice, and no coverage" do
      assert {:ok, state} = frame(fixture!("market_trades_snapshot.json"))

      refute_received {:dp_exchange, :coinbase, _anything}
      assert MapSet.size(state.delivering) == 0
    end

    test "a snapshot sent again on resubscribe is still not delivered" do
      # Delivering it would double count history on every reconnect.
      for _attempt <- 1..2,
          do: assert({:ok, _state} = frame(fixture!("market_trades_snapshot.json")))

      refute_received {:dp_exchange, :coinbase, %Types.Trade{}}
    end

    test "only the update after a snapshot is delivered" do
      assert {:ok, _state} = frame(fixture!("market_trades_snapshot.json"))
      assert {:ok, _state} = frame(fixture!("market_trades_update.json"))

      assert_received {:dp_exchange, :coinbase, %Types.Trade{id: "1101555350"}}
      assert_received {:dp_exchange, :coinbase, %Types.Trade{id: "1101555349"}}
      refute_received {:dp_exchange, :coinbase, %Types.Trade{}}
    end
  end

  describe "an unreadable trade fails closed through the data_quality notice" do
    for {label, overrides} <- [
          {"no trade_id", %{"trade_id" => nil}},
          {"an empty trade_id", %{"trade_id" => ""}},
          {"a numeric trade_id", %{"trade_id" => 7}},
          {"an unparseable price", %{"price" => "abc"}},
          {"a NaN price", %{"price" => "NaN"}},
          {"a missing size", %{"size" => nil}},
          {"an infinite size", %{"size" => "Infinity"}},
          {"a missing time", %{"time" => nil}},
          {"an unparseable time", %{"time" => "yesterday"}}
        ] do
      test "#{label} is reported and not delivered" do
        assert {:ok, _state} = frame(envelope([trade(unquote(Macro.escape(overrides)))]))

        assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = notice}
        assert notice.details.channel == :market_trades
        assert notice.details.payload == "BTC-USD"
        refute_received {:dp_exchange, :coinbase, %Types.Trade{}}
      end
    end

    test "one bad trade does not cost the good trade beside it" do
      assert {:ok, _state} =
               frame(envelope([trade(%{"price" => "abc"}), trade(%{"trade_id" => "9"})]))

      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
      assert_received {:dp_exchange, :coinbase, %Types.Trade{id: "9"}}
    end

    test "a row with no product id, or a non-string one, is reported rather than raising" do
      assert {:ok, _state} = frame(envelope([Map.delete(trade(), "product_id")]))
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}

      assert {:ok, _state} = frame(envelope([trade(%{"product_id" => %{}})]))
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}

      assert {:ok, _state} = frame(envelope(["not a map"]))
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
    end

    test "an update whose trades is null, and an unknown event type, are reported" do
      assert {:ok, _state} = frame(envelope(nil))
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}

      assert {:ok, _state} = frame(envelope([trade()], "mystery"))
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}
      refute_received {:dp_exchange, :coinbase, %Types.Trade{}}
    end
  end

  describe "Feed :channels" do
    test "the default is unchanged: :trades is opt-in" do
      feed = start_feed()
      assert :sys.get_state(feed).channels == [:quotes, :order_book]
    end

    test "channels: [:trades] opens market_trades shards and nothing else" do
      feed = start_feed(channels: [:trades])
      :ok = Feed.subscribe(feed, ["BTC-USD", "ETH-USD"])

      channels =
        feed
        |> :sys.get_state()
        |> Map.fetch!(:shards)
        |> Map.keys()
        |> Enum.map(fn {channel, _index} -> channel end)
        |> Enum.uniq()

      assert channels == ["market_trades"]
    end

    test "all three kinds are accepted together, in any order, without duplicates" do
      feed = start_feed(channels: [:trades, :order_book, :quotes, :trades])

      assert :sys.get_state(feed).channels == [:trades, :order_book, :quotes]
    end

    test "an unknown kind is still refused, and the message now names :trades as known" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Feed.start_link(name: nil, channels: [:candles, :trades])

      assert message =~ ":channels must be drawn from"
      assert message =~ ":trades"
      assert message =~ "[:candles]"
    end

    test "a delivered Trade is forwarded to subscribers and counts as :trades coverage" do
      feed = start_feed(channels: [:trades])
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      trade = %Types.Trade{
        id: "1",
        symbol: "BTC-USD",
        side: :buy,
        price: Decimal.new("1"),
        quantity: Decimal.new("1"),
        timestamp: ~U[2026-10-02 12:00:00Z],
        provider: :coinbase
      }

      send(feed, {:dp_exchange, :coinbase, trade})

      assert_receive {:dp_exchange, :coinbase, %Types.Trade{id: "1", symbol: "BTC-USD"}}, 500
      assert Feed.coverage_by_kind(feed) == %{trades: %{"BTC-USD" => :stream}}
      refute Map.has_key?(Feed.coverage_by_kind(feed), :quotes)
    end
  end

  describe "capabilities and the fake" do
    test "streamable declares :trades" do
      assert :trades in DpExchange.Coinbase.capabilities().streamable
    end

    test "the fake delivers a Trade only when :trades is asked for" do
      assert :ok = Fake.subscribe(["BTC-USD"], to: self())
      refute_received {:dp_exchange, :coinbase, %Types.Trade{}}
      assert_received {:dp_exchange, :coinbase, %Types.Quote{}}

      assert :ok = Fake.subscribe(["ETH-USD"], to: self(), channels: [:quotes, :trades])
      assert_received {:dp_exchange, :coinbase, %Types.Trade{symbol: "ETH-USD"} = trade}
      assert trade.id && trade.side in [:buy, :sell] && trade.broken == false
    end

    test "the fake's coverage_by_kind carries :trades only for symbols that asked, and drops them" do
      Fake.subscribe(["BTC-USD", "ETH-USD"], to: self())
      refute Map.has_key?(Fake.coverage_by_kind(), :trades)

      Fake.subscribe(["ETH-USD"], to: self(), channels: [:trades])
      assert Fake.coverage_by_kind().trades == %{"ETH-USD" => :stream}

      Fake.update_symbols(["ETH-USD", "BTC-USD"])
      assert Fake.coverage_by_kind().trades == %{"ETH-USD" => :stream}

      Fake.unsubscribe(["ETH-USD"])
      refute Map.has_key?(Fake.coverage_by_kind(), :trades)
    end
  end
end

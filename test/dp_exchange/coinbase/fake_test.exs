defmodule DpExchange.Coinbase.FakeTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Fake
  alias DpExchange.Core.{Notice, Types}

  # The fake is a real implementation, so it gets real tests. The two rules it exists to
  # honour — less capable but never differently capable, and never rewriting a caller's
  # value — are what these assert.

  describe "it answers from memory with the same shapes as the real venue" do
    test "get_price returns a Quote with a fixed timestamp" do
      # Fixed, not `utc_now/0`. A fake that stamps the current clock cannot be used to
      # test anything about freshness, and stamping now is the substitution this family
      # refuses.
      assert {:ok, %Types.Quote{} = first} = Fake.get_price("BTC-USD")
      assert {:ok, second} = Fake.get_price("BTC-USD")

      assert first.timestamp == second.timestamp
      assert first.provider == :coinbase
    end

    test "get_symbols returns its catalogue" do
      assert {:ok, symbols} = Fake.get_symbols()
      assert "BTC-USD" in symbols
    end

    test "its declaration IS the real venue's" do
      # A fake declaring different capabilities from the venue it stands in for is a fake
      # a consumer cannot use to test capability branching.
      assert Fake.capabilities() == DpExchange.Coinbase.capabilities()
      assert Fake.provider_name() == DpExchange.Coinbase.provider_name()
      assert Fake.runtime_id() == DpExchange.Coinbase.runtime_id()
      assert Fake.asset_classes() == DpExchange.Coinbase.asset_classes()
    end
  end

  describe "it models refusals, not only successes" do
    test "an unlisted symbol is REFUSED, not errored and not empty" do
      # The original fake this pattern guards against answered `{:ok, []}` to things it
      # could not do, so callers got plausible wrong answers rather than failures.
      assert {:refused, :not_listed} = Fake.get_price("NOPE-USD")
      assert {:refused, :not_listed} = Fake.get_historical_prices("NOPE-USD", "1h")
    end

    test "a width Coinbase does not serve is refused, including 12h" do
      assert {:error, {:unsupported_timeframe, "12h"}} =
               Fake.get_historical_prices("BTC-USD", "12h")
    end

    test "an over-wide range is refused with the same shape the real venue gives" do
      finish = ~U[2026-08-28 12:00:00Z]
      start = DateTime.add(finish, -60 * 400, :second)

      assert {:error, {:range_too_wide, requested: 400, max: 350}} =
               Fake.get_historical_prices("BTC-USD", "1m", start: start, end: finish)
    end

    test "it refuses exactly what the real venue refuses" do
      real =
        DpExchange.Core.Capabilities.endpoints_at(
          DpExchange.Coinbase.capabilities(),
          :unsupported
        )

      for {name, arity} <- real, name not in [:child_spec, :start_link] do
        args = List.duplicate([], arity)
        assert {:error, :not_supported} = apply(Fake, name, args)
      end
    end
  end

  describe "candles" do
    test "the fake returns bars, not quotes" do
      # It returned `get_price/2`'s Quote here, which agreed with the real package's own
      # `price: close` defect — a suite reproducing the bug it exists to catch.
      assert {:ok, [bar]} = Fake.get_historical_prices("BTC-USD", "1h")

      assert %Types.Candle{} = bar
      assert bar.timeframe == "1h"
      assert Types.Candle.coherent?(bar)
    end

    test "the bar has a real range, so high is not close" do
      assert {:ok, [bar]} = Fake.get_historical_prices("BTC-USD", "1h")

      refute Decimal.equal?(bar.high, bar.close)
      refute Decimal.equal?(bar.low, bar.open)
    end
  end

  describe "the two endpoints the family had no facade for" do
    test "close_position returns an order with no side" do
      # nil in the fake because it is nil in production: the venue never states the side of
      # a closing order, and a fake that filled in :sell would teach a consumer to rely on
      # a field that is not there.
      assert {:ok, %Types.Order{} = order} = Fake.close_position(%{}, "BTC-USD")

      assert order.side == nil
      assert order.status == :pending
      assert order.provider == :coinbase
    end

    test "preview_replace prices price and size changes" do
      assert {:ok, preview} = Fake.preview_replace(%{}, "abc", %{price: Decimal.new("41000")})
      assert Decimal.equal?(preview.order_total, Decimal.new("20000.00"))
      assert preview.order_id == "abc"
    end

    test "preview_replace refuses an edit the venue refuses" do
      assert {:error, {:unsupported_order_edit, [:side]}} =
               Fake.preview_replace(%{}, "abc", %{side: :sell})
    end
  end

  describe "streaming" do
    test "subscribe pushes immediately, as a first tick would" do
      assert :ok = Fake.subscribe(~w(BTC-USD), to: self())
      assert_received {:dp_exchange, :coinbase, %Types.Quote{symbol: "BTC-USD"}}
    end

    test "coverage reports only what it pushed for" do
      assert :ok = Fake.subscribe(~w(BTC-USD NOPE-USD), to: self())
      coverage = Fake.coverage()

      assert coverage["BTC-USD"] == :stream
      refute Map.has_key?(coverage, "NOPE-USD")
    end

    test "unsubscribe drops coverage" do
      Fake.subscribe(~w(BTC-USD ETH-USD), to: self())
      assert :ok = Fake.unsubscribe(~w(BTC-USD))

      refute Map.has_key?(Fake.coverage(), "BTC-USD")
      assert Fake.coverage()["ETH-USD"] == :stream
    end

    test "update_symbols replaces the set" do
      Fake.subscribe(~w(BTC-USD), to: self())
      assert :ok = Fake.update_symbols(~w(ETH-USD))

      assert Map.keys(Fake.coverage()) == ~w(ETH-USD)
    end

    test "state is per process, so two tests cannot interfere" do
      Fake.subscribe(~w(BTC-USD), to: self())

      task = Task.async(fn -> Fake.coverage() end)
      assert Task.await(task) == %{}
    end

    test "notices arrive on their own channel" do
      assert :ok = Fake.subscribe_notices(to: self())
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :link_up}}
    end
  end

  describe "lifecycle" do
    test "it does not start itself" do
      assert :ignore = Fake.start_link([])
      assert %{id: Fake} = Fake.child_spec([])
    end
  end

  describe "market_status" do
    test "matches the real venue" do
      assert Fake.market_status([]) == DpExchange.Coinbase.market_status([])
    end
  end
end

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

  describe "balances and accounts" do
    test "the fake's held amount is not zero, so available is not the total" do
      # A consumer reading available_balance as the total fails here rather than in
      # production, which is the only reason a fake has numbers at all.
      assert {:ok, balances} = Fake.get_balances(%{}, [])
      btc = Enum.find(balances, &(&1.currency == "BTC"))

      refute Decimal.equal?(btc.hold, Decimal.new("0"))
      refute Decimal.equal?(btc.available_balance, btc.balance)
      assert Decimal.equal?(btc.balance, Decimal.add(btc.available_balance, btc.hold))
    end

    test "a balance is stamped when it was asked for" do
      before = DateTime.utc_now()
      assert {:ok, [balance | _rest]} = Fake.get_balances(%{}, [])

      assert DateTime.compare(balance.timestamp, before) != :lt
    end

    test "accounts carry what a balance cannot — the uuid and the platform" do
      assert {:ok, [account]} = Fake.get_accounts(%{}, [])

      assert account["uuid"]
      assert account["platform"] == "ACCOUNT_PLATFORM_CONSUMER"
    end

    test "a uuid the fake does not hold is refused, not an empty account" do
      # `{:ok, []}` would read as "this account has nothing in it".
      assert {:refused, :not_found} = Fake.get_accounts(%{}, uuid: "nope")
    end

    test "the fake's own uuid reads back" do
      assert {:ok, [account]} =
               Fake.get_accounts(%{}, uuid: "8bfc20d7-f7c6-4422-bf07-8243ca4169fe")

      assert account["currency"] == "BTC"
    end
  end

  describe "fills" do
    test "an adjusted fill is excluded by default" do
      # A REVERSAL is not a trade that happened, and Fill has no field to say so. A fake
      # that returned both under one type would teach a consumer to sum them.
      assert {:ok, [only]} = Fake.get_trade_history(%{}, [])
      assert only.trade_id == "t-1"
    end

    test "asking for them widens the answer" do
      assert {:ok, both} = Fake.get_trade_history(%{}, trade_types: ["FILL", "REVERSAL"])
      assert length(both) == 2
    end

    test "the fee currency is nil, as it is in production" do
      assert {:ok, [fill]} = Fake.get_trade_history(%{}, [])
      assert fill.fee_currency == nil
      assert fill.liquidity == :taker
    end
  end

  describe "the tape" do
    test "more than one print comes back" do
      # The whole point of the tape is that get_price/2 keeps only the newest and this does
      # not. A fake with one print would never show the difference.
      assert {:ok, trades} = Fake.get_trades("BTC-USD")

      assert length(trades) == 2
      assert Enum.map(trades, & &1.side) == [:buy, :sell]
    end

    test "an unlisted symbol is refused, not an empty tape" do
      assert {:refused, :not_listed} = Fake.get_trades("NOPE-USD")
    end

    test "no print is marked broken — this venue publishes no bust flag" do
      assert {:ok, trades} = Fake.get_trades("BTC-USD")
      refute Enum.any?(trades, & &1.broken)
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

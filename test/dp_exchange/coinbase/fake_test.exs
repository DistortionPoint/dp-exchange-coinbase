defmodule DpExchange.Coinbase.FakeTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Fake
  alias DpExchange.Core.{Notice, Types}

  @credentials %{api_key: "k", api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="}
  @missing {:error, {:missing_credentials, :coinbase}}

  # A complete limit order: type and time-in-force are required, never defaulted.
  defp limit_order(overrides \\ %{}) do
    Map.merge(
      %{
        symbol: "BTC-USD",
        side: :buy,
        order_type: :limit,
        time_in_force: :gtc,
        quantity: Decimal.new("0.5"),
        price: Decimal.new("40000")
      },
      overrides
    )
  end

  # The fake is a real implementation, so it gets real tests. The two rules it exists to
  # honour — less capable but never differently capable, and never rewriting a caller's
  # value — are what these assert.

  describe "private endpoints refuse what the real path refuses: no usable credential" do
    # The real path answers `{:error, {:missing_credentials, :coinbase}}` for `nil`, `%{}` and
    # a map that cannot sign, before any request. The fake used to inspect none of them.
    test "every credentialed call, with the credential positional" do
      one = Decimal.new("1")
      request = limit_order(%{quantity: one, price: one})
      edit = %{price: Decimal.new("1"), quantity: Decimal.new("1")}

      for bad <- [nil, %{}, %{api_key: "k"}, %{api_key: 1, api_secret: "s"}] do
        assert @missing == Fake.get_balances(bad, [])
        assert @missing == Fake.get_accounts(bad, [])
        assert @missing == Fake.get_fees(bad, [])
        assert @missing == Fake.get_trade_history(bad, [])
        assert @missing == Fake.get_trade_volume(bad)
        assert @missing == Fake.place_order(bad, request)
        assert @missing == Fake.preview_order(bad, request)
        assert @missing == Fake.cancel_order(bad, "fake-order-1")
        assert @missing == Fake.get_order(bad, "fake-order-1")
        assert @missing == Fake.get_orders(bad)
        assert @missing == Fake.replace_order(bad, "fake-order-1", edit)
        assert @missing == Fake.preview_replace(bad, "fake-order-1", edit)
        assert @missing == Fake.close_position(bad, "BTC-USD")
        assert @missing == Fake.list_payment_methods(bad)
        assert @missing == Fake.get_payment_method(bad, "pm-1")
      end
    end

    test "every credentialed call, with the credential in opts (the facade's default is %{})" do
      for opts <- [[], [credentials: nil], [credentials: %{}]] do
        assert @missing == Fake.get_positions(opts)
        assert @missing == Fake.list_portfolios(opts)
        assert @missing == Fake.get_roles(opts)
        assert @missing == Fake.create_account([name: "n"] ++ opts)
        assert @missing == Fake.rename_account("pf-1", "n", opts)
        assert @missing == Fake.quote_conversion("USD", "USDC", Decimal.new("1"), opts)

        assert @missing ==
                 Fake.transfer_internal("USD", Decimal.new("1"), [from: "a", to: "b"], opts)
      end
    end

    test "a conversion commit or read checks its accounts, then the credential, then the id" do
      assert {:error, :from_and_to_required} = Fake.commit_conversion("t-1", [])
      assert @missing == Fake.commit_conversion("t-1", from: "USD", to: "USDC")
      assert @missing == Fake.get_conversion("t-1", from: "USD", to: "USDC")

      opts = [from: "USD", to: "USDC", credentials: @credentials]
      assert {:refused, :not_found} = Fake.commit_conversion("t-1", opts)
    end

    test "the argument checks come first where the real function runs them first" do
      assert {:error, :name_required} = Fake.create_account([])

      assert {:error, :missing_portfolio} =
               Fake.transfer_internal("USD", Decimal.new("1"), [], [])
    end

    test "get_top_of_book reads %{} as no credential, as the real path does" do
      assert @missing == Fake.get_top_of_book("BTC-USD", credentials: %{})
    end

    test "test_connection: none is reachability, a key that cannot sign is refused" do
      assert {:ok, %{"reachable" => true}} = Fake.test_connection(%{}, [])
      assert @missing == Fake.test_connection(%{api_key: "k"}, [])
      assert {:ok, %{"can_view" => true}} = Fake.test_connection(@credentials, [])
    end

    test "public market data needs none" do
      assert {:ok, _quote} = Fake.get_price("BTC-USD")
      assert {:ok, _book} = Fake.get_order_book("BTC-USD")
    end
  end

  describe "orders are validated by the real checks, in the real order" do
    test "an order with no symbol or side is an error, not a KeyError" do
      assert {:error, {:invalid_symbol, nil}} =
               Fake.place_order(@credentials, Map.delete(limit_order(), :symbol))

      assert {:error, {:missing_field, :side}} =
               Fake.place_order(@credentials, Map.delete(limit_order(), :side))
    end

    test "a limit order with no price is refused, as is a market order with no size" do
      limit = Map.delete(limit_order(), :price)
      assert {:error, {:missing_field, :price}} = Fake.place_order(@credentials, limit)
      assert {:error, {:missing_field, :price}} = Fake.preview_order(@credentials, limit)

      market = %{symbol: "BTC-USD", side: :buy, order_type: :market, time_in_force: :ioc}
      assert {:error, {:missing_field, :quantity}} = Fake.place_order(@credentials, market)
    end

    test "a request the real path refuses is refused before the credential is looked at" do
      assert {:error, {:invalid_symbol, nil}} = Fake.place_order(%{}, %{side: :buy})
    end

    test "type and time-in-force are required, and a field the type does not use is refused" do
      assert {:error, {:missing_field, :order_type}} =
               Fake.place_order(@credentials, Map.delete(limit_order(), :order_type))

      assert {:error, {:missing_field, :time_in_force}} =
               Fake.place_order(@credentials, Map.delete(limit_order(), :time_in_force))

      assert {:error, {:unexpected_field, :stop_price}} =
               Fake.place_order(@credentials, limit_order(%{stop_price: "1"}))

      market = %{symbol: "BTC-USD", side: :buy, order_type: :market, time_in_force: :ioc}

      assert {:error, {:unexpected_field, :price}} =
               Fake.place_order(@credentials, Map.merge(market, %{quantity: "1", price: "1"}))
    end

    test "a quote-sized limit order and post_only: false behave as on the real path" do
      quote_sized = limit_order(%{quote_size: "10"}) |> Map.delete(:quantity)

      assert {:ok, order} = Fake.place_order(@credentials, quote_sized)
      assert order.quantity == nil

      assert {:error, {:unexpected_field, :quote_size}} =
               Fake.place_order(@credentials, limit_order(%{quote_size: "10"}))

      fok = %{time_in_force: :fok}

      assert {:ok, _order} =
               Fake.place_order(@credentials, limit_order(Map.put(fok, :post_only, false)))

      assert {:error, {:unexpected_field, :post_only}} =
               Fake.place_order(@credentials, limit_order(Map.put(fok, :post_only, true)))
    end

    test "the placed order carries Decimals, as the real return does" do
      request = limit_order(%{quantity: "0.5", price: "40000.5"})

      assert {:ok, order} = Fake.place_order(@credentials, request)
      assert Decimal.equal?(order.quantity, Decimal.new("0.5"))
      assert Decimal.equal?(order.price, Decimal.new("40000.5"))
    end

    test "a float amount is refused, as the real path refuses it" do
      assert {:error, {:invalid_price, 40_000.5}} =
               Fake.place_order(@credentials, limit_order(%{price: 40_000.5}))
    end

    test "the side comes back as the atom the real path returns, not the caller's string" do
      assert {:ok, %Types.Order{side: :buy}} =
               Fake.place_order(@credentials, limit_order(%{side: "BUY"}))

      assert {:error, {:invalid_side, "hold"}} =
               Fake.place_order(@credentials, limit_order(%{side: "hold"}))
    end

    test "client_order_id is checked as the real path checks it" do
      for bad <- ["", "  ", 5] do
        assert {:error, {:invalid_client_order_id, ^bad}} =
                 Fake.place_order(@credentials, limit_order(%{client_order_id: bad}))
      end
    end

    test "re-sending a client_order_id returns the original order, as the idempotent venue does" do
      request = limit_order(%{client_order_id: "mine-1"})

      assert {:ok, first} = Fake.place_order(@credentials, request)
      assert {:ok, again} = Fake.place_order(@credentials, request)
      assert again == first

      assert {:ok, [_canned, _placed] = orders} = Fake.get_orders(@credentials)
      assert Enum.count(orders, &(&1.id == first.id)) == 1

      assert {:ok, other} = Fake.place_order(@credentials, limit_order(%{client_order_id: "b"}))
      refute other.id == first.id

      assert {:ok, one} = Fake.place_order(@credentials, limit_order())
      assert {:ok, two} = Fake.place_order(@credentials, limit_order())
      refute one.id == two.id
    end

    test "a replace read-back shows both edited fields" do
      edit = %{price: Decimal.new("41000"), quantity: Decimal.new("0.75")}

      assert {:ok, order} = Fake.replace_order(@credentials, "fake-order-1", edit)
      assert Decimal.equal?(order.price, Decimal.new("41000"))
      assert Decimal.equal?(order.quantity, Decimal.new("0.75"))
    end

    test "an unknown order is the venue's 404, {:refused, :not_found}" do
      assert {:refused, :not_found} = Fake.get_order(@credentials, "no-such-order")
    end

    test ":status and :symbol narrow the list instead of being ignored" do
      assert {:ok, [_open]} = Fake.get_orders(@credentials, status: :open, symbol: "BTC-USD")
      assert {:ok, []} = Fake.get_orders(@credentials, status: :filled)
      assert {:ok, []} = Fake.get_orders(@credentials, symbol: "ETH-USD")
    end

    test "fills narrow on :symbol, :order_id and the time window" do
      assert {:ok, [_fill]} = Fake.get_trade_history(@credentials, symbol: "BTC-USD")
      assert {:ok, []} = Fake.get_trade_history(@credentials, symbol: "ETH-USD")
      assert {:ok, []} = Fake.get_trade_history(@credentials, order_id: "other")
      assert {:ok, []} = Fake.get_trade_history(@credentials, start: ~U[2026-09-01 00:00:00Z])
      assert {:ok, []} = Fake.get_trade_history(@credentials, end: ~U[2026-08-01 00:00:00Z])
    end

    test "the window is [start, end): a fill stamped exactly at :start is kept, at :end not" do
      at = ~U[2026-08-28 12:00:00Z]

      assert {:ok, [%Types.Fill{timestamp: ^at}]} =
               Fake.get_trade_history(@credentials, start: at)

      assert {:ok, []} = Fake.get_trade_history(@credentials, end: at)
      assert {:ok, []} = Fake.get_trade_history(@credentials, start: ~U[2026-08-28 12:00:01Z])

      assert {:ok, [%Types.Fill{timestamp: ^at}]} =
               Fake.get_trade_history(@credentials,
                 start: at,
                 end: ~U[2026-08-28 12:00:01Z]
               )
    end
  end

  describe "candles are validated before the symbol, as the real path validates them" do
    test "an unsupported timeframe wins over an unlisted symbol" do
      assert {:error, {:unsupported_timeframe, "12h"}} =
               Fake.get_historical_prices("NOPE-USD", "12h")
    end

    test "an over-wide window wins over an unlisted symbol" do
      finish = ~U[2026-08-28 12:00:00Z]
      start = DateTime.add(finish, -60 * 400, :second)

      assert {:error, {:range_too_wide, requested: 400, max: 350}} =
               Fake.get_historical_prices("NOPE-USD", "1m", start: start, end: finish)
    end

    test "a window with only :end set defaults its start as the real path does" do
      # `:end` is exclusive: the bar opening at 12:00 is inside an end of 13:00 and outside
      # an end of 12:00 (MD2).
      assert {:ok, [_bar]} =
               Fake.get_historical_prices("BTC-USD", "1h", end: ~U[2026-08-28 13:00:00Z])

      assert {:ok, []} =
               Fake.get_historical_prices("BTC-USD", "1h", end: ~U[2026-08-28 12:00:00Z])
    end

    test "start is inclusive, and limit / include_partial are validated as on the real path" do
      finish = ~U[2026-08-29 00:00:00Z]
      on_open = [start: ~U[2026-08-28 12:00:00Z], end: finish]
      after_open = [start: ~U[2026-08-28 12:00:01Z], end: finish]

      assert {:ok, [_bar]} = Fake.get_historical_prices("BTC-USD", "1h", on_open)
      assert {:ok, []} = Fake.get_historical_prices("BTC-USD", "1h", after_open)

      assert {:error, {:invalid_option, :limit, 351}} =
               Fake.get_historical_prices("BTC-USD", "1h", [], limit: 351)

      assert {:error, {:invalid_option, :include_partial, "yes"}} =
               Fake.get_historical_prices("BTC-USD", "1h", [], include_partial: "yes")

      assert {:ok, [_bar]} = Fake.get_historical_prices("BTC-USD", "1h", [], limit: 5)
    end
  end

  describe "the book" do
    test "a depth of zero is refused, as the real path refuses it, not an empty book" do
      assert {:error, {:invalid_option, :depth, 0}} = Fake.get_order_book("BTC-USD", depth: 0)
    end

    test "depth bounds the levels per side" do
      assert {:ok, %Types.OrderBook{bids: [_one], asks: [_other]}} =
               Fake.get_order_book("BTC-USD", depth: 1)
    end
  end

  describe "streamed quotes" do
    test "carry a rolling 24h volume and no venue_time, as the real stream's do (MD7)" do
      assert :ok = Fake.subscribe(~w(BTC-USD), to: self())

      assert_receive {:dp_exchange, :coinbase, %Types.Quote{} = streamed}, 5_000
      assert streamed.volume_window == :rolling_24h
      assert streamed.venue_time == nil

      # REST keeps the trade's own time: `get_price/2` is a different statement.
      assert {:ok, %Types.Quote{venue_time: %DateTime{}}} = Fake.get_price("BTC-USD")
    end
  end

  describe "it answers from memory with the same shapes as the real venue" do
    test "get_price returns a Quote with a fixed timestamp" do
      # Fixed, not `utc_now/0`. A fake that stamps the current clock cannot be used to
      # test anything about freshness, and stamping now is the substitution this family
      # refuses.
      assert {:ok, %Types.Quote{} = first} = Fake.get_price("BTC-USD")
      assert {:ok, second} = Fake.get_price("BTC-USD")

      assert first.venue_time == second.venue_time
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

  describe "get_top_of_book/2 — the one endpoint with no public form" do
    test "without credentials it refuses, exactly as the real client does" do
      # DpExchange.Coinbase.Rest.get_top_of_book/2 refuses before sending anything when
      # given no credentials, because /best_bid_ask has no /market/... counterpart on this
      # venue. A fake that answered :ok regardless would be MORE capable than the real
      # venue on the one call where that gap matters — a consumer's test would pass
      # without credentials and the identical call would refuse in production.
      assert {:error, {:missing_credentials, :coinbase}} = Fake.get_top_of_book("BTC-USD")
      assert {:error, {:missing_credentials, :coinbase}} = Fake.get_top_of_book("BTC-USD", [])
    end

    test "with credentials it answers, with the bid split from the price" do
      opts = [
        credentials: %{api_key: "k", api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="}
      ]

      assert {:ok, %Types.TopOfBook{} = top} = Fake.get_top_of_book("BTC-USD", opts)
      refute Decimal.equal?(top.bid, top.ask)
    end

    test "an unlisted symbol is refused as :not_listed, credentials notwithstanding" do
      opts = [
        credentials: %{api_key: "k", api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="}
      ]

      assert {:refused, :not_listed} = Fake.get_top_of_book("NOPE-USD", opts)
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
      assert {:ok, %Types.Order{} = order} = Fake.close_position(@credentials, "BTC-USD")

      assert order.side == nil
      assert order.status == :pending
      assert order.provider == :coinbase
    end

    test "preview_replace prices price and size changes" do
      assert {:ok, preview} =
               Fake.preview_replace(@credentials, "abc", %{
                 price: Decimal.new("41000"),
                 quantity: Decimal.new("0.5")
               })

      assert Decimal.equal?(preview.order_total, Decimal.new("20000.00"))
      assert preview.order_id == "abc"
    end

    test "preview_replace refuses an edit the venue refuses" do
      assert {:error, {:unsupported_order_edit, [:side]}} =
               Fake.preview_replace(@credentials, "abc", %{side: :sell})
    end

    test "preview_replace refuses price alone — EditOrderRequest requires size too" do
      assert {:error, :missing_required_edit_field} =
               Fake.preview_replace(@credentials, "abc", %{price: Decimal.new("41000")})
    end
  end

  describe "balances and accounts" do
    test "the fake's held amount is not zero, so available is not the total" do
      # A consumer reading available_balance as the total fails here rather than in
      # production, which is the only reason a fake has numbers at all.
      assert {:ok, balances} = Fake.get_balances(@credentials, [])
      btc = Enum.find(balances, &(&1.currency == "BTC"))

      refute Decimal.equal?(btc.hold, Decimal.new("0"))
      refute Decimal.equal?(btc.available_balance, btc.balance)
      assert Decimal.equal?(btc.balance, Decimal.add(btc.available_balance, btc.hold))
    end

    test "a balance is stamped when it was asked for" do
      before = DateTime.utc_now()
      assert {:ok, [balance | _rest]} = Fake.get_balances(@credentials, [])

      assert DateTime.compare(balance.timestamp, before) != :lt
    end

    test "accounts carry what a balance cannot — the uuid and the platform" do
      assert {:ok, [account]} = Fake.get_accounts(@credentials, [])

      assert account["uuid"]
      assert account["platform"] == "ACCOUNT_PLATFORM_CONSUMER"
    end

    test "a uuid the fake does not hold is refused, not an empty account" do
      # `{:ok, []}` would read as "this account has nothing in it".
      assert {:refused, :not_found} = Fake.get_accounts(@credentials, uuid: "nope")
    end

    test "the fake's own uuid reads back" do
      assert {:ok, [account]} =
               Fake.get_accounts(@credentials, uuid: "8bfc20d7-f7c6-4422-bf07-8243ca4169fe")

      assert account["currency"] == "BTC"
    end
  end

  describe "fills" do
    test "an adjusted fill is excluded by default" do
      # A REVERSAL is not a trade that happened, and Fill has no field to say so. A fake
      # that returned both under one type would teach a consumer to sum them.
      assert {:ok, [only]} = Fake.get_trade_history(@credentials, [])
      assert only.trade_id == "t-1"
    end

    test "asking for them widens the answer" do
      assert {:ok, both} = Fake.get_trade_history(@credentials, trade_types: ["FILL", "REVERSAL"])
      assert length(both) == 2
    end

    test "the fee currency is nil, as it is in production" do
      assert {:ok, [fill]} = Fake.get_trade_history(@credentials, [])
      assert fill.fee_currency == nil
      assert fill.liquidity == :taker
    end
  end

  describe "the tape" do
    test "more than one print comes back" do
      # The whole point of the tape is that get_price/2 keeps only the newest and this does
      # not. A fake with one print would never show the difference.
      assert {:ok, trades} = Fake.get_trades("BTC-USD", limit: 10)

      assert length(trades) == 2
      # Oldest first, as `Rest.get_trades/2` returns them.
      assert Enum.map(trades, & &1.side) == [:sell, :buy]
      assert trades == Enum.sort_by(trades, & &1.timestamp, DateTime)
    end

    test "limit bounds the tape to the newest prints, and must be a positive integer" do
      assert {:ok, [%{id: "t-1"}]} = Fake.get_trades("BTC-USD", limit: 1)

      for bad <- [0, -1, "5", 1.5] do
        assert {:error, {:invalid_limit, ^bad}} = Fake.get_trades("BTC-USD", limit: bad)
      end
    end

    test "a lower-case symbol is found, as Rest upper-cases it; a slash spelling is not" do
      assert {:ok, [_one, _two]} = Fake.get_trades("btc-usd", limit: 10)
      assert {:refused, :not_listed} = Fake.get_trades("BTC/USD", limit: 10)
    end

    test "an order book depth that is not a count is an error, not a crash" do
      assert {:error, {:invalid_option, :depth, "x"}} =
               Fake.get_order_book("BTC-USD", depth: "x")
    end

    test "an unlisted symbol is refused, not an empty tape" do
      assert {:refused, :not_listed} = Fake.get_trades("NOPE-USD", limit: 10)
    end

    test "no print is marked broken — this venue publishes no bust flag" do
      assert {:ok, trades} = Fake.get_trades("BTC-USD", limit: 10)
      refute Enum.any?(trades, & &1.broken)
    end

    test "limit is required, matching the real venue's endpoint" do
      # `limit` is `required: true` on the ticker endpoint
      # (docs/reference/coinbase/openapi/at-spec.yaml:523-528). A fake that answered
      # without one would let a consumer's suite go green on a call the real venue refuses.
      assert {:error, :missing_limit} = Fake.get_trades("BTC-USD")
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

    test "wanted/1 holds every symbol subscribed, sorted, and follows unsubscribe" do
      assert Fake.wanted() == []

      Fake.subscribe(~w(ETH-USD BTC-USD), to: self())
      assert Fake.wanted() == ~w(BTC-USD ETH-USD)
      assert Enum.all?(Map.keys(Fake.coverage()), &(&1 in Fake.wanted()))

      assert :ok = Fake.unsubscribe(~w(BTC-USD))
      assert Fake.wanted() == ~w(ETH-USD)
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

    test "coverage_by_kind reports every subscribed symbol under :quotes only — the fake " <>
           "never synthesises an order book" do
      assert :ok = Fake.subscribe(~w(BTC-USD ETH-USD), to: self())

      by_kind = Fake.coverage_by_kind()

      assert by_kind == %{quotes: %{"BTC-USD" => :stream, "ETH-USD" => :stream}}
      refute Map.has_key?(by_kind, :order_book)
    end

    test "coverage_by_kind's symbol union matches coverage/1 exactly" do
      assert :ok = Fake.subscribe(~w(BTC-USD ETH-USD), to: self())

      coverage_symbols = Fake.coverage() |> Map.keys() |> MapSet.new()

      union =
        Fake.coverage_by_kind()
        |> Map.values()
        |> Enum.flat_map(&Map.keys/1)
        |> MapSet.new()

      assert union == coverage_symbols
    end

    test "every kind coverage_by_kind reports is declared streamable" do
      Fake.subscribe(~w(BTC-USD), to: self())

      declared = MapSet.new(Fake.capabilities().streamable)
      reported = Fake.coverage_by_kind() |> Map.keys() |> MapSet.new()

      assert MapSet.subset?(reported, declared)
    end

    test "state is per process, so two tests cannot interfere" do
      Fake.subscribe(~w(BTC-USD), to: self())

      task = Task.async(fn -> Fake.coverage() end)
      assert Task.await(task) == %{}
    end

    test "registering for notices sends none, as the real feed does" do
      assert :ok = Fake.subscribe_notices(to: self())
      refute_received {:dp_exchange, :coinbase, %Notice{}}
    end

    test "a :to atom naming no process is skipped on delivery, not an ArgumentError" do
      nobody = :coinbase_fake_nobody_registered_here

      assert :ok = Fake.subscribe(~w(BTC-USD), to: nobody)
      assert :ok = Fake.subscribe(~w(BTC-USD), to: nobody, channels: [:trades, :order_book])
    end

    test "a :to atom naming a registered process is delivered to" do
      name = :coinbase_fake_registered_consumer
      Process.register(self(), name)
      on_exit(fn -> if Process.whereis(name), do: Process.unregister(name) end)

      assert :ok = Fake.subscribe(~w(BTC-USD), to: name)
      assert_received {:dp_exchange, :coinbase, %Types.Quote{symbol: "BTC-USD"}}
    end

    test "coverage_by_kind omits every empty kind, :quotes included" do
      assert Fake.coverage_by_kind() == %{}

      Fake.subscribe(~w(BTC-USD), to: self(), channels: [:trades])
      Fake.unsubscribe(~w(BTC-USD))
      assert Fake.coverage_by_kind() == %{}
    end

    test "get_price refuses a credential the real path refuses, and takes none publicly" do
      assert {:ok, _quote} = Fake.get_price("BTC-USD")
      assert {:ok, _quote} = Fake.get_price("BTC-USD", credentials: %{})
      assert {:ok, _quote} = Fake.get_price("BTC-USD", credentials: @credentials)

      assert @missing == Fake.get_price("BTC-USD", credentials: %{api_key: "k"})
      assert @missing == Fake.get_price("BTC-USD", credentials: %{api_key: " ", api_secret: "s"})

      assert {:error, {:invalid_credentials, :coinbase}} ==
               Fake.get_price("BTC-USD", credentials: %{api_key: "k ", api_secret: "s"})
    end

    test "blank, whitespace-only and padded credentials are refused alike by every call" do
      secret = @credentials.api_secret
      blank_secret = %{api_key: "k", api_secret: ""}

      assert @missing == Fake.get_top_of_book("BTC-USD", credentials: blank_secret)
      blank_key = %{@credentials | api_key: ""}
      assert @missing == Fake.get_top_of_book("BTC-USD", credentials: blank_key)
      assert @missing == Fake.get_balances(%{api_key: "k", api_secret: "  \n"}, [])

      padded = %{api_key: "k", api_secret: secret <> "\n"}
      assert {:error, {:invalid_credentials, :coinbase}} == Fake.get_balances(padded, [])
    end

    test "symbols that are blank after trim, or an improper list, are refused" do
      for bad <- [[" "], ["BTC-USD", "\t"], ["BTC-USD" | "tail"]] do
        assert {:error, {:invalid_symbols, _bad}} = Fake.subscribe(bad)
        assert {:error, {:invalid_symbols, _bad}} = Fake.unsubscribe(bad)
        assert {:error, {:invalid_symbols, _bad}} = Fake.update_symbols(bad)
      end

      assert {:error, {:invalid_symbols, nil}} = Fake.unsubscribe(nil)
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

  describe "a lower-case subscription" do
    # The real facade upper-cases symbols on the way in. The fake has to give the same
    # answer, or a consumer's tier-1 tests certify silence where the venue delivers.
    test "is delivered under the canonical symbol, as the real package does" do
      opts = [to: self(), account_id: "acct", account_number: "acct", account_hash: "acct"]

      assert :ok = DpExchange.Coinbase.Fake.subscribe(["btc-usd"], opts)
      assert_receive {:dp_exchange, _venue, %{symbol: "BTC-USD"}}, 5_000
      assert Map.has_key?(DpExchange.Coinbase.Fake.coverage(opts), "BTC-USD")
    end
  end

  describe "issued portfolio and preview ids are the venue's UUIDs and round-trip" do
    @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

    test "list_portfolios -> get_roles -> rename_account agree on UUID portfolio ids" do
      opts = [credentials: @credentials]

      assert {:ok, [default, retired]} = Fake.list_portfolios(opts)
      assert default.id =~ @uuid
      assert retired.id =~ @uuid
      refute default.id == retired.id

      # The portfolio the key is attached to is one the listing names.
      assert {:ok, %{"portfolio_uuid" => attached}} = Fake.get_roles(opts)
      assert attached == default.id

      assert {:ok, renamed} = Fake.rename_account(default.id, "Renamed", opts)
      assert renamed.id == default.id
    end

    test "create_account issues a UUID portfolio id that rename_account accepts" do
      assert {:ok, created} = Fake.create_account(credentials: @credentials, name: "Fresh")
      assert created.id =~ @uuid

      assert {:ok, renamed} =
               Fake.rename_account(created.id, "Again", credentials: @credentials)

      assert renamed.id == created.id
    end

    test "preview_order issues a UUID preview id, as the venue's preview_id" do
      request = limit_order()

      assert {:ok, %{preview_id: preview_id}} = Fake.preview_order(@credentials, request)
      assert preview_id =~ @uuid
    end
  end

  describe "an order the fake placed is the order it reads back and cancels" do
    defp eth_sell do
      limit_order(%{
        symbol: "ETH-USD",
        side: :sell,
        quantity: Decimal.new("2"),
        price: Decimal.new("3000")
      })
    end

    test "place -> get -> list -> cancel -> get -> cancel again" do
      assert {:ok, placed} = Fake.place_order(@credentials, eth_sell())
      refute placed.id == "fake-order-1"

      assert {:ok, read} = Fake.get_order(@credentials, placed.id)
      assert read.id == placed.id
      assert read.symbol == "ETH-USD"
      assert read.side == :sell
      assert Decimal.equal?(read.quantity, Decimal.new("2"))
      assert Decimal.equal?(read.price, Decimal.new("3000"))
      assert read.status == :open

      assert {:ok, [listed]} = Fake.get_orders(@credentials, symbol: "ETH-USD")
      assert listed.id == placed.id

      assert {:ok, :cancelled} = Fake.cancel_order(@credentials, placed.id)
      assert {:ok, %{status: :cancelled}} = Fake.get_order(@credentials, placed.id)

      assert {:refused, {:cancel_rejected, _reason}} =
               Fake.cancel_order(@credentials, placed.id)
    end

    test "two placements are two orders" do
      assert {:ok, first} = Fake.place_order(@credentials, eth_sell())
      assert {:ok, second} = Fake.place_order(@credentials, eth_sell())
      refute first.id == second.id

      assert {:ok, :cancelled} = Fake.cancel_order(@credentials, first.id)
      assert {:ok, %{status: :open}} = Fake.get_order(@credentials, second.id)
    end

    test "an id the fake never issued answers as the venue's 404 and unknown cancel" do
      assert {:refused, :not_found} = Fake.get_order(@credentials, "never-issued")

      assert {:refused, {:cancel_rejected, "UNKNOWN_CANCEL_ORDER"}} =
               Fake.cancel_order(@credentials, "never-issued")
    end

    test "cancelling the canned order is reflected in the next read" do
      assert {:ok, :cancelled} = Fake.cancel_order(@credentials, "fake-order-1")
      assert {:ok, %{status: :cancelled}} = Fake.get_order(@credentials, "fake-order-1")
    end

    test "replace_order on a placed id keeps the id, reads back edited, and cancels" do
      assert {:ok, placed} = Fake.place_order(@credentials, eth_sell())
      edit = %{price: Decimal.new("3100"), quantity: Decimal.new("3")}

      assert {:ok, edited} = Fake.replace_order(@credentials, placed.id, edit)
      assert edited.id == placed.id
      assert edited.symbol == "ETH-USD"

      assert {:ok, read} = Fake.get_order(@credentials, edited.id)
      assert Decimal.equal?(read.price, Decimal.new("3100"))
      assert Decimal.equal?(read.quantity, Decimal.new("3"))
      assert read.status == :open

      assert {:ok, :cancelled} = Fake.cancel_order(@credentials, edited.id)
    end

    test "replace_order on the canned order reads back edited" do
      edit = %{price: Decimal.new("41000"), quantity: Decimal.new("0.75")}

      assert {:ok, _edited} = Fake.replace_order(@credentials, "fake-order-1", edit)
      assert {:ok, read} = Fake.get_order(@credentials, "fake-order-1")
      assert Decimal.equal?(read.price, Decimal.new("41000"))
    end

    test "replace_order on an id the fake never issued is the venue's 404" do
      edit = %{price: Decimal.new("1"), quantity: Decimal.new("1")}

      assert {:refused, :not_found} = Fake.replace_order(@credentials, "never-issued", edit)
      assert {:refused, :not_found} = Fake.get_order(@credentials, "never-issued")
    end

    test "close_position mints an id that reads back and cancels, one per call" do
      assert {:ok, first} = Fake.close_position(@credentials, "BTC-USD")
      assert {:ok, second} = Fake.close_position(@credentials, "BTC-USD")
      refute first.id == second.id

      assert {:ok, read} = Fake.get_order(@credentials, first.id)
      assert read.id == first.id
      assert read.symbol == "BTC-USD"
      assert read.side == nil
      assert read.status == :open

      assert {:ok, :cancelled} = Fake.cancel_order(@credentials, first.id)
      assert {:ok, %{status: :open}} = Fake.get_order(@credentials, second.id)
    end
  end

  describe "streaming parity, found 2026-10-10" do
    test ":order_book pushes a snapshot and is covered under that kind" do
      :ok = Fake.subscribe(["BTC-USD"], to: self(), channels: [:quotes, :order_book])

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{symbol: "BTC-USD"}}
      assert %{order_book: %{"BTC-USD" => :stream}} = Fake.coverage_by_kind()

      :ok = Fake.unsubscribe(["BTC-USD"])
      refute Map.has_key?(Fake.coverage_by_kind(), :order_book)
    end

    test "channels: [:trades] alone pushes no quote and covers no quotes, as the real feed" do
      :ok = Fake.subscribe(["BTC-USD"], to: self(), channels: [:trades])

      assert_received {:dp_exchange, :coinbase, %Types.Trade{symbol: "BTC-USD"}}
      refute_received {:dp_exchange, :coinbase, %Types.Quote{}}
      assert Fake.coverage_by_kind() == %{trades: %{"BTC-USD" => :stream}}
      assert Fake.coverage() == %{"BTC-USD" => :stream}

      # Asking for quotes later adds that kind; it does not need the trades call repeated.
      :ok = Fake.subscribe(["BTC-USD"], to: self())
      assert_received {:dp_exchange, :coinbase, %Types.Quote{symbol: "BTC-USD"}}

      assert %{quotes: %{"BTC-USD" => :stream}, trades: %{"BTC-USD" => :stream}} =
               Fake.coverage_by_kind()
    end

    test "an unknown or empty :channels is refused before anything is pushed or covered" do
      for bad <- [[:candles], [:quotes, :candles], [], :quotes, [:quotes | :trades]] do
        assert {:error, {:invalid_option, :channels, ^bad}} =
                 Fake.subscribe(["BTC-USD"], to: self(), channels: bad)
      end

      refute_received {:dp_exchange, :coinbase, _anything}
      assert Fake.coverage() == %{}
    end

    test "update_symbols does not give a trades-only symbol quote coverage" do
      :ok = Fake.subscribe(["BTC-USD"], to: self(), channels: [:trades])
      :ok = Fake.update_symbols(["BTC-USD"])

      refute Map.has_key?(Fake.coverage_by_kind(), :quotes)
      assert Fake.coverage() == %{"BTC-USD" => :stream}
    end

    test "update_symbols pushes for a symbol it adds" do
      :ok = Fake.update_symbols(["ETH-USD"])

      assert_received {:dp_exchange, :coinbase, %Types.Quote{symbol: "ETH-USD"}}
      assert Fake.coverage() == %{"ETH-USD" => :stream}
    end

    test "subscribe does not consume a failure queued for get_price" do
      DpExchange.Core.FakeInjection.queue_failures(:coinbase, [{:error, :queued}])
      :ok = Fake.subscribe(["BTC-USD"], to: self())

      assert {:error, :queued} = Fake.get_price("BTC-USD")
    end
  end
end

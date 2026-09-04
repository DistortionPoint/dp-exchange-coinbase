defmodule DpExchange.Coinbase.FakeInjectionTest do
  @moduledoc """
  Proves `Fake` actually consults `Core.FakeInjection` — the shared mechanism itself is
  tested in `dp_exchange_core`; this is the wiring, per function, in this package.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Fake
  alias DpExchange.Core.FakeInjection

  @credentials %{api_key: "organizations/x/apiKeys/y", api_secret: "secret"}

  describe "whole-call injection reaches every function with a real success path" do
    test "get_symbols/1" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.get_symbols() == {:error, :injected}
    end

    test "get_market_overview/1" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.get_market_overview([]) == {:error, :injected}
    end

    test "list_instruments/1" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.list_instruments([]) == {:error, :injected}
    end

    test "get_balances/2" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.get_balances(@credentials, []) == {:error, :injected}
    end

    test "get_accounts/2" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.get_accounts(@credentials, []) == {:error, :injected}
    end

    test "get_fees/2" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.get_fees(@credentials, []) == {:error, :injected}
    end

    test "get_trade_history/2" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.get_trade_history(@credentials, []) == {:error, :injected}
    end

    test "test_connection/2" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.test_connection(@credentials, []) == {:error, :injected}
    end

    test "market_status/1" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.market_status([]) == {:error, :injected}
    end

    test "get_positions/1" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.get_positions([]) == {:error, :injected}
    end

    test "stake/3" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.stake("BTC", Decimal.new("1"), portfolio_id: "pf-1") == {:error, :injected}
    end

    test "unstake/3" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.unstake("BTC", Decimal.new("1"), portfolio_id: "pf-1") == {:error, :injected}
    end

    test "quote_conversion/4" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.quote_conversion("BTC", "USD", Decimal.new("1")) == {:error, :injected}
    end

    test "commit_conversion/2" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.commit_conversion("id", from: "a", to: "b") == {:error, :injected}
    end

    test "get_conversion/2" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.get_conversion("id", from: "a", to: "b") == {:error, :injected}
    end

    test "get_trade_volume/2" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.get_trade_volume(@credentials, []) == {:error, :injected}
    end

    test "list_portfolios/1" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.list_portfolios([]) == {:error, :injected}
    end

    test "create_account/1" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.create_account(name: "New") == {:error, :injected}
    end

    test "rename_account/3" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.rename_account("pf-1", "New") == {:error, :injected}
    end

    test "get_roles/1" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.get_roles([]) == {:error, :injected}
    end

    test "place_order/3" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.place_order(@credentials, %{}) == {:error, :injected}
    end

    test "cancel_order/3" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.cancel_order(@credentials, "fake-order-1") == {:error, :injected}
    end

    test "get_order/3" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.get_order(@credentials, "fake-order-1") == {:error, :injected}
    end

    test "get_orders/2" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.get_orders(@credentials) == {:error, :injected}
    end

    test "preview_order/3" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.preview_order(@credentials, %{}) == {:error, :injected}
    end

    test "replace_order/4" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.replace_order(@credentials, "fake-order-1", %{}) == {:error, :injected}
    end

    test "preview_replace/4" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.preview_replace(@credentials, "fake-order-1", %{}) == {:error, :injected}
    end

    test "list_payment_methods/2" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.list_payment_methods(@credentials, []) == {:error, :injected}
    end

    test "get_payment_method/3" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert Fake.get_payment_method(@credentials, "pm-1") == {:error, :injected}
    end

    test "transfer_internal/4" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})

      assert Fake.transfer_internal("BTC", Decimal.new("1"), [from: "a", to: "b"], []) ==
               {:error, :injected}
    end

    test "with nothing queued, normal Fake behaviour is unaffected" do
      assert {:ok, _symbols} = Fake.get_symbols()
    end
  end

  describe "symbol-targeted injection" do
    test "get_price/2 only fails for the targeted symbol" do
      FakeInjection.fail_always(:coinbase, "BTC-USD", {:error, :injected})

      assert Fake.get_price("BTC-USD") == {:error, :injected}
      assert {:ok, _quote} = Fake.get_price("ETH-USD")
    end

    test "get_top_of_book/2 only fails for the targeted symbol" do
      FakeInjection.fail_always(:coinbase, "BTC-USD", {:error, :injected})

      assert Fake.get_top_of_book("BTC-USD") == {:error, :injected}
      assert {:ok, _tob} = Fake.get_top_of_book("ETH-USD")
    end

    test "get_historical_prices/4 only fails for the targeted symbol" do
      FakeInjection.fail_always(:coinbase, "BTC-USD", {:error, :injected})

      assert Fake.get_historical_prices("BTC-USD", "1m") == {:error, :injected}
      assert {:ok, [_candle]} = Fake.get_historical_prices("ETH-USD", "1m")
    end

    test "get_order_book/2 only fails for the targeted symbol" do
      FakeInjection.fail_always(:coinbase, "BTC-USD", {:error, :injected})

      assert Fake.get_order_book("BTC-USD") == {:error, :injected}
      assert {:ok, _book} = Fake.get_order_book("ETH-USD")
    end

    test "get_trades/2 only fails for the targeted symbol" do
      FakeInjection.fail_always(:coinbase, "BTC-USD", {:error, :injected})

      assert Fake.get_trades("BTC-USD") == {:error, :injected}
      assert {:ok, [_first | _rest]} = Fake.get_trades("ETH-USD")
    end

    test "quantization/1 only fails for the targeted symbol" do
      FakeInjection.fail_always(:coinbase, "BTC-USD", {:error, :injected})

      assert Fake.quantization("BTC-USD") == {:error, :injected}
      assert {:ok, _quantum} = Fake.quantization("ETH-USD")
    end

    test "close_position/3 only fails for the targeted symbol" do
      FakeInjection.fail_always(:coinbase, "BTC-USD", {:error, :injected})

      assert Fake.close_position(@credentials, "BTC-USD") == {:error, :injected}
      assert {:ok, _order} = Fake.close_position(@credentials, "ETH-USD")
    end

    test "a whole-call queue still reaches a symbol-taking function with no symbol-specific override" do
      FakeInjection.fail_always(:coinbase, {:error, :whole_call})

      assert Fake.get_price("BTC-USD") == {:error, :whole_call}
    end
  end

  describe "queue_failures/2 is deterministic and pops in order" do
    test "returns queued outcomes, then resumes normal behaviour" do
      FakeInjection.queue_failures(:coinbase, [{:error, :first}, {:error, :second}])

      assert Fake.get_symbols() == {:error, :first}
      assert Fake.get_symbols() == {:error, :second}
      assert {:ok, _symbols} = Fake.get_symbols()
    end
  end

  describe "isolation from other venues" do
    test "queuing for :coinbase never answers a read for another venue" do
      FakeInjection.fail_always(:coinbase, {:error, :injected})
      assert FakeInjection.next_outcome(:robinhood) == :none
    end
  end
end

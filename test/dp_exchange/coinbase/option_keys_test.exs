defmodule DpExchange.Coinbase.OptionKeysTest do
  @moduledoc """
  Every facade function that takes options refuses a key it does not read, on the real
  facade and on the Fake alike (`DpExchange.Core.Options`, the family's unknown-option
  rule). The real facade is called with a plug that reports any request it receives, so
  "refused" means "nothing was sent", not merely "an error came back".
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase
  alias DpExchange.Coinbase.{Fake, OptionKeys}

  @moduletag :capture_log

  @credentials %{
    api_key: "organizations/x/apiKeys/y",
    api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
  }
  @prime %{access_key: "k", passphrase: "p", signing_key: "c2VjcmV0"}

  # Every function in the table with a valid positional argument for each, so the refusal
  # under test is the option's and not an argument's. `o` is the option list under test.
  defp calls do
    one = Decimal.new(1)
    order = limit_order()
    changes = %{price: Decimal.new("40000"), quantity: Decimal.new("1")}
    setting = "INTRADAY_MARGIN_SETTING_STANDARD"

    [
      get_price: fn m, o -> m.get_price("BTC-USD", o) end,
      get_top_of_book: fn m, o -> m.get_top_of_book("BTC-USD", o) end,
      get_historical_prices: fn m, o -> m.get_historical_prices("BTC-USD", "1h", [], o) end,
      get_symbols: fn m, o -> m.get_symbols(o) end,
      get_market_overview: fn m, o -> m.get_market_overview(o) end,
      list_instruments: fn m, o -> m.list_instruments(o) end,
      get_order_book: fn m, o -> m.get_order_book("BTC-USD", o) end,
      get_trades: fn m, o -> m.get_trades("BTC-USD", o) end,
      get_balances: fn m, o -> m.get_balances(@credentials, o) end,
      get_accounts: fn m, o -> m.get_accounts(@credentials, o) end,
      get_fees: fn m, o -> m.get_fees(@credentials, o) end,
      get_trade_volume: fn m, o -> m.get_trade_volume(@credentials, o) end,
      get_orders: fn m, o -> m.get_orders(@credentials, o) end,
      get_trade_history: fn m, o -> m.get_trade_history(@credentials, o) end,
      place_order: fn m, o -> m.place_order(@credentials, order, o) end,
      preview_order: fn m, o -> m.preview_order(@credentials, order, o) end,
      replace_order: fn m, o -> m.replace_order(@credentials, "o-1", changes, o) end,
      preview_replace: fn m, o -> m.preview_replace(@credentials, "o-1", changes, o) end,
      cancel_order: fn m, o -> m.cancel_order(@credentials, "o-1", o) end,
      get_order: fn m, o -> m.get_order(@credentials, "o-1", o) end,
      close_position: fn m, o -> m.close_position(@credentials, "BTC-USD", o) end,
      list_payment_methods: fn m, o -> m.list_payment_methods(@credentials, o) end,
      get_payment_method: fn m, o -> m.get_payment_method(@credentials, "pm-1", o) end,
      get_roles: fn m, o -> m.get_roles(o) end,
      get_server_time: fn m, o -> m.get_server_time(o) end,
      test_connection: fn m, o -> m.test_connection(@credentials, o) end,
      market_status: fn m, o -> m.market_status(o) end,
      transfer_internal: fn m, o -> m.transfer_internal("USD", one, o, []) end,
      create_account: fn m, o -> m.create_account(o) end,
      rename_account: fn m, o -> m.rename_account("pf-1", "name", o) end,
      delete_portfolio: fn m, o -> m.delete_portfolio(@credentials, "pf-1", o) end,
      list_portfolios: fn m, o -> m.list_portfolios(o) end,
      get_portfolio_breakdown: fn m, o -> m.get_portfolio_breakdown(@credentials, "pf-1", o) end,
      quote_conversion: fn m, o -> m.quote_conversion("USD", "USDC", one, o) end,
      commit_conversion: fn m, o -> m.commit_conversion("c-1", o) end,
      get_conversion: fn m, o -> m.get_conversion("c-1", o) end,
      get_positions: fn m, o -> m.get_positions(o) end,
      list_futures_positions: fn m, o -> m.list_futures_positions(o) end,
      get_futures_position: fn m, o ->
        m.get_futures_position(@credentials, "BIT-28JUL23-CDE", o)
      end,
      get_futures_balance_summary: fn m, o -> m.get_futures_balance_summary(@credentials, o) end,
      list_futures_sweeps: fn m, o -> m.list_futures_sweeps(@credentials, o) end,
      cancel_futures_sweep: fn m, o -> m.cancel_futures_sweep(@credentials, o) end,
      get_intraday_margin_setting: fn m, o -> m.get_intraday_margin_setting(@credentials, o) end,
      set_intraday_margin_setting: fn m, o ->
        m.set_intraday_margin_setting(@credentials, setting, o)
      end,
      schedule_futures_sweep: fn m, o -> m.schedule_futures_sweep(@credentials, o) end,
      get_current_margin_window: fn m, o -> m.get_current_margin_window(@credentials, o) end,
      stake: fn m, o -> m.stake("ETH", one, o) end,
      unstake: fn m, o -> m.unstake("ETH", one, o) end,
      query_transaction_validators: fn m, o ->
        m.query_transaction_validators(@prime, "pf-1", o)
      end,
      staking_status: fn m, o -> m.staking_status(@prime, "pf-1", "w-1", o) end,
      unstake_status: fn m, o -> m.unstake_status(@prime, "pf-1", "w-1", o) end,
      claim_rewards: fn m, o -> m.claim_rewards(@prime, "pf-1", "w-1", o) end,
      preview_unstake_wallet: fn m, o ->
        m.preview_unstake_wallet(@prime, "pf-1", "w-1", "ETH", one, o)
      end,
      subscribe: fn m, o -> m.subscribe(["BTC-USD"], o) end,
      unsubscribe: fn m, o -> m.unsubscribe(["BTC-USD"], o) end,
      update_symbols: fn m, o -> m.update_symbols(["BTC-USD"], o) end,
      subscribe_notices: fn m, o -> m.subscribe_notices(o) end
    ]
  end

  defp raising_calls do
    [
      coverage: fn m, o -> m.coverage(o) end,
      wanted: fn m, o -> m.wanted(o) end,
      coverage_by_kind: fn m, o -> m.coverage_by_kind(o) end
    ]
  end

  defp limit_order do
    %{
      symbol: "BTC-USD",
      side: :buy,
      order_type: :limit,
      time_in_force: :gtc,
      quantity: Decimal.new("0.5"),
      price: Decimal.new("40000")
    }
  end

  # Answers `{}` and tells the test it was asked.
  defp reporting(test_pid) do
    fn conn ->
      send(test_pid, {:sent, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{}))
    end
  end

  defp stray_opts do
    # `limt` first: the first key the call does not read is the one named, and a no-request
    # call does not read the transport keys that follow.
    [limt: 1, plug: reporting(self()), retry_attempts: 0, credentials: @credentials]
  end

  defp one, do: Decimal.new(1)

  describe "the table" do
    test "names every probed function, each a real facade function that the Fake also has" do
      facade = for {name, _arity} <- Coinbase.__info__(:functions), do: name
      fake = for {name, _arity} <- Fake.__info__(:functions), do: name

      for function <- Keyword.keys(calls()) ++ Keyword.keys(raising_calls()) do
        assert function in facade
        assert function in fake
        assert is_list(OptionKeys.own_keys(function))
      end
    end

    test "allows a transport key only where the call reads it, and a function's own keys" do
      probe = DpExchange.Core.AdapterContract.unknown_option_probe()
      # `TransportKeysTest` holds the per-call detail; here only that nothing reads these.
      unread = [:environment, :base_url]

      for function <- Keyword.keys(calls()) ++ Keyword.keys(raising_calls()) do
        allowed = OptionKeys.allowed(function)

        assert :credentials in allowed
        assert Enum.all?(unread, &(&1 not in allowed))
        refute probe in allowed
      end

      assert :limit in OptionKeys.own_keys(:get_orders)
      refute :limit in OptionKeys.own_keys(:get_price)
      assert OptionKeys.own_keys(:update_symbols) == [:feed, :name]
      assert :name in OptionKeys.allowed(:get_balances)
      # `create_account/1` reads `:name` as the portfolio's name, once.
      assert Enum.count(OptionKeys.allowed(:create_account), &(&1 == :name)) == 1
      refute :url in OptionKeys.allowed(:coverage)
    end

    test "an unknown function is a KeyError, never an allow-all" do
      assert_raise KeyError, fn -> OptionKeys.check(:no_such_function, []) end
    end
  end

  for module <- [Coinbase, Fake] do
    describe "#{inspect(module)}: a key nothing reads" do
      test "is refused by name on every function that answers an error, and nothing is sent" do
        module = unquote(module)

        answers =
          for {name, call} <- calls(), do: {name, call.(module, stray_opts())}

        for {name, answer} <- answers do
          assert answer == {:error, {:unknown_option, :limt}},
                 "#{name} given limt: 1 answered #{inspect(answer, limit: 6)}"
        end

        refute_receive {:sent, _path}, 500
      end

      test "is refused even when its value is nil, because the caller meant something by it" do
        module = unquote(module)
        opts = [plug: reporting(self()), limt: nil]

        assert {:error, {:unknown_option, :limt}} = module.get_orders(@credentials, opts)
        assert {:error, {:unknown_option, :limt}} = module.get_symbols(opts)

        refute_receive {:sent, _path}, 500
      end

      test "options that are not a keyword list are refused, not raised on" do
        module = unquote(module)

        for bad <- [%{}, [1], "x"], {name, call} <- calls() do
          answer = call.(module, bad)

          assert answer == {:error, {:invalid_options, bad}},
                 "#{name} given #{inspect(bad)} answered #{inspect(answer, limit: 6)}"
        end
      end

      test "the reads with no error channel raise ArgumentError instead" do
        module = unquote(module)

        for {name, call} <- raising_calls() do
          assert_raise ArgumentError, ~r/#{name}/, fn -> call.(module, limt: 1) end
          assert_raise ArgumentError, ~r/#{name}/, fn -> call.(module, %{}) end
        end

        assert module.coverage([]) == %{}
        assert module.wanted([]) == []
        assert module.coverage_by_kind([]) == %{}
      end
    end
  end

  # Always sent exactly once: no idempotency key the venue honours, so no retry keys.
  @sent_once ~w(cancel_order replace_order transfer_internal create_account delete_portfolio
                commit_conversion schedule_futures_sweep cancel_futures_sweep)a

  for module <- [Coinbase, Fake] do
    describe "#{inspect(module)}: retry keys on a sent-once call" do
      test "are refused by name for any value, and nothing is sent" do
        module = unquote(module)
        probed = Keyword.take(calls(), @sent_once)
        assert length(probed) == length(@sent_once)

        for {name, call} <- probed, key <- [:retry_attempts, :retry_delay], value <- [0, 1, 3] do
          answer =
            call.(module, [{key, value}, plug: reporting(self()), credentials: @credentials])

          assert answer == {:error, {:unknown_option, key}},
                 "#{name} given #{key}: #{value} answered #{inspect(answer, limit: 6)}"
        end

        refute_receive {:sent, _path}, 500
      end

      test "are still read by the writes that carry an idempotency key" do
        module = unquote(module)
        keyed = Keyword.take(calls(), [:place_order, :close_position])
        assert length(keyed) == 2

        for {name, call} <- keyed, key <- [:retry_attempts, :retry_delay] do
          answer = call.(module, [{key, 1}, limt: 1, credentials: @credentials])

          assert answer == {:error, {:unknown_option, :limt}},
                 "#{name} reads #{key}, so the stray limt is the first refusal"
        end
      end
    end
  end

  describe "a function the venue does not serve" do
    test "keeps answering not_supported whatever the options" do
      for module <- [Coinbase, Fake] do
        assert module.get_funding("BTC-USD", limt: 1) == {:error, :not_supported}
        assert module.get_transfers(@credentials, limt: 1) == {:error, :not_supported}

        assert module.withdraw("BTC", "bitcoin", one(), "addr", limt: 1) ==
                 {:error, :not_supported}
      end
    end
  end

  describe "the order of the checks" do
    test "a malformed symbol is refused before a stray option" do
      for module <- [Coinbase, Fake] do
        assert {:error, {:invalid_symbol, nil}} = module.get_price(nil, limt: 1)
        assert {:error, {:invalid_symbol, nil}} = module.get_trades(nil, limt: 1)

        assert {:error, {:invalid_symbol, nil}} =
                 module.get_historical_prices(nil, "1h", [], limt: 1)
      end
    end

    test "a stray option is refused before the credential is read" do
      for module <- [Coinbase, Fake] do
        assert module.get_top_of_book("BTC-USD", limt: 1) ==
                 {:error, {:unknown_option, :limt}}

        assert module.get_orders(nil, limt: 1) == {:error, {:unknown_option, :limt}}
      end
    end
  end
end

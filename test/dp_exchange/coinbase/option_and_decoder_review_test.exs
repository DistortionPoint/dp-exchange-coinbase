defmodule DpExchange.Coinbase.OptionAndDecoderReviewTest do
  @moduledoc """
  Tick AJ: an option no read honours is refused by name, a page size above the spec's type is
  refused, and the decoders it touched fail closed on a field they cannot read.

  A misspelt `limt:` or `symbl:` used to be dropped without a word, and the call answered
  for a different question than the one asked: an unfiltered, unbounded history under a
  filter's name. Every refusal below is asserted against a plug that reports any request it
  receives, so "refused" means "nothing was sent", not merely "an error came back".
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Fake, Feed, Prime, Rest}
  alias DpExchange.Core.{Config, Types}

  @moduletag :capture_log

  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{
    api_key: "organizations/x/apiKeys/y",
    api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
  }

  # Answers `body` and tells the test it was asked.
  defp reporting(body, test_pid) do
    fn conn ->
      send(test_pid, {:sent, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp responding(body), do: reporting(body, self())

  defp opts(body \\ %{}, extra \\ []),
    do: Keyword.merge([plug: responding(body), retry_attempts: 0], extra)

  defp fill(overrides \\ %{}) do
    Map.merge(
      %{
        "trade_id" => "t-1",
        "order_id" => "o-1",
        "trade_time" => "2026-08-31T09:59:59Z",
        "trade_type" => "FILL",
        "price" => "40100.50",
        "size" => "0.25",
        "commission" => "1.20",
        "product_id" => "BTC-USD",
        "liquidity_indicator" => "TAKER",
        "side" => "BUY"
      },
      overrides
    )
  end

  describe "an option no read honours" do
    test "is refused by name on every read, and nothing is sent" do
      start = ~U[2026-08-30 00:00:00Z]
      range = [strat: start, end: ~U[2026-08-30 05:00:00Z]]

      history = Rest.get_trade_history(@credentials, opts(%{}, symbl: "BTC-USD"))
      orders = Rest.get_orders(@credentials, opts(%{}, limt: 5))
      trades = Rest.get_trades("BTC-USD", opts(%{}, limit: 5, sinse: start))
      by_opts = Rest.get_historical_prices("BTC-USD", "1h", [], opts(%{}, limt: 5))
      by_range = Rest.get_historical_prices("BTC-USD", "1h", range, opts())
      book = Rest.get_order_book("BTC-USD", opts(%{}, deph: 5))

      assert history == {:error, {:unknown_option, :symbl}}
      assert orders == {:error, {:unknown_option, :limt}}
      assert trades == {:error, {:unknown_option, :sinse}}
      assert by_opts == {:error, {:unknown_option, :limt}}
      assert by_range == {:error, {:unknown_option, :strat}}
      assert book == {:error, {:unknown_option, :deph}}

      refute_receive {:sent, _path}, 500
    end

    test "the Fake refuses exactly as the real reads do" do
      history = Fake.get_trade_history(@credentials, symbl: "BTC-USD")
      orders = Fake.get_orders(@credentials, limt: 5)
      trades = Fake.get_trades("BTC-USD", limit: 5, sinse: 1)
      candles = Fake.get_historical_prices("BTC-USD", "1h", [], limt: 5)
      book = Fake.get_order_book("BTC-USD", deph: 5)

      assert history == {:error, {:unknown_option, :symbl}}
      assert orders == {:error, {:unknown_option, :limt}}
      assert trades == {:error, {:unknown_option, :sinse}}
      assert candles == {:error, {:unknown_option, :limt}}
      assert book == {:error, {:unknown_option, :deph}}
    end

    test "options that are not a keyword list are refused, not raised on" do
      for bad <- [%{limit: 5}, [1, 2], "limit", 5] do
        assert {:error, {:invalid_options, ^bad}} = Rest.get_orders(@credentials, bad)
        assert {:error, {:invalid_options, ^bad}} = Rest.get_trade_history(@credentials, bad)
        assert {:error, {:invalid_options, ^bad}} = Rest.get_trades("BTC-USD", bad)
      end
    end

    test "the keys each read does honour still pass" do
      body = %{"orders" => [], "cursor" => ""}

      assert {:ok, []} =
               Rest.get_orders(
                 @credentials,
                 opts(body, status: :open, symbol: "BTC-USD", limit: 5, portfolio: "pf-1")
               )

      assert_receive {:sent, path}, 5_000
      assert String.ends_with?(path, "/orders/historical/batch")

      assert {:ok, []} =
               Rest.get_trade_history(
                 @credentials,
                 opts(%{"fills" => [], "cursor" => ""},
                   trade_types: ["FILL"],
                   symbol: "BTC-USD",
                   order_id: "o-1",
                   start: ~U[2026-08-30 00:00:00Z],
                   end: ~U[2026-08-31 00:00:00Z],
                   limit: 5,
                   portfolio: "pf-1"
                 )
               )

      assert_receive {:sent, _fills_path}, 5_000
    end
  end

  describe "a page size above the spec's type" do
    test "is refused for orders (int32) and fills (int64), not sent" do
      too_big_for_orders = 2_147_483_648
      too_big_for_fills = 9_223_372_036_854_775_808

      assert {:error, {:invalid_option, :limit, ^too_big_for_orders}} =
               Rest.get_orders(@credentials, opts(%{}, limit: too_big_for_orders))

      assert {:error, {:invalid_option, :limit, ^too_big_for_fills}} =
               Rest.get_trade_history(@credentials, opts(%{}, limit: too_big_for_fills))

      assert {:error, {:invalid_option, :limit, ^too_big_for_orders}} =
               Fake.get_orders(@credentials, limit: too_big_for_orders)

      refute_receive {:sent, _path}, 500
    end

    test "the types' own maxima are accepted" do
      assert {:ok, []} =
               Rest.get_orders(
                 @credentials,
                 opts(%{"orders" => []}, limit: 2_147_483_647)
               )

      assert {:ok, []} =
               Rest.get_trade_history(
                 @credentials,
                 opts(%{"fills" => []}, limit: 9_223_372_036_854_775_807)
               )
    end
  end

  describe "a fill's commission" do
    test "that the venue stated and this cannot read refuses the history" do
      for bad <- ["abc", "NaN", "Infinity", "-Infinity", %{"x" => 1}, [1], true] do
        body = %{"fills" => [fill(%{"commission" => bad})], "cursor" => ""}

        assert {:error, {:invalid_decimal, :fee, ^bad}} =
                 Rest.get_trade_history(@credentials, opts(body)),
               "commission #{inspect(bad)} must not become a fee-free fill"
      end
    end

    test "that the venue did not state is nil" do
      for unstated <- [nil, ""] do
        body = %{"fills" => [fill(%{"commission" => unstated})], "cursor" => ""}

        assert {:ok, [%Types.Fill{fee: nil}]} = Rest.get_trade_history(@credentials, opts(body))
      end
    end

    test "that is a number is read as one" do
      body = %{"fills" => [fill(%{"commission" => 2})], "cursor" => ""}

      assert {:ok, [%Types.Fill{fee: fee}]} = Rest.get_trade_history(@credentials, opts(body))
      assert Decimal.equal?(fee, Decimal.new(2))
    end
  end

  describe "a fills cursor" do
    test "that is present and not a string refuses the history instead of ending it" do
      for bad <- [42, %{"next" => "x"}, ["x"], true] do
        body = %{"fills" => [fill()], "cursor" => bad}

        assert {:error, :unexpected_response_shape} =
                 Rest.get_trade_history(@credentials, opts(body)),
               "cursor #{inspect(bad)} must not read as the end of the history"
      end
    end

    test "that is absent or empty ends the walk" do
      for body <- [%{"fills" => [fill()]}, %{"fills" => [fill()], "cursor" => ""}] do
        assert {:ok, [_one]} = Rest.get_trade_history(@credentials, opts(body))
      end
    end

    test "that is offered back unchanged is refused at once" do
      # The first page offers "same"; the second is fetched with it and offers it back.
      assert {:error, :pagination_cursor_repeated} =
               Rest.get_trade_history(@credentials, plug: distinct_fills(), retry_attempts: 0)
    end
  end

  # Two fills that differ, so the repeat is the cursor's and not the duplicate-row check's.
  defp distinct_fills do
    counter = :counters.new(1, [])

    fn conn ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{"fills" => [fill(%{"trade_id" => "t-#{n}"})], "cursor" => "same"})
      )
    end
  end

  describe "a conversion's total_fee" do
    defp trade(total_fee) do
      %{
        "trade" => %{
          "id" => "t-1",
          "status" => "TRADE_STATUS_CREATED",
          "user_entered_amount" => %{"value" => "100", "currency" => "USD"},
          "total" => %{"value" => "99.9", "currency" => "USDC"},
          "total_fee" => total_fee
        }
      }
    end

    test "that was sent and is unreadable is refused, and does not crash the caller" do
      for bad <- ["0.1", 5, [1], true, %{"amount" => "x"}, %{"amount" => nil}, %{}] do
        assert {:error, :unexpected_response_shape} =
                 Rest.quote_conversion(
                   @credentials,
                   "USD",
                   "USDC",
                   Decimal.new("100"),
                   opts(trade(bad))
                 ),
               "total_fee #{inspect(bad)} is not 'no fee'"

        assert {:error, :unexpected_response_shape} =
                 Rest.get_conversion(@credentials, "t-1", opts(trade(bad), from: "a", to: "b"))
      end
    end

    test "that is null or absent is not stated" do
      absent = update_in(trade(nil), ["trade"], &Map.delete(&1, "total_fee"))

      for body <- [trade(nil), absent] do
        assert {:ok, %Types.Conversion{fee: nil}} =
                 Rest.get_conversion(@credentials, "t-1", opts(body, from: "a", to: "b"))
      end
    end

    test "that carries an amount is read" do
      good = %{"amount" => %{"value" => "0.1", "currency" => "USD"}}

      assert {:ok, %Types.Conversion{fee: fee}} =
               Rest.get_conversion(@credentials, "t-1", opts(trade(good), from: "a", to: "b"))

      assert Decimal.equal?(fee, Decimal.new("0.1"))
    end
  end

  describe "futures and portfolio reads" do
    test "a misspelt option is refused, never read as an absent one" do
      # `usd_amout:` absent would sweep EVERY available dollar.
      sweep = Rest.schedule_futures_sweep(@credentials, opts(%{}, usd_amout: "5"))
      window = Rest.get_current_margin_window(@credentials, opts(%{}, margin_profile: "x"))
      listing = Rest.list_portfolios(@credentials, opts(%{}, portfolio_typ: "DEFAULT"))
      breakdown = Rest.get_portfolio_breakdown(@credentials, "pf-1", opts(%{}, currncy: "EUR"))
      fees = Rest.get_fees(@credentials, opts(%{}, product_typ: "SPOT"))
      balances = Rest.get_balances(@credentials, opts(%{}, limt: 5))
      accounts = Rest.get_accounts(@credentials, opts(%{}, uid: "x"))
      create = Rest.create_portfolio(@credentials, opts(%{}, name: "n", nme: "m"))

      assert sweep == {:error, {:unknown_option, :usd_amout}}
      assert window == {:error, {:unknown_option, :margin_profile}}
      assert listing == {:error, {:unknown_option, :portfolio_typ}}
      assert breakdown == {:error, {:unknown_option, :currncy}}
      assert fees == {:error, {:unknown_option, :product_typ}}
      assert balances == {:error, {:unknown_option, :limt}}
      assert accounts == {:error, {:unknown_option, :uid}}
      assert create == {:error, {:unknown_option, :nme}}

      refute_receive {:sent, _path}, 500
    end

    test "a transfer with a stray option is refused" do
      assert {:error, {:unknown_option, :note}} =
               Rest.transfer_internal(
                 @credentials,
                 "USD",
                 Decimal.new(1),
                 opts(%{}, from: "a", to: "b", note: "x")
               )

      refute_receive {:sent, _path}, 500
    end

    test "the portfolio-less futures reads refuse a portfolio and any other key" do
      for call <- [
            &Rest.get_futures_balance_summary/2,
            &Rest.list_futures_sweeps/2,
            &Rest.cancel_futures_sweep/2,
            &Rest.get_intraday_margin_setting/2
          ] do
        assert {:error, {:unsupported_option, :portfolio}} =
                 call.(@credentials, opts(%{}, portfolio: "pf-1"))

        assert {:error, {:unknown_option, :scope}} = call.(@credentials, opts(%{}, scope: "x"))
      end

      assert {:error, {:unsupported_option, :portfolio}} =
               Rest.set_intraday_margin_setting(
                 @credentials,
                 "INTRADAY_MARGIN_SETTING_STANDARD",
                 opts(%{}, portfolio: "pf-1")
               )

      refute_receive {:sent, _path}, 500
    end

    test "the Fake refuses exactly as the real reads do" do
      assert {:error, {:unknown_option, :usd_amout}} =
               Fake.schedule_futures_sweep(@credentials, usd_amout: "5")

      assert {:error, {:unknown_option, :scope}} =
               Fake.list_futures_sweeps(@credentials, scope: "x")

      assert {:error, {:unsupported_option, :portfolio}} =
               Fake.get_futures_balance_summary(@credentials, portfolio: "pf-1")

      assert {:error, {:unknown_option, :portfolio_typ}} =
               Fake.list_portfolios(portfolio_typ: "DEFAULT", credentials: @credentials)
    end
  end

  describe "Prime staking calls" do
    @prime %{access_key: "k", passphrase: "p", signing_key: "c2VjcmV0"}

    test "a misspelt option is refused before anything is signed" do
      stake =
        Prime.stake_portfolio(@prime, "pf-1", "ETH", Decimal.new(1), opts(%{}, metdata: %{}))

      claim = Prime.claim_rewards(@prime, "pf-1", "w-1", opts(%{}, amout: Decimal.new(1)))
      typo = opts(%{}, transaction_id: ["t"])
      query = Prime.query_transaction_validators(@prime, "pf-1", typo)

      assert stake == {:error, {:unknown_option, :metdata}}
      assert claim == {:error, {:unknown_option, :amout}}
      assert query == {:error, {:unknown_option, :transaction_id}}

      refute_receive {:sent, _path}, 500
    end

    test "options that are not a keyword list are refused, not raised on" do
      for bad <- [%{}, [1], "x"] do
        assert {:error, {:invalid_options, ^bad}} =
                 DpExchange.Coinbase.stake("ETH", Decimal.new(1), bad)

        assert {:error, {:invalid_options, ^bad}} =
                 DpExchange.Coinbase.unstake("ETH", Decimal.new(1), bad)

        assert {:error, {:invalid_options, ^bad}} = Fake.stake("ETH", Decimal.new(1), bad)
      end
    end

    test "a key that cannot be spelt as a string is refused, not raised on" do
      body = %{{:a, 1} => "x"}

      extra_opts = opts(%{}, extra: body)
      body_opts = opts(%{}, body: body)
      one = Decimal.new(1)

      assert {:error, {:invalid_extra, ^body}} =
               Prime.stake_portfolio(@prime, "pf-1", "ETH", one, extra_opts)

      assert {:error, {:invalid_body, ^body}} =
               Prime.claim_rewards(@prime, "pf-1", "w-1", body_opts)

      refute_receive {:sent, _path}, 500
    end

    test "the subscription calls refuse a misspelt subscriber option" do
      assert {:error, {:unknown_option, :too}} = Feed.subscribe(Feed, ["BTC-USD"], too: self())
      assert {:error, {:unknown_option, :too}} = Feed.subscribe_notices(Feed, too: self())
      assert {:error, {:invalid_options, 5}} = Feed.subscribe(Feed, ["BTC-USD"], 5)
      assert {:error, {:unknown_option, :too}} = Fake.subscribe(["BTC-USD"], too: self())
      assert {:error, {:unknown_option, :too}} = Fake.subscribe_notices(too: self())
      facade = DpExchange.Coinbase
      assert {:error, {:unknown_option, :too}} = facade.subscribe(["BTC-USD"], too: 1)
      assert {:error, {:invalid_options, %{}}} = facade.subscribe(["BTC-USD"], %{})
    end
  end
end

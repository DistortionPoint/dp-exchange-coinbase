defmodule DpExchange.Coinbase.SpecExamplesTest do
  @moduledoc """
  Spec-example conformance: every REST endpoint and WebSocket channel this package calls
  or decodes, driven by a fixture built from **Coinbase's own committed spec** —
  `docs/reference/coinbase/openapi/{at-spec.yaml,prime-spec.yaml,at-async.json}` — never
  from a value this package's own code happens to produce.

  This family's worst bugs have come from a test fixture written to agree with the code
  instead of with the vendor: a field renamed, a type changed, a case shape guessed —
  and the test that should have caught it was built from the same guess. Every fixture
  under `test/fixtures/spec_examples/` is built by walking the vendor's own OpenAPI/
  AsyncAPI schema and preferring each field's own documented `example` value; where a
  decoded field has none, a value was constructed by hand and is recorded, with its
  reasoning, in `test/fixtures/spec_examples/README.md` and `.../fills.md`. Neither this
  test file nor those fixtures were built by reading `rest.ex`, `prime.ex` or `socket.ex`
  and copying a shape back out of them.

  Assertions check **meaningful decoded values** — a `Decimal` equal to the vendor's own
  string, a side atom carrying the documented semantics, a timestamp equal to the venue's
  own — not merely that a field is non-nil. Where the spec documents the request side
  (parameters, request body), the request actually sent is captured through the `plug:`
  seam and asserted against the spec's own field names, required-ness and types.

  See `test/fixtures/spec_examples/README.md` for the citation of every fixture (spec
  file, schema, line) and its documented gaps, and `.../fills.md` for the literal values
  used where the vendor spec provides no example at all.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Prime, Rest, Socket}
  alias DpExchange.Core.{Config, Instrument, Notice, Types}

  @moduletag :capture_log

  # The same process-scoped limiter seam every suite in this package uses: a real module
  # answering from configuration, not a mock — see CLAUDE.md's testing strategy.
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

  @prime_credentials %{
    access_key: "prime-key",
    passphrase: "prime-passphrase",
    signing_key: "prime-signing-key"
  }

  # --- fixture loading ------------------------------------------------------

  @fixtures_root Path.join([__DIR__, "..", "..", "fixtures", "spec_examples"])

  defp fixture!(relative_path) do
    [@fixtures_root, relative_path]
    |> Path.join()
    |> File.read!()
    |> Jason.decode!()
  end

  # --- plug helpers, following the existing suites' own conventions --------

  defp responding(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp capturing(body, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_string, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  # `get_accounts.json`/`get_historical_orders.json` document the vendor's own
  # `has_next: true` example verbatim (see README) — sent as-is, this would page forever
  # against a plug answering the same body every time. Every walking endpoint's own test
  # answers the first request with the real fixture and every following one (any request
  # whose query string carries a `cursor`) with an empty terminal page in the same
  # envelope, exactly as `accounts_test.exs`'s own `cursor=page2` pattern already does.
  defp paginate_once(first_page_body, empty_page_body) do
    fn conn ->
      body = if conn.query_string =~ "cursor=", do: empty_page_body, else: first_page_body

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  # `replace_order/4` reads the edit order back with a second call once the edit
  # succeeds (`rest.ex`'s `edit_result/4`) — a plug that answers by path, the same
  # multi-response pattern `place_order_test.exs` already uses for `edit_preview`.
  defp routing(by_path) do
    fn conn ->
      body = Enum.find_value(by_path, fn {match, body} -> conn.request_path =~ match && body end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  # ===========================================================================
  # Advanced Trade REST — market data
  # ===========================================================================

  describe "get_price/2 — GetMarketTrades / GetPublicMarketTrades" do
    test "private path (credentials given) decodes the venue's own trade as a Quote" do
      body = fixture!("at/get_market_trades.json")

      assert {:ok, %Types.Quote{} = quote_struct} =
               Rest.get_price("BTC-USD",
                 credentials: @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert quote_struct.symbol == "BTC-USD"
      assert Decimal.equal?(quote_struct.price, Decimal.new("140.91"))
      assert quote_struct.venue_time == ~U[2021-05-31 09:59:59Z]
      assert quote_struct.provider == :coinbase
    end

    test "public path (no credentials) decodes GetPublicMarketTrades the same way" do
      body = fixture!("at/get_public_market_trades.json")

      assert {:ok, %Types.Quote{} = quote_struct} =
               Rest.get_price("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(quote_struct.price, Decimal.new("140.91"))
    end

    test "requests exactly the credentialed path with limit=1, never the public one, when given a credential" do
      me = self()

      assert {:ok, _quote} =
               Rest.get_price("BTC-USD",
                 credentials: @credentials,
                 plug: capturing(fixture!("at/get_market_trades.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert path == "/api/v3/brokerage/products/BTC-USD/ticker"
      assert query =~ "limit=1"
    end
  end

  describe "get_trades/2 — the same ticker endpoint's trade list" do
    test "decodes every trade, flipping the venue's documented MAKER side to the contract's taker side" do
      body = fixture!("at/get_market_trades.json")

      assert {:ok, [%Types.Trade{} = trade]} =
               Rest.get_trades("BTC-USD",
                 credentials: @credentials,
                 limit: 10,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert trade.id == "34b080bf-fcfd-445a-832b-46b5ddc65601"
      # `HistoricalMarketTrade.side` is documented as the MAKER side
      # (at-spec.yaml:7752) and the fixture carries the vendor's own example, "BUY". This
      # package's `to_trade/2` flips it to the taker side per `Core.Types.Trade`'s own
      # contract — see `rest.ex`'s comment on `to_trade/2` — so a maker "BUY" decodes here
      # to `:sell`, not `:buy`.
      assert trade.side == :sell
      assert Decimal.equal?(trade.price, Decimal.new("140.91"))
      assert Decimal.equal?(trade.quantity, Decimal.new("4"))
      assert trade.timestamp == ~U[2021-05-31 09:59:59Z]
    end
  end

  describe "get_historical_prices/4 — Candles / GetPublicCandles" do
    test "decodes the venue's own OHLCV bar, epoch-seconds start and all" do
      body = fixture!("at/get_candles.json")

      assert {:ok, [%Types.Candle{} = candle]} =
               Rest.get_historical_prices(
                 "BTC-USD",
                 "1h",
                 [start: ~U[2026-01-01 00:00:00Z], end: ~U[2026-01-02 00:00:00Z]],
                 credentials: @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert candle.opened_at == DateTime.from_unix!(1_639_508_050)
      assert Decimal.equal?(candle.open, Decimal.new("140.21"))
      assert Decimal.equal?(candle.high, Decimal.new("140.21"))
      assert Decimal.equal?(candle.low, Decimal.new("140.21"))
      assert Decimal.equal?(candle.close, Decimal.new("140.21"))
      assert Decimal.equal?(candle.volume, Decimal.new("56437345"))
      assert candle.provider == :coinbase
    end

    test "the public path decodes GetPublicCandles identically" do
      body = fixture!("at/get_public_candles.json")

      assert {:ok, [%Types.Candle{} = candle]} =
               Rest.get_historical_prices(
                 "BTC-USD",
                 "1h",
                 [start: ~U[2026-01-01 00:00:00Z], end: ~U[2026-01-02 00:00:00Z]],
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(candle.close, Decimal.new("140.21"))
    end
  end

  describe "list_instruments/1, get_symbols/1, get_market_overview/1 — GetProducts / GetPublicProducts" do
    test "list_instruments/1 decodes an Instrument with the venue's SPOT type and online status" do
      body = fixture!("at/get_products.json")

      assert {:ok, [%Instrument{} = instrument]} =
               Rest.list_instruments(
                 credentials: @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert instrument.symbol == "BTC-USD"
      assert instrument.base == "BTC"
      assert instrument.quote == "USD"
      # ProductType's own enum has no per-value vendor example, only the wrapper's
      # placeholder "SPOT" (see README) — `product_type: "SPOT"` is what the fixture
      # carries, and `Instrument.instrument_from/1` maps it to `:spot`.
      assert instrument.instrument == :spot
      # `status: "online"` (a manual fill — Product.status has no vendor example at all,
      # required though it is; see fills.md) maps through `Instrument.status_from/1`.
      assert instrument.status == :tradable
    end

    test "get_symbols/1 (public) reads GetPublicProducts and returns canonical symbols" do
      body = fixture!("at/get_public_products.json")

      assert {:ok, ["BTC-USD"]} = Rest.get_symbols(plug: responding(body), retry_attempts: 0)
    end

    test "get_market_overview/1 decodes price/volume/status per symbol" do
      body = fixture!("at/get_products.json")

      assert {:ok, %{"BTC-USD" => row}} =
               Rest.get_market_overview(
                 credentials: @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(row.price, Decimal.new("140.21"))
      assert Decimal.equal?(row.volume_24h, Decimal.new("1908432"))
      assert row.status == "online"
    end

    test "get_alias_map/1 relates two DIFFERENT canonical symbols, per the venue's own alias field" do
      # `get_products_alias_pair.json` is a hand-curated variant of the auto-extracted
      # `Product` row — see README's "Hand-curated variants" for exactly what was
      # overridden and why (the vendor's own placeholder example puts the same string in
      # both `product_id` and `alias`, which cannot exercise this function's actual job).
      body = fixture!("at/get_products_alias_pair.json")

      assert {:ok, aliases} =
               Rest.get_alias_map(
                 credentials: @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert aliases["XLM-USDC"] == "XLM-USD"
      assert aliases["XLM-USD"] == "XLM-USDC"
    end
  end

  describe "quantization/2 — reads Product's price_increment, not quote_increment" do
    test "each field maps to its own distinct venue value, not a neighbouring one" do
      # See README's "Hand-curated variants": the vendor's own placeholder example is the
      # same string on every increment/min/max field, so this fixture gives each a
      # distinct value — the exact regression `quantization/2`'s moduledoc records.
      body = fixture!("at/get_product_distinct_increments.json")

      assert {:ok, quantization} =
               Rest.quantization("BTC-USD",
                 credentials: @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(quantization.price_increment, Decimal.new("0.01"))
      assert Decimal.equal?(quantization.quantity_increment, Decimal.new("0.00001"))
      assert Decimal.equal?(quantization.min_quantity, Decimal.new("0.0001"))
      assert Decimal.equal?(quantization.min_quote_size, Decimal.new("1"))
      assert Decimal.equal?(quantization.max_quantity, Decimal.new("500"))
      assert Decimal.equal?(quantization.max_quote_size, Decimal.new("2000000"))
      assert quantization.status == "online"
    end
  end

  describe "get_product/2 — Product / GetPublicProduct, returned unmodified" do
    test "the private path returns the venue's own product map, not a decoded struct" do
      body = fixture!("at/get_product.json")

      assert {:ok, product} =
               Rest.get_product("BTC-USD",
                 credentials: @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert product["product_id"] == "BTC-USD"
      assert product["status"] == "online"
      assert product["base_name"] == "Bitcoin"
    end

    test "the public path returns GetPublicProduct the same way" do
      body = fixture!("at/get_public_product.json")

      assert {:ok, product} =
               Rest.get_product("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert product["quote_name"] == "US Dollar"
    end
  end

  # ===========================================================================
  # Order book / top of book
  # ===========================================================================

  describe "get_top_of_book/2 — GetBestBidAsk (private only, per the venue)" do
    test "decodes best bid/ask as Decimal with the venue's own PriceBook time" do
      body = fixture!("at/get_best_bid_ask.json")

      assert {:ok, %Types.TopOfBook{} = top} =
               Rest.get_top_of_book("BTC-USD",
                 credentials: @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(top.bid, Decimal.new("79478.71"))
      assert Decimal.equal?(top.ask, Decimal.new("79478.71"))
      assert Decimal.equal?(top.bid_size, Decimal.new("0.5"))
      # `PriceBook.time` has no vendor field-level example (manual fill; see fills.md).
      assert top.venue_time == ~U[2026-08-28 14:53:45Z]
    end
  end

  describe "get_order_book/2 — GetProductBook / GetPublicProductBook" do
    test "the private path sorts and decodes both sides as Decimal" do
      body = fixture!("at/get_product_book.json")

      assert {:ok, %Types.OrderBook{} = book} =
               Rest.get_order_book("BTC-USD",
                 credentials: @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert book.symbol == "BTC-USD"
      assert [{price, size}] = book.bids
      assert Decimal.equal?(price, Decimal.new("79478.71"))
      assert Decimal.equal?(size, Decimal.new("0.5"))
      assert book.venue_time == ~U[2026-08-28 14:53:45Z]
    end

    test "the public path decodes GetPublicProductBook the same way" do
      body = fixture!("at/get_public_product_book.json")

      assert {:ok, %Types.OrderBook{} = book} =
               Rest.get_order_book("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert [{ask_price, _size}] = book.asks
      assert Decimal.equal?(ask_price, Decimal.new("79478.71"))
    end

    test "GetProductBook's documented query params are sent — product_id, limit, aggregation_price_increment" do
      me = self()

      assert {:ok, _book} =
               Rest.get_order_book("BTC-USD",
                 credentials: @credentials,
                 limit: 50,
                 aggregation_price_increment: "0.01",
                 plug: capturing(fixture!("at/get_product_book.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", "/api/v3/brokerage/product_book", query, _raw}
      assert query =~ "product_id=BTC-USD"
      assert query =~ "limit=50"
      assert query =~ "aggregation_price_increment=0.01"
    end
  end

  # ===========================================================================
  # Accounts & balances
  # ===========================================================================

  describe "get_balances/2, get_accounts/2 — GetAccounts / GetAccount" do
    test "get_balances/2 decodes currency and Decimal available/hold from the venue's own Account/Amount" do
      first_page = fixture!("at/get_accounts.json")
      empty_page = %{"accounts" => [], "has_next" => false}

      assert {:ok, [%Types.Balance{} = balance]} =
               Rest.get_balances(@credentials,
                 plug: paginate_once(first_page, empty_page),
                 retry_attempts: 0
               )

      assert balance.currency == "BTC"
      assert Decimal.equal?(balance.available_balance, Decimal.new("1.23"))
      assert Decimal.equal?(balance.hold, Decimal.new("1.23"))
      assert balance.provider == :coinbase
    end

    test "get_accounts/2 (listing) returns the venue's own account rows, unnormalised" do
      first_page = fixture!("at/get_accounts.json")
      empty_page = %{"accounts" => [], "has_next" => false}

      assert {:ok, [account]} =
               Rest.get_accounts(@credentials,
                 plug: paginate_once(first_page, empty_page),
                 retry_attempts: 0
               )

      assert account["uuid"] == "8bfc20d7-f7c6-4422-bf07-8243ca4169fe"
      assert account["platform"] == "ACCOUNT_PLATFORM_CONSUMER"
      assert account["ready"] == true
    end

    test "get_accounts/2 with :uuid reads GetAccount — the single-account form" do
      body = fixture!("at/get_account.json")

      assert {:ok, [account]} =
               Rest.get_accounts(@credentials,
                 uuid: "8bfc20d7-f7c6-4422-bf07-8243ca4169fe",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert account["name"] == "BTC Wallet"
      assert account["type"] == "FIAT"
    end
  end

  # ===========================================================================
  # Payment methods
  # ===========================================================================

  describe "list_payment_methods/2, get_payment_method/3 — GetPaymentMethods / GetPaymentMethod" do
    test "list_payment_methods/2 returns the venue's own rows" do
      body = fixture!("at/get_payment_methods.json")

      assert {:ok, [method]} =
               Rest.list_payment_methods(@credentials, plug: responding(body), retry_attempts: 0)

      assert method["type"] == "ACH"
      assert method["verified"] == true
    end

    test "get_payment_method/3 reads the single-method envelope" do
      body = fixture!("at/get_payment_method.json")

      assert {:ok, method} =
               Rest.get_payment_method(@credentials, "8bfc20d7-f7c6-4422-bf07-8243ca4169fe",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert method["currency"] == "USD"
      assert method["allow_withdraw"] == true
    end
  end

  # ===========================================================================
  # Key permissions & server time
  # ===========================================================================

  describe "get_key_permissions/2, get_server_time/1, test_connection/2" do
    test "get_key_permissions/2 returns the venue's own GetApiKeyPermissionsResponse" do
      body = fixture!("at/get_api_key_permissions.json")

      assert {:ok, permissions} =
               Rest.get_key_permissions(@credentials, plug: responding(body), retry_attempts: 0)

      assert permissions["portfolio_type"] == "DEFAULT"
    end

    test "test_connection/2 with credentials reads /key_permissions and stamps reachable: true" do
      body = fixture!("at/get_api_key_permissions.json")

      assert {:ok, %{"reachable" => true, "portfolio_type" => "DEFAULT"}} =
               Rest.test_connection(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "get_server_time/1 answers even the venue's minimal (field-example-free) GetServerTime" do
      body = fixture!("at/get_server_time.json")

      assert {:ok, time} = Rest.get_server_time(plug: responding(body), retry_attempts: 0)
      assert time == %{}
    end
  end

  # ===========================================================================
  # Fees & trade volume
  # ===========================================================================

  describe "get_fees/2, get_trade_volume/2 — GetTransactionSummary" do
    test "get_fees/2 decodes the venue's own fee tier and goods_and_services_tax" do
      body = fixture!("at/get_transaction_summary.json")

      assert {:ok, fees} = Rest.get_fees(@credentials, plug: responding(body), retry_attempts: 0)

      assert fees["fee_tier"]["taker_fee_rate"] == "0.0010"
      assert fees["fee_tier"]["maker_fee_rate"] == "0.0020"
      assert fees["goods_and_services_tax"]["type"] == "INCLUSIVE"
    end

    test "get_trade_volume/2 merges the venue's own account totals onto each volume_breakdown row" do
      body = fixture!("at/get_transaction_summary.json")

      assert {:ok, [row]} =
               Rest.get_trade_volume(@credentials, plug: responding(body), retry_attempts: 0)

      assert row["volume_type"] == "VOLUME_TYPE_SPOT"
      assert row["total_fees"] == 25
      assert row["advanced_trade_only_volume"] == 1000
    end
  end

  # ===========================================================================
  # Portfolios
  # ===========================================================================

  describe "list_portfolios/2, get_portfolio_breakdown/3, create/rename/delete_portfolio" do
    test "list_portfolios/2 decodes id/name/type/deleted from the venue's own Portfolio" do
      body = fixture!("at/get_portfolios.json")

      assert {:ok, [%Types.Portfolio{} = portfolio]} =
               Rest.list_portfolios(@credentials, plug: responding(body), retry_attempts: 0)

      assert portfolio.id == "8bfc20d7-f7c6-4422-bf07-8243ca4169fe"
      assert portfolio.name == "Default Portfolio"
      assert portfolio.deleted == false
    end

    test "get_portfolio_breakdown/3 returns the venue's own breakdown map, undecoded" do
      body = fixture!("at/get_portfolio_breakdown.json")

      assert {:ok, breakdown} =
               Rest.get_portfolio_breakdown(@credentials, "8bfc20d7-f7c6-4422-bf07-8243ca4169fe",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Map.has_key?(breakdown, "portfolio")
      assert Map.has_key?(breakdown, "portfolio_balances")
      assert Map.has_key?(breakdown, "spot_positions")
    end

    test "create_portfolio/2 decodes the venue's own CreatePortfolioResponse" do
      body = fixture!("at/create_portfolio.json")

      assert {:ok, %Types.Portfolio{name: "Default Portfolio"}} =
               Rest.create_portfolio(@credentials,
                 name: "Default Portfolio",
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "rename_portfolio/3 decodes EditPortfolioResponse" do
      body = fixture!("at/edit_portfolio.json")

      assert {:ok, %Types.Portfolio{id: "8bfc20d7-f7c6-4422-bf07-8243ca4169fe"}} =
               Rest.rename_portfolio(
                 @credentials,
                 "8bfc20d7-f7c6-4422-bf07-8243ca4169fe",
                 "Default Portfolio",
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "delete_portfolio/3 accepts the venue's own (field-example-free) DeletePortfolioResponse" do
      body = fixture!("at/delete_portfolio.json")

      assert {:ok, _response} =
               Rest.delete_portfolio(@credentials, "8bfc20d7-f7c6-4422-bf07-8243ca4169fe",
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "transfer_internal/3 decodes MovePortfolioFundsResponse" do
      body = fixture!("at/move_portfolio_funds.json")

      assert {:ok, result} =
               Rest.transfer_internal(@credentials, "USD", Decimal.new("10"),
                 from: "8bfc20d7-f7c6-4422-bf07-8243ca4169fe",
                 to: "8bfc20d7-f7c6-4422-bf07-8243ca4169fe",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert result["source_portfolio_uuid"] == "8bfc20d7-f7c6-4422-bf07-8243ca4169fe"
    end
  end

  # ===========================================================================
  # Convert
  # ===========================================================================

  describe "quote_conversion/4, commit_conversion/3, get_conversion/3 — Convert endpoints" do
    test "quote_conversion/4 decodes id/status/from_amount/to_amount as Decimal" do
      body = fixture!("at/create_convert_quote.json")

      assert {:ok, %Types.Conversion{} = conversion} =
               Rest.quote_conversion(@credentials, "USD", "BTC", Decimal.new("125.50"),
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert conversion.status == :quoted
      assert conversion.from_asset == "USD"
      assert conversion.to_asset == "BTC"
      assert Decimal.equal?(conversion.from_amount, Decimal.new("125.50"))
      assert Decimal.equal?(conversion.to_amount, Decimal.new("125.50"))
    end

    test "commit_conversion/3 maps TRADE_STATUS_CREATED to :quoted (the venue's own enum, unedited)" do
      body = fixture!("at/commit_convert_trade.json")

      assert {:ok, %Types.Conversion{status: :quoted}} =
               Rest.commit_conversion(@credentials, "some-trade-id",
                 from: "USD-account",
                 to: "BTC-account",
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "get_conversion/3 reads the trade back the same way" do
      body = fixture!("at/get_convert_trade.json")

      assert {:ok, %Types.Conversion{id: id}} =
               Rest.get_conversion(@credentials, "some-trade-id",
                 from: "USD-account",
                 to: "BTC-account",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert id == "b6ec2e9a-1b6a-4b6a-9e1a-000000000001"
    end
  end

  # ===========================================================================
  # Futures (CFM)
  # ===========================================================================

  describe "get_positions/2, list_futures_positions/2, get_futures_position/3" do
    test "get_positions/2 normalises the venue's own FCMPosition into a Types.Position" do
      body = fixture!("at/get_fcm_positions.json")

      assert {:ok, [%Types.Position{} = position]} =
               Rest.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert position.symbol == "BIT-28JUL23-CDE"
      assert position.side == :long
      assert position.instrument_type == :future
      assert Decimal.equal?(position.quantity, Decimal.new("10"))
      assert Decimal.equal?(position.average_cost, Decimal.new("26500.00"))
      assert Decimal.equal?(position.mark_price, Decimal.new("27000.50"))
      assert Decimal.equal?(position.unrealised_pnl, Decimal.new("500.00"))
      # See `Rest.get_positions/2`'s own moduledoc: no lifetime realised PnL is published.
      assert position.realised_pnl == nil
    end

    test "list_futures_positions/2 returns the venue's own row, including daily_realized_pnl" do
      body = fixture!("at/get_fcm_positions.json")

      assert {:ok, [row]} =
               Rest.list_futures_positions(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["daily_realized_pnl"] == "120.00"
    end

    test "get_futures_position/3 reads the single-position envelope" do
      body = fixture!("at/get_fcm_position.json")

      assert {:ok, position} =
               Rest.get_futures_position(@credentials, "BIT-28JUL23-CDE",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert position["product_id"] == "BIT-28JUL23-CDE"
    end
  end

  describe "get_futures_balance_summary/2, sweeps, margin settings" do
    test "get_futures_balance_summary/2 returns the venue's own FCMBalanceSummary" do
      body = fixture!("at/get_fcm_balance_summary.json")

      assert {:ok, summary} =
               Rest.get_futures_balance_summary(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      # `get_futures_balance_summary/2` unwraps the `"balance_summary"` envelope key
      # itself — the returned map is its own contents, not the envelope.
      assert summary["futures_buying_power"] == %{"value" => "125.50", "currency" => "USD"}

      assert summary["intraday_margin_window_measure"]["margin_window_type"] ==
               "FCM_MARGIN_WINDOW_TYPE_OVERNIGHT"
    end

    test "list_futures_sweeps/2 returns the venue's own GetFCMSweepsResponse" do
      body = fixture!("at/get_fcm_sweeps.json")

      assert {:ok, _sweeps} =
               Rest.list_futures_sweeps(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "schedule_futures_sweep/2 accepts ScheduleFCMSweepResponse" do
      body = fixture!("at/schedule_fcm_sweep.json")

      assert {:ok, _response} =
               Rest.schedule_futures_sweep(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "cancel_futures_sweep/2 accepts CancelFCMSweepResponse" do
      body = fixture!("at/cancel_fcm_sweep.json")

      assert {:ok, _response} =
               Rest.cancel_futures_sweep(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "get_intraday_margin_setting/2 decodes the venue's own setting enum" do
      body = fixture!("at/get_intraday_margin_setting.json")

      assert {:ok, "INTRADAY_MARGIN_SETTING_STANDARD"} =
               Rest.get_intraday_margin_setting(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "set_intraday_margin_setting/3 accepts SetIntradayMarginSettingResponse" do
      body = fixture!("at/set_intraday_margin_setting.json")

      assert {:ok, _response} =
               Rest.set_intraday_margin_setting(@credentials, "INTRADAY_MARGIN_SETTING_STANDARD",
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "get_current_margin_window/2 decodes GetCurrentMarginWindowResponse" do
      body = fixture!("at/get_current_margin_window.json")

      assert {:ok,
              %{"margin_window" => %{"margin_window_type" => "MARGIN_WINDOW_TYPE_OVERNIGHT"}}} =
               Rest.get_current_margin_window(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end
  end

  # ===========================================================================
  # Trade history (fills)
  # ===========================================================================

  describe "get_trade_history/2 — GetFills" do
    test "decodes order_id/side/price/quantity/liquidity from a real Fill" do
      first_page = fixture!("at/get_fills.json")
      empty_page = %{"fills" => []}

      assert {:ok, [%Types.Fill{} = fill]} =
               Rest.get_trade_history(@credentials,
                 plug: paginate_once(first_page, empty_page),
                 retry_attempts: 0
               )

      assert fill.order_id == "0000-000000-000000"
      assert fill.trade_id == "1111-11111-111111"
      assert fill.symbol == "BTC-USD"
      assert fill.side == :buy
      assert Decimal.equal?(fill.price, Decimal.new("10000.00"))
      assert Decimal.equal?(fill.quantity, Decimal.new("0.001"))
      assert Decimal.equal?(fill.fee, Decimal.new("1.25"))
      assert fill.liquidity == :maker
      assert fill.timestamp == ~U[2021-05-31 09:59:59Z]
    end
  end

  # ===========================================================================
  # Orders
  # ===========================================================================

  describe "place_order/3 — PostOrder" do
    test "decodes the venue's own NewOrderSuccessResponse into a placed Order" do
      body = fixture!("at/post_order.json")

      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.001"),
        price: Decimal.new("40000"),
        order_type: :limit,
        time_in_force: :gtc
      }

      assert {:ok, %Types.Order{} = order} =
               Rest.place_order(@credentials, request, plug: responding(body), retry_attempts: 0)

      assert order.id == "11111-00000-000000"
      assert order.symbol == "BTC-USD"
      assert order.side == :buy
    end

    test "sends product_id/side/order_configuration — the fields OrderPreviewRequest/NewOrderRequest both document" do
      me = self()

      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.001"),
        price: Decimal.new("40000"),
        order_type: :limit,
        time_in_force: :gtc,
        post_only: false
      }

      assert {:ok, _order} =
               Rest.place_order(@credentials, request,
                 plug: capturing(fixture!("at/post_order.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", "/api/v3/brokerage/orders", _query, raw}
      decoded = Jason.decode!(raw)

      assert decoded["product_id"] == "BTC-USD"
      assert decoded["side"] == "BUY"
      assert is_map(decoded["order_configuration"])
      assert decoded["order_configuration"]["limit_limit_gtc"]["base_size"] == "0.001"
      # NewOrderRequest documents `post_only` and `size_in_quote` as `boolean`, not the
      # string `"false"` some venues send for the same field — this pins the JSON type.
      assert decoded["order_configuration"]["limit_limit_gtc"]["post_only"] == false
    end
  end

  describe "cancel_order/3 — CancelOrders (batch, one id)" do
    test "a matching row with success: true decodes to :cancelled" do
      body = fixture!("at/cancel_orders.json")

      assert {:ok, :cancelled} =
               Rest.cancel_order(@credentials, "0000-00000",
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "sends order_ids as a JSON array, per CancelOrdersRequest" do
      me = self()

      assert {:ok, :cancelled} =
               Rest.cancel_order(@credentials, "0000-00000",
                 plug: capturing(fixture!("at/cancel_orders.json"), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", "/api/v3/brokerage/orders/batch_cancel", _query, raw}
      assert Jason.decode!(raw) == %{"order_ids" => ["0000-00000"]}
    end
  end

  describe "get_order/3, get_orders/2 — GetHistoricalOrder / GetHistoricalOrders" do
    test "get_order/3 decodes the venue's own Order" do
      body = fixture!("at/get_historical_order.json")

      assert {:ok, %Types.Order{} = order} =
               Rest.get_order(@credentials, "0000-000000-000000",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert order.id == "0000-000000-000000"
      assert order.symbol == "BTC-USD"
    end

    test "get_orders/2 walks one real page of GetHistoricalOrders" do
      first_page = fixture!("at/get_historical_orders.json")
      empty_page = %{"orders" => [], "has_next" => false}

      assert {:ok, [%Types.Order{} = order]} =
               Rest.get_orders(@credentials,
                 plug: paginate_once(first_page, empty_page),
                 retry_attempts: 0
               )

      assert order.id == "0000-000000-000000"
    end
  end

  describe "preview_order/3 — OrderPreviewResponse, both the refusal and the acceptance branch" do
    test "a populated errs array (the venue's own required-but-example-free field) is a refusal" do
      body = fixture!("at/preview_order.json")

      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.001"),
        price: Decimal.new("40000"),
        order_type: :limit,
        time_in_force: :gtc
      }

      assert {:refused, {:preview_rejected, ["PREVIEW_MISSING_COMMISSION_RATE"]}} =
               Rest.preview_order(@credentials, request,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "an empty errs array (the accepted-variant fixture) decodes real Decimal totals" do
      body = fixture!("at/preview_order_accepted.json")

      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.001"),
        price: Decimal.new("40000"),
        order_type: :limit,
        time_in_force: :gtc
      }

      assert {:ok, preview} =
               Rest.preview_order(@credentials, request,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(preview.order_total, Decimal.new("10025.00"))
      assert Decimal.equal?(preview.commission_total, Decimal.new("25.00"))
      assert Decimal.equal?(preview.best_bid, Decimal.new("39999.50"))
      assert Decimal.equal?(preview.best_ask, Decimal.new("40000.50"))
      # `quote_size`/`base_size` carry the vendor's own JSON-number examples (10, 0.001)
      # against a field documented `type: string` — see README's spec self-contradictions.
      # `decimal/1` already handles a number, so this is also the conformance check that
      # this particular vendor inconsistency does not crash decoding.
      assert Decimal.equal?(preview.base_size, Decimal.new("0.001"))
    end
  end

  describe "preview_replace/4 — PreviewEditOrderResponse, both branches" do
    test "a populated errors array is an edit-preview refusal" do
      body = fixture!("at/preview_edit_order.json")

      assert {:refused, {:edit_preview_rejected, [%{"edit_failure_reason" => _reason}]}} =
               Rest.preview_replace(
                 @credentials,
                 "0000-000000-000000",
                 %{price: Decimal.new("41000"), quantity: Decimal.new("0.002")},
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "an empty errors array decodes real Decimal totals" do
      body = fixture!("at/preview_edit_order_accepted.json")

      assert {:ok, preview} =
               Rest.preview_replace(
                 @credentials,
                 "0000-000000-000000",
                 %{price: Decimal.new("41000"), quantity: Decimal.new("0.002")},
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(preview.base_size, Decimal.new("0.001"))
    end
  end

  describe "close_position/3 — ClosePositionResponse" do
    test "decodes a placed closing order from the venue's own NewOrderSuccessResponse shape" do
      body = fixture!("at/close_position.json")

      assert {:ok, %Types.Order{} = order} =
               Rest.close_position(@credentials, "BTC-USD",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert order.id == "11111-00000-000000"
      assert order.symbol == "BTC-USD"
      # See `close_position/3`'s own moduledoc: the venue echoes no side for a close.
      assert order.side == nil
    end
  end

  describe "replace_order/4 — EditOrderResponse success reads the order back" do
    test "success: true triggers a second GET, decoded as the venue's own Order" do
      responses = %{
        "/orders/edit" => fixture!("at/edit_order.json"),
        "/orders/historical/" => fixture!("at/get_historical_order.json")
      }

      assert {:ok, %Types.Order{} = order} =
               Rest.replace_order(
                 @credentials,
                 "0000-000000-000000",
                 %{price: Decimal.new("41000"), quantity: Decimal.new("0.002")},
                 plug: routing(responses),
                 retry_attempts: 0
               )

      assert order.id == "0000-000000-000000"
    end
  end

  # ===========================================================================
  # Prime staking — every response is returned unmodified; every request is asserted
  # against the spec's own required fields and types directly (see README's "Prime
  # request bodies" section for why there is no request fixture).
  # ===========================================================================

  describe "Prime portfolio-scoped staking — StakingInitiate / StakingUnstake (portfolio)" do
    test "stake_portfolio/5 sends exactly idempotency_key, currency_symbol, amount" do
      me = self()
      body = fixture!("prime/portfolio_staking_initiate.json")

      assert {:ok, response} =
               Prime.stake_portfolio(@prime_credentials, "pf-1", "eth", Decimal.new("16"),
                 idempotency_key: "test-key-1",
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert response == body

      assert_receive {:request, "POST", "/v1/portfolios/pf-1/staking/initiate", _query, raw}
      decoded = Jason.decode!(raw)

      assert Map.keys(decoded) |> Enum.sort() == ["amount", "currency_symbol", "idempotency_key"]
      assert decoded["currency_symbol"] == "ETH"
      assert decoded["amount"] == "16"
      assert decoded["idempotency_key"] == "test-key-1"
    end

    test "unstake_portfolio/5 sends idempotency_key, currency_symbol, amount to the unstake path" do
      me = self()
      body = fixture!("prime/portfolio_staking_unstake.json")

      assert {:ok, _response} =
               Prime.unstake_portfolio(@prime_credentials, "pf-1", "eth", Decimal.new("16"),
                 idempotency_key: "test-key-2",
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", "/v1/portfolios/pf-1/staking/unstake", _query, raw}
      decoded = Jason.decode!(raw)

      assert decoded["currency_symbol"] == "ETH"
      assert decoded["amount"] == "16"
    end
  end

  describe "Prime wallet-scoped staking — StakingInitiate / StakingUnstake (wallet)" do
    test "stake_wallet/6 nests amount under inputs, and sends no currency field the schema does not have" do
      me = self()
      body = fixture!("prime/staking_initiate.json")

      assert {:ok, response} =
               Prime.stake_wallet(@prime_credentials, "pf-1", "wal-1", "eth", Decimal.new("16"),
                 idempotency_key: "test-key-3",
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert response["wallet_id"] == "1a2b3c4d-9f8e-4a1e-b0a3-0000000wallet"
      assert response["activity_id"] == "act_0000000000000003"

      assert_receive {:request, "POST", "/v1/portfolios/pf-1/wallets/wal-1/staking/initiate",
                      _query, raw}

      decoded = Jason.decode!(raw)

      assert decoded["idempotency_key"] == "test-key-3"
      assert decoded["inputs"] == %{"amount" => "16"}
      refute Map.has_key?(decoded, "currency")
      refute Map.has_key?(decoded, "currency_symbol")
    end

    test "unstake_wallet/6 sends the same wallet-scoped shape to the unstake path" do
      me = self()
      body = fixture!("prime/staking_unstake.json")

      assert {:ok, _response} =
               Prime.unstake_wallet(@prime_credentials, "pf-1", "wal-1", "eth", Decimal.new("8"),
                 idempotency_key: "test-key-4",
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", "/v1/portfolios/pf-1/wallets/wal-1/staking/unstake",
                      _query, raw}

      assert Jason.decode!(raw)["inputs"] == %{"amount" => "8"}
    end
  end

  describe "Prime preview, status and claim" do
    test "preview_unstake_wallet/6 sends {amount} alone — no idempotency_key, no currency" do
      me = self()
      body = fixture!("prime/preview_unstake.json")

      assert {:ok, response} =
               Prime.preview_unstake_wallet(
                 @prime_credentials,
                 "pf-1",
                 "wal-1",
                 "eth",
                 Decimal.new("8"),
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert response["estimated_amount"] == "15.5"

      assert_receive {:request, "POST", _path, _query, raw}
      assert Jason.decode!(raw) == %{"amount" => "8"}
    end

    test "unstake_status/4 (GET) decodes the venue's own UnstakingStatus rows unmodified" do
      body = fixture!("prime/get_unstaking_status.json")

      assert {:ok, response} =
               Prime.unstake_status(@prime_credentials, "pf-1", "wal-1",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert response == body
      assert [validator] = response["validators"]
      assert validator["validator_address"] == "0xva11da700000000000000000000000000000001"
    end

    test "staking_status/4 (GET) decodes the venue's own StakingStatus rows unmodified" do
      body = fixture!("prime/get_staking_status.json")

      assert {:ok, response} =
               Prime.staking_status(@prime_credentials, "pf-1", "wal-1",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert [validator] = response["validators"]
      assert [status] = validator["statuses"]
      assert status["amount"] == "16"
      assert status["estimated_hours_to_stake"] == 672
    end

    test "claim_rewards/4 always sends idempotency_key, generated when the caller gives none" do
      me = self()
      body = fixture!("prime/staking_claim_rewards.json")

      assert {:ok, response} =
               Prime.claim_rewards(@prime_credentials, "pf-1", "wal-1",
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert response["transaction_id"] == "txn_0000000000000005"

      assert_receive {:request, "POST", "/v1/portfolios/pf-1/wallets/wal-1/staking/claim_rewards",
                      _query, raw}

      decoded = Jason.decode!(raw)
      assert is_binary(decoded["idempotency_key"]) and decoded["idempotency_key"] != ""
    end
  end

  describe "Prime query_transaction_validators/3 — ListTransactionValidators" do
    test "decodes the venue's own transaction/validator pairs and pagination unmodified" do
      me = self()
      body = fixture!("prime/list_transaction_validators.json")

      assert {:ok, response} =
               Prime.query_transaction_validators(@prime_credentials, "pf-1",
                 transaction_ids: ["txn-1"],
                 plug: capturing(body, me),
                 retry_attempts: 0
               )

      assert [row] = response["transaction_validators"]
      assert row["transaction_id"] == "8f14e45f-ceea-467e-0000-000000000txn"
      assert row["validator_address"] == "0xva11da700000000000000000000000000000001"
      assert response["pagination"]["has_next"] == false

      assert_receive {:request, "POST",
                      "/v1/portfolios/pf-1/staking/transaction-validators/query", _query, raw}

      assert Jason.decode!(raw) == %{"transaction_ids" => ["txn-1"]}
    end

    test "refuses locally, never sending an empty list on the caller's behalf" do
      assert {:error, :missing_transaction_ids} =
               Prime.query_transaction_validators(@prime_credentials, "pf-1", retry_attempts: 0)
    end
  end

  # ===========================================================================
  # WebSocket — ticker and level2, the only channels this package ever subscribes to
  # (`streamable: [:quotes, :order_book]`); heartbeats and status prove the no-op and
  # the catch-all against genuine vendor-shaped frames.
  # ===========================================================================

  defp socket_state(subscriber \\ nil) do
    %{
      subscriber: subscriber || self(),
      credentials: nil,
      delivering: MapSet.new(),
      connected_once?: false,
      last_seq: nil,
      stale_run: nil,
      last_frame_at: nil,
      silence_check: nil
    }
  end

  defp frame!(relative_path) do
    payload = fixture!(relative_path)
    Socket.handle_frame({:text, Jason.encode!(payload)}, socket_state())
  end

  describe "ticker channel — TickerEnvelope/Ticker (at-async.json)" do
    test "decodes a Quote with Decimal price/volume and the envelope's own timestamp" do
      assert {:ok, _state} = frame!("websocket/ticker.json")

      assert_received {:dp_exchange, :coinbase, %Types.Quote{} = quote_struct}
      assert quote_struct.symbol == "BTC-USD"
      assert Decimal.equal?(quote_struct.price, Decimal.new("79478.7"))
      assert Decimal.equal?(quote_struct.volume, Decimal.new("1234.5"))
      assert quote_struct.venue_time == ~U[2026-08-28 14:53:45.649112Z]
      assert quote_struct.provider == :coinbase
    end
  end

  describe "l2_data channel — L2Envelope/L2Update (at-async.json)" do
    test "a snapshot decodes to OrderBook, sorted, with bid/offer mapped to :bid/:ask" do
      assert {:ok, _state} = frame!("websocket/l2_snapshot.json")

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{} = book}
      assert book.symbol == "BTC-USD"
      assert [{bid_price, bid_qty}] = book.bids
      assert Decimal.equal?(bid_price, Decimal.new("79478.0"))
      assert Decimal.equal?(bid_qty, Decimal.new("0.5"))
      assert [{ask_price, _ask_qty}] = book.asks
      assert Decimal.equal?(ask_price, Decimal.new("79479.0"))
      # `L2Update.event_time` (per-row) becomes `venue_time` as the MAX across the
      # snapshot's own rows — see `socket.ex`'s `latest_event_time/1`.
      assert book.venue_time == ~U[2026-08-28 14:53:45.610000Z]
    end

    test "an update decodes to OrderBookDelta, carrying the venue's own bid side and a zero-quantity removal" do
      assert {:ok, _state} = frame!("websocket/l2_update.json")

      assert_received {:dp_exchange, :coinbase, %Types.OrderBookDelta{} = delta}
      assert delta.symbol == "BTC-USD"
      assert [{:bid, price, quantity}] = delta.levels
      assert Decimal.equal?(price, Decimal.new("79478.0"))
      # `new_quantity: "0"` is the venue's own removal signal — see the moduledoc's
      # "A zero quantity means the level ceased to exist".
      assert Decimal.equal?(quantity, Decimal.new("0"))
      assert delta.timestamp == ~U[2026-08-28 14:53:46.600000Z]
    end
  end

  describe "heartbeats channel — HeartbeatEnvelope (at-async.json)" do
    test "a genuine heartbeat frame is a no-op, not a crash" do
      assert {:ok, state} = frame!("websocket/heartbeats.json")
      assert state.delivering == MapSet.new()
      refute_received {:dp_exchange, :coinbase, _anything}
    end
  end

  describe "status channel — a genuine vendor-shaped frame this package never subscribes to" do
    test "StatusEnvelope/ProductStatus is recognised by the catch-all as a data_quality notice" do
      assert {:ok, _state} = frame!("websocket/status_unsubscribed.json")

      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = notice}
      assert notice.details.channel == "status"
    end
  end
end

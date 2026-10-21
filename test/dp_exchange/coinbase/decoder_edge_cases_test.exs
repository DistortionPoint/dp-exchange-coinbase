defmodule DpExchange.Coinbase.DecoderEdgeCasesTest do
  @moduledoc """
  Table-driven edge cases for the venue payload decoders, and the fake-versus-real parity
  checks that can be driven without a network.

  Every payload here PARSES and every number in it is real; what is wrong is the
  combination: the same entry twice, a bar that cannot have traded, a balance below zero.
  Each used to come back as a plausible value. Each is now a refusal or an unstated `nil`.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Fake, Rest}
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

  @shape {:error, :unexpected_response_shape}

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp opts(body), do: [plug: responding(body), retry_attempts: 0]
  defp private_opts(body), do: [credentials: @credentials] ++ opts(body)

  describe "candles" do
    defp bar(start, overrides \\ %{}) do
      Map.merge(
        %{
          "start" => to_string(start),
          "open" => "10",
          "high" => "12",
          "low" => "9",
          "close" => "11",
          "volume" => "3"
        },
        overrides
      )
    end

    test "two bars opened at the same instant refuse the series" do
      body = %{"candles" => [bar(1_700_000_000), bar(1_700_000_000, %{"close" => "10.5"})]}

      assert @shape == Rest.get_historical_prices("BTC-USD", "1m", [], opts(body))
    end

    test "the same bucket start spelled as a string and as a number is still a duplicate" do
      as_number = Map.put(bar(1_700_000_000), "start", 1_700_000_000)
      body = %{"candles" => [bar(1_700_000_000), as_number]}

      assert @shape == Rest.get_historical_prices("BTC-USD", "1m", [], opts(body))
    end

    test "a bar that cannot have traded is refused, however well each number parses" do
      impossible = [
        {"high below low", %{"high" => "8", "low" => "9"}},
        {"open above high", %{"open" => "13"}},
        {"open below low", %{"open" => "8"}},
        {"close above high", %{"close" => "13"}},
        {"close below low", %{"close" => "8"}}
      ]

      for {label, overrides} <- impossible do
        body = %{"candles" => [bar(1_700_000_000, overrides)]}

        assert @shape == Rest.get_historical_prices("BTC-USD", "1m", [], opts(body)),
               "#{label} was accepted"
      end
    end

    test "a bar whose open and close sit exactly on its high and low is a real bar" do
      body = %{"candles" => [bar(1_700_000_000, %{"open" => "9", "close" => "12"})]}

      assert {:ok, [%Types.Candle{}]} =
               Rest.get_historical_prices("BTC-USD", "1m", [], opts(body))
    end

    test "missing, empty, wrong-typed and non-positive fields are refused" do
      broken = [
        {"no open", Map.delete(bar(1_700_000_000), "open")},
        {"empty high", bar(1_700_000_000, %{"high" => ""})},
        {"boolean low", bar(1_700_000_000, %{"low" => true})},
        {"list close", bar(1_700_000_000, %{"close" => ["1"]})},
        {"zero open", bar(1_700_000_000, %{"open" => "0", "low" => "0"})},
        {"negative low", bar(1_700_000_000, %{"low" => "-1"})},
        {"absurd high", bar(1_700_000_000, %{"high" => "1e999999999"})},
        {"no start", Map.delete(bar(1_700_000_000), "start")},
        {"zero start", bar(0)},
        {"nanosecond start", bar(1_700_000_000_000_000_000)}
      ]

      for {label, row} <- broken do
        body = %{"candles" => [row]}

        assert {:error, _reason} = Rest.get_historical_prices("BTC-USD", "1m", [], opts(body)),
               "#{label} was accepted"
      end
    end

    test "a start that is not epoch seconds is refused as undated, never read in another unit" do
      # Seconds is the venue's unit; a millisecond or microsecond value is out of
      # `DateTime.from_unix/1`'s range and must be refused by name, not raise and not be
      # rescaled by magnitude. Zero and negative would otherwise quietly become 1970.
      starts = [
        1_700_000_000_000,
        1_700_000_000_000_000,
        "1700000000000",
        0,
        -1,
        "-1700000000",
        "1700000000.5",
        "2023-11-14T22:13:20Z"
      ]

      for start <- starts do
        body = %{"candles" => [Map.put(bar(1_700_000_000), "start", start)]}

        assert {:error, :missing_venue_timestamp} ==
                 Rest.get_historical_prices("BTC-USD", "1m", [], opts(body)),
               "start #{inspect(start)} was not refused as undated"
      end
    end

    test "bars sent newest first come back oldest first" do
      body = %{"candles" => [bar(1_700_000_120), bar(1_700_000_000), bar(1_700_000_060)]}

      assert {:ok, bars} = Rest.get_historical_prices("BTC-USD", "1m", [], opts(body))

      assert Enum.map(bars, &DateTime.to_unix(&1.opened_at)) ==
               [1_700_000_000, 1_700_000_060, 1_700_000_120]
    end
  end

  describe "the tape" do
    defp print(id, overrides \\ %{}) do
      Map.merge(
        %{
          "trade_id" => id,
          "price" => "100",
          "size" => "1",
          "time" => "2026-08-28T14:53:45Z",
          "side" => "BUY"
        },
        overrides
      )
    end

    test "one trade id twice refuses the tape, even when the copies disagree" do
      for second <- [print("t-1"), print("t-1", %{"price" => "101"})] do
        body = %{"trades" => [print("t-1"), second]}

        assert @shape == Rest.get_trades("BTC-USD", [limit: 10] ++ opts(body))
      end
    end

    test "distinct ids at the same instant are two prints" do
      body = %{"trades" => [print("t-1"), print("t-2")]}

      assert {:ok, [_one, _two]} = Rest.get_trades("BTC-USD", [limit: 10] ++ opts(body))
    end

    test "zero and negative sizes and prices, and an unknown side, are handled" do
      bad = [%{"size" => "0"}, %{"size" => "-1"}, %{"price" => "0"}, %{"price" => "-5"}]

      for overrides <- bad do
        body = %{"trades" => [print("t-1", overrides)]}

        assert {:error, _reason} = Rest.get_trades("BTC-USD", [limit: 10] ++ opts(body))
      end

      body = %{"trades" => [print("t-1", %{"side" => "SIDEWAYS"})]}

      assert {:ok, [%Types.Trade{side: nil}]} =
               Rest.get_trades("BTC-USD", [limit: 10] ++ opts(body))
    end
  end

  describe "the order book" do
    defp book(bids, asks) do
      %{
        "pricebook" => %{
          "product_id" => "BTC-USD",
          "time" => "2026-08-28T14:53:45Z",
          "bids" => bids,
          "asks" => asks
        }
      }
    end

    test "two rows at one price on a side refuse the book, however the price is spelled" do
      row = fn price, size -> %{"price" => price, "size" => size} end

      for {bids, asks} <- [
            {[row.("100", "1"), row.("100", "2")], [row.("101", "1")]},
            {[row.("100.0", "1"), row.("100.00", "1")], [row.("101", "1")]},
            {[row.("100", "1")], [row.("101", "1"), row.("101", "1")]}
          ] do
        assert @shape == Rest.get_order_book("BTC-USD", opts(book(bids, asks)))
      end
    end

    test "the same price on both sides is a crossed book, not a duplicate" do
      row = [%{"price" => "100", "size" => "1"}]

      assert {:ok, %Types.OrderBook{bids: [_bid], asks: [_ask]}} =
               Rest.get_order_book("BTC-USD", opts(book(row, row)))
    end

    test "missing, empty and wrong-typed price or size refuse the book" do
      for level <- [
            %{"price" => "100"},
            %{"size" => "1"},
            %{"price" => "", "size" => "1"},
            %{"price" => "100", "size" => ""},
            %{"price" => 100, "size" => true},
            %{"price" => "-1", "size" => "1"},
            %{"price" => "100", "size" => "-1"},
            %{"price" => "NaN", "size" => "1"}
          ] do
        assert {:error, _reason} =
                 Rest.get_order_book("BTC-USD", opts(book([level], [])))
      end
    end
  end

  describe "the catalogue" do
    defp product(id, overrides \\ %{}) do
      Map.merge(
        %{"product_id" => id, "price" => "10", "status" => "online", "product_type" => "SPOT"},
        overrides
      )
    end

    test "the same row twice is one product" do
      body = %{"products" => [product("BTC-USD"), product("ETH-USD"), product("BTC-USD")]}

      assert {:ok, ["BTC-USD", "ETH-USD"]} = Rest.get_symbols(opts(body))
      assert {:ok, overview} = Rest.get_market_overview(opts(body))
      assert Map.keys(overview) == ["BTC-USD", "ETH-USD"]
      assert {:ok, [_btc, _eth]} = Rest.list_instruments(opts(body))
    end

    test "two rows that disagree about one product refuse the catalogue" do
      for second <- [product("BTC-USD", %{"price" => "11"}), product("btc-usd")] do
        body = %{"products" => [product("BTC-USD"), second]}

        assert @shape == Rest.get_symbols(opts(body))
        assert @shape == Rest.get_market_overview(opts(body))
        assert @shape == Rest.list_instruments(opts(body))
        assert @shape == Rest.get_alias_map(opts(body))
      end
    end

    test "a pagination.has_next that is not a boolean is not the last page" do
      # `"true"` read as "no more" returned the first page as the whole catalogue.
      for flag <- ["true", 1, %{}] do
        body = %{
          "products" => [product("BTC-USD")],
          "pagination" => %{"has_next" => flag, "next_cursor" => "page2"}
        }

        assert @shape == Rest.get_symbols(opts(body)), "has_next #{inspect(flag)}"
        assert @shape == Rest.list_instruments(opts(body))
      end

      done = %{"products" => [product("BTC-USD")], "pagination" => %{"has_next" => false}}
      assert {:ok, ["BTC-USD"]} = Rest.get_symbols(opts(done))
    end

    test "an overview price, high or low at or below zero is not stated, nor a negative volume" do
      body = %{
        "products" => [
          product("BTC-USD", %{
            "price" => "0",
            "high_24h" => "-4",
            "low_24h" => "0",
            "volume_24h" => "-10",
            "price_percentage_change_24h" => "-1.5"
          })
        ]
      }

      assert {:ok, %{"BTC-USD" => row}} = Rest.get_market_overview(opts(body))
      assert row.price == nil
      assert row.high_24h == nil
      assert row.low_24h == nil
      assert row.volume_24h == nil
      # A fall is a real number; only the three above have no negative reading.
      assert Decimal.equal?(row.price_change_24h_pct, Decimal.new("-1.5"))
    end

    test "a zero volume is a real answer" do
      body = %{"products" => [product("BTC-USD", %{"volume_24h" => "0"})]}

      assert {:ok, %{"BTC-USD" => %{volume_24h: volume}}} = Rest.get_market_overview(opts(body))
      assert Decimal.equal?(volume, 0)
    end
  end

  describe "fills" do
    defp fill(overrides \\ %{}) do
      Map.merge(
        %{
          "entry_id" => "e-1",
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

    test "a row repeated byte for byte refuses the history" do
      body = %{"fills" => [fill(), fill()], "cursor" => ""}

      assert @shape == Rest.get_trade_history(@credentials, opts(body))
    end

    test "a fill and its reversal, which share a trade id, are two rows" do
      body = %{
        "fills" => [fill(), fill(%{"trade_type" => "REVERSAL", "entry_id" => "e-2"})],
        "cursor" => ""
      }

      assert {:ok, [_fill]} = Rest.get_trade_history(@credentials, opts(body))

      both = [trade_types: ["FILL", "REVERSAL"]] ++ opts(body)
      assert {:ok, [_fill, _reversal]} = Rest.get_trade_history(@credentials, both)
    end
  end

  describe "orders" do
    test "one order id listed twice refuses the list" do
      row = %{
        "order_id" => "o-1",
        "product_id" => "BTC-USD",
        "side" => "BUY",
        "order_type" => "LIMIT",
        "time_in_force" => "GOOD_UNTIL_CANCELLED",
        "status" => "OPEN",
        "order_configuration" => %{
          "limit_limit_gtc" => %{"base_size" => "1.0", "limit_price" => "40000"}
        },
        "filled_size" => "0.25",
        "average_filled_price" => "40100.5",
        "total_fees" => "1.20",
        "created_time" => "2026-08-31T12:00:00Z"
      }

      body = %{"orders" => [row, row], "has_next" => false}

      assert @shape == Rest.get_orders(@credentials, opts(body))
      assert {:ok, [_one]} = Rest.get_orders(@credentials, opts(%{body | "orders" => [row]}))
    end
  end

  describe "balances" do
    defp account(overrides) do
      Map.merge(
        %{
          "uuid" => "u-1",
          "currency" => "BTC",
          "available_balance" => %{"value" => "1.5", "currency" => "BTC"},
          "hold" => %{"value" => "0.5", "currency" => "BTC"}
        },
        overrides
      )
    end

    test "a negative available balance or hold is not stated, and leaves the total unstated" do
      for field <- ["available_balance", "hold"] do
        body = %{
          "accounts" => [account(%{field => %{"value" => "-1", "currency" => "BTC"}})],
          "has_next" => false
        }

        assert {:ok, [balance]} = Rest.get_balances(@credentials, opts(body))
        assert balance.balance == nil
      end
    end

    test "zero is a balance" do
      body = %{
        "accounts" => [account(%{"available_balance" => %{"value" => "0"}})],
        "has_next" => false
      }

      assert {:ok, [balance]} = Rest.get_balances(@credentials, opts(body))
      assert Decimal.equal?(balance.available_balance, 0)
      assert Decimal.equal?(balance.balance, Decimal.new("0.5"))
    end

    test "the same account row twice refuses the list, and a different one does not" do
      same = %{"accounts" => [account(%{}), account(%{})], "has_next" => false}
      other = %{"accounts" => [account(%{}), account(%{"uuid" => "u-2"})], "has_next" => false}

      assert @shape == Rest.get_balances(@credentials, opts(same))
      assert {:ok, [_one, _two]} = Rest.get_balances(@credentials, opts(other))
    end
  end

  describe "the fake answers what the real path answers, for the same input" do
    test "a depth the real path accepts returns a book instead of building two billion levels" do
      assert :ok = Rest.validate_book_options(depth: 2_000_000_000)

      assert {:ok, %Types.OrderBook{bids: bids, asks: asks}} =
               Fake.get_order_book("BTC-USD", depth: 2_000_000_000)

      assert length(bids) == 50
      assert length(asks) == 50
    end

    test "a malformed credential is refused by the catalogue reads on both sides" do
      padded = %{api_key: "k ", api_secret: "s"}

      for bad <- [%{api_key: "k"}, %{api_key: " ", api_secret: "s"}, padded] do
        for {fake, real} <- [
              {&Fake.get_symbols/1, &Rest.get_symbols/1},
              {&Fake.get_market_overview/1, &Rest.get_market_overview/1},
              {&Fake.list_instruments/1, &Rest.list_instruments/1}
            ] do
          from_real = real.([credentials: bad] ++ opts(%{"products" => []}))

          assert {:error, {code, :coinbase}} = from_real
          assert code in [:missing_credentials, :invalid_credentials]
          assert fake.(credentials: bad) == from_real
        end
      end
    end

    test "no credential, and an empty one, take the public path on both sides" do
      test_pid = self()

      reporting = fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        send(test_pid, {:requested, conn.request_path, auth})
        responding(%{"products" => []}).(conn)
      end

      for creds <- [nil, %{}] do
        assert {:ok, _symbols} = Fake.get_symbols(credentials: creds)
        assert {:ok, _overview} = Fake.get_market_overview(credentials: creds)
        assert {:ok, _instruments} = Fake.list_instruments(credentials: creds)

        # The real side: the public path, and no token on the wire.
        assert {:ok, _real} =
                 Rest.get_symbols(credentials: creds, plug: reporting, retry_attempts: 0)

        assert_received {:requested, path, authorization}
        assert String.ends_with?(path, "/market/products")
        assert authorization == []
      end

      assert {:ok, _symbols} = Fake.get_symbols(credentials: @credentials)
      assert {:ok, _symbols} = Rest.get_symbols(private_opts(%{"products" => []}))
    end
  end
end

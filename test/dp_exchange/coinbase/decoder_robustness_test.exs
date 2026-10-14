defmodule DpExchange.Coinbase.DecoderRobustnessTest do
  @moduledoc """
  Hostile and malformed venue payloads (REST bodies and WebSocket frames).

  Every case here is a value that PARSES cleanly and is still not what the field means: a
  negative size, a price of nothing, a string where a boolean belongs, a map where an id
  belongs, a venue reason as long as an error page. Each used to be carried through as a
  plausible value (or, for a frame that is not a map, dropped without a word); each is now a
  refusal, a `nil` ("not stated") or an observable notice.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Rest, Socket}
  alias DpExchange.Core.{Config, Notice, Types}

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

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp opts(body), do: [plug: responding(body), retry_attempts: 0]
  defp private_opts(body), do: [credentials: @credentials] ++ opts(body)

  defp fill(overrides) do
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

  defp tape_trade(overrides) do
    Map.merge(
      %{
        "trade_id" => "42",
        "product_id" => "BTC-USD",
        "price" => "85701.9",
        "size" => "0.5",
        "time" => "2026-10-02T14:54:03.341087Z",
        "side" => "BUY"
      },
      overrides
    )
  end

  defp position_row(overrides) do
    Map.merge(
      %{
        "product_id" => "BIT-28JUL23-CDE",
        "side" => "SHORT",
        "number_of_contracts" => "3",
        "current_price" => "29500",
        "avg_entry_price" => "30000",
        "unrealized_pnl" => "1500"
      },
      overrides
    )
  end

  defp order_json(overrides) do
    Map.merge(
      %{
        "order_id" => "abc-123",
        "product_id" => "BTC-USD",
        "side" => "BUY",
        "order_type" => "LIMIT",
        "time_in_force" => "GOOD_UNTIL_CANCELLED",
        "status" => "OPEN",
        "order_configuration" => %{
          "limit_limit_gtc" => %{"base_size" => "1.0", "limit_price" => "40000"}
        },
        "filled_size" => "0.25",
        "average_filled_price" => "40100.5"
      },
      overrides
    )
  end

  defp limit_request do
    %{
      symbol: "BTC-USD",
      side: :buy,
      quantity: Decimal.new("0.5"),
      price: Decimal.new("40000"),
      order_type: :limit,
      time_in_force: :gtc
    }
  end

  describe "a fill that is not an execution" do
    test "a size of zero or less is refused" do
      for bad <- ["0", "-1", "-0.5"] do
        body = %{"fills" => [fill(%{"size" => bad})], "cursor" => ""}

        assert {:error, {:non_positive_quantity, :quantity, ^bad}} =
                 Rest.get_trade_history(@credentials, opts(body))
      end
    end

    test "a price of zero or less is refused" do
      for bad <- ["0", "-5"] do
        body = %{"fills" => [fill(%{"price" => bad})], "cursor" => ""}

        assert {:error, {:non_positive_price, :price, ^bad}} =
                 Rest.get_trade_history(@credentials, opts(body))
      end
    end

    test "a trade_id that is not a string is refused, and an absent one is kept absent" do
      for bad <- [7, %{"a" => 1}, [1], 1.5] do
        body = %{"fills" => [fill(%{"trade_id" => bad})], "cursor" => ""}

        assert {:error, :unexpected_response_shape} =
                 Rest.get_trade_history(@credentials, opts(body))
      end

      body = %{"fills" => [fill(%{"trade_id" => nil})], "cursor" => ""}

      assert {:ok, [%Types.Fill{trade_id: nil}]} =
               Rest.get_trade_history(@credentials, opts(body))
    end
  end

  describe "the public tape" do
    test "a print of zero or negative size is refused" do
      for bad <- ["0", "-2"] do
        body = %{"trades" => [tape_trade(%{"size" => bad})]}

        assert {:error, {:non_positive_quantity, :quantity, ^bad}} =
                 Rest.get_trades("BTC-USD", [limit: 5] ++ opts(body))
      end
    end

    test "a trade_id that is not a string is refused, as the stream refuses it" do
      for bad <- [7, %{"a" => 1}, [1]] do
        body = %{"trades" => [tape_trade(%{"trade_id" => bad})]}

        assert {:error, :unexpected_response_shape} =
                 Rest.get_trades("BTC-USD", [limit: 5] ++ opts(body))
      end
    end

    test "a negative size on the newest print is no volume, not a negative one" do
      newest = %{"time" => "2026-10-02T14:54:03Z", "price" => "100", "size" => "-3"}
      body = %{"trades" => [newest]}

      assert {:ok, %Types.Quote{volume: nil, volume_window: nil}} =
               Rest.get_price("BTC-USD", opts(body))
    end
  end

  describe "candles" do
    test "a negative volume is not stated, never carried" do
      body = %{
        "candles" => [
          %{
            "start" => "1700000000",
            "open" => "1",
            "high" => "2",
            "low" => "0.5",
            "close" => "1.5",
            "volume" => "-10"
          }
        ]
      }

      assert {:ok, [%Types.Candle{volume: nil}]} =
               Rest.get_historical_prices("BTC-USD", "1m", [], opts(body))
    end
  end

  describe "top of book" do
    test "a best price of zero or less, or a negative size, is refused" do
      for {price, size} <- [{"-5", "1"}, {"0", "1"}, {"10", "-1"}] do
        body = %{
          "pricebooks" => [
            %{
              "product_id" => "BTC-USD",
              "bids" => [%{"price" => price, "size" => size}],
              "asks" => [%{"price" => "11", "size" => "1"}]
            }
          ]
        }

        assert {:error, :unexpected_response_shape} =
                 Rest.get_top_of_book("BTC-USD", private_opts(body))
      end
    end
  end

  describe "positions" do
    test "a product id that is not a non-blank string is refused" do
      for bad <- [123, "", "   ", %{"a" => 1}] do
        body = %{"positions" => [position_row(%{"product_id" => bad})]}

        assert {:error, {:missing_required_field, :symbol}} =
                 Rest.get_positions(@credentials, opts(body))
      end
    end

    test "the raw listing refuses a row that is not an object" do
      body = %{"positions" => [position_row(%{}), 5]}

      assert {:error, :unexpected_response_shape} =
               Rest.list_futures_positions(@credentials, opts(body))
    end
  end

  describe "raw row lists are lists of objects" do
    test "payment methods, sweeps and accounts refuse an entry that is not a map" do
      assert {:error, :unexpected_response_shape} =
               Rest.list_payment_methods(@credentials, opts(%{"payment_methods" => [1]}))

      assert {:error, :unexpected_response_shape} =
               Rest.list_futures_sweeps(@credentials, opts(%{"sweeps" => ["x", nil]}))

      assert {:error, :unexpected_response_shape} =
               Rest.get_accounts(@credentials, opts(%{"accounts" => [5], "has_next" => false}))
    end
  end

  describe "portfolios" do
    test "a deleted flag that is not a boolean is refused, not truthy" do
      for bad <- ["false", "0", 1, %{}] do
        body = %{"portfolios" => [%{"uuid" => "pf-1", "name" => "A", "deleted" => bad}]}

        assert {:error, :unexpected_response_shape} =
                 Rest.list_portfolios(@credentials, opts(body))
      end
    end

    test "a name or type that is not a string is refused" do
      for field <- ["name", "type"] do
        body = %{"portfolios" => [%{"uuid" => "pf-1", field => 5}]}

        assert {:error, :unexpected_response_shape} =
                 Rest.list_portfolios(@credentials, opts(body))
      end
    end
  end

  describe "previews" do
    test "an errs that is present and not a list is unreadable, not a green light" do
      for bad <- ["INSUFFICIENT_FUND", %{"a" => 1}, 7] do
        body = %{"errs" => bad, "order_total" => "1"}

        assert {:error, :unexpected_response_shape} =
                 Rest.preview_order(@credentials, limit_request(), private_opts(body))
      end
    end

    test "an edit preview's errors that is present and not a list is unreadable" do
      changes = %{price: Decimal.new("40000"), quantity: Decimal.new("1")}

      for bad <- ["BAD", %{"a" => 1}] do
        body = %{"errors" => bad}

        assert {:error, :unexpected_response_shape} =
                 Rest.preview_replace(@credentials, "abc-123", changes, opts(body))
      end
    end
  end

  describe "the catalogue" do
    test "a product with a blank name is skipped, not listed as the symbol \"\"" do
      body = %{
        "products" => [
          %{"product_id" => ""},
          %{"product_id" => "   "},
          %{"product_id" => "BTC-USD"}
        ]
      }

      assert {:ok, ["BTC-USD"]} = Rest.get_symbols(opts(body))
    end

    test "a base or quote that is not a string is not stated" do
      body = %{
        "products" => [
          %{
            "product_id" => "BTC-USD",
            "base_currency_id" => 5,
            "quote_currency_id" => %{"a" => 1},
            "product_type" => "SPOT",
            "status" => "online"
          }
        ]
      }

      assert {:ok, [instrument]} = Rest.list_instruments(opts(body))
      assert instrument.base == nil
      assert instrument.quote == nil
    end

    test "an overview status that is not a string is not stated" do
      body = %{"products" => [%{"product_id" => "BTC-USD", "price" => "1", "status" => %{}}]}

      assert {:ok, %{"BTC-USD" => %{status: nil}}} = Rest.get_market_overview(opts(body))
    end
  end

  describe "an order read back" do
    test "negative sizes and prices are not stated" do
      order =
        order_json(%{
          "filled_size" => "-1",
          "order_configuration" => %{
            "limit_limit_gtc" => %{"base_size" => "-2", "limit_price" => "-3"}
          }
        })

      assert {:ok, read} = Rest.get_order(@credentials, "abc-123", opts(%{"order" => order}))
      assert read.quantity == nil
      assert read.price == nil
      assert read.filled_quantity == nil
      assert read.average_price == nil
    end

    test "a JSON float with an absurd exponent is not stated" do
      # `1.0e300` is finite and parsed as a Decimal with exponent 300, past the 64 places
      # every string already stops at.
      body = ~s({"order": #{Jason.encode!(order_json(%{}))}})
      body = String.replace(body, ~s("filled_size":"0.25"), ~s("filled_size":1.0e300))

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, body)
      end

      assert {:ok, read} = Rest.get_order(@credentials, "abc-123", plug: plug, retry_attempts: 0)
      assert read.filled_quantity == nil
    end
  end

  describe "a venue reason is bounded" do
    test "a cancel's failure_reason is cut, and a non-string one is unreadable" do
      long = String.duplicate("X", 10_000)

      body = %{
        "results" => [%{"order_id" => "abc-123", "success" => false, "failure_reason" => long}]
      }

      assert {:refused, {:cancel_rejected, reason}} =
               Rest.cancel_order(@credentials, "abc-123", opts(body))

      assert String.length(reason) == 2_048

      body = %{
        "results" => [
          %{"order_id" => "abc-123", "success" => false, "failure_reason" => %{"a" => 1}}
        ]
      }

      assert {:error, :unexpected_response_shape} =
               Rest.cancel_order(@credentials, "abc-123", opts(body))
    end

    test "a placement's rejection reason is cut" do
      long = String.duplicate("Y", 10_000)
      body = %{"success" => false, "error_response" => %{"new_order_failure_reason" => long}}

      assert {:refused, {:order_rejected, reason}} =
               Rest.place_order(@credentials, limit_request(), opts(body))

      assert String.length(reason) == 2_048
    end
  end

  describe "WebSocket frames" do
    defp state do
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

    defp frame(payload) when is_binary(payload),
      do: Socket.handle_frame({:text, payload}, state())

    defp frame(payload), do: frame(Jason.encode!(payload))

    defp trades_frame(trade) do
      %{
        "channel" => "market_trades",
        "timestamp" => "2026-10-02T14:54:03.464172Z",
        "events" => [%{"type" => "update", "trades" => [trade]}]
      }
    end

    test "a streamed trade of zero or negative size is reported and not delivered" do
      for bad <- ["0", "-1"] do
        assert {:ok, _state} = frame(trades_frame(tape_trade(%{"size" => bad})))

        assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = notice}
        assert notice.details.channel == :market_trades
        refute_received {:dp_exchange, :coinbase, %Types.Trade{}}
      end
    end

    test "a negative 24-hour volume on a ticker is not stated" do
      ticker = %{"product_id" => "BTC-USD", "price" => "100", "volume_24_h" => "-5"}

      frame = %{
        "channel" => "ticker",
        "timestamp" => "2026-10-02T14:54:03Z",
        "events" => [%{"type" => "update", "tickers" => [ticker]}]
      }

      assert {:ok, _state} = frame(frame)
      assert_received {:dp_exchange, :coinbase, %Types.Quote{volume: nil, volume_window: nil}}
    end

    test "a subscribed channel whose events is not a list is reported, not dropped" do
      for {channel, label} <- [
            {"ticker", :ticker},
            {"l2_data", :level2},
            {"market_trades", :market_trades}
          ],
          events <- [nil, "x", %{"a" => 1}] do
        assert {:ok, _state} = frame(%{"channel" => channel, "events" => events})

        assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = notice}
        assert notice.details.channel == label
        assert notice.details.reason == :unexpected_event
      end
    end

    test "a frame that is JSON but not an object is reported, not dropped" do
      for payload <- ["[1,2,3]", "42", "\"text\"", "null", "true"] do
        assert {:ok, _state} = frame(payload)

        assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = notice}
        assert notice.details.channel == :frame
        assert notice.details.reason == :unexpected_frame
        assert String.length(notice.details.payload) <= 120
      end
    end

    test "a heartbeat and an acknowledgement are still silent" do
      for channel <- ["heartbeats", "subscriptions"] do
        assert {:ok, _state} = frame(%{"channel" => channel, "events" => []})
        refute_received {:dp_exchange, :coinbase, %Notice{}}
      end
    end
  end
end

defmodule DpExchange.Coinbase.RestBranchesTest do
  @moduledoc """
  `Rest` branches no other test reached: how a venue's non-success answers are classified on
  reads, answers whose shape is wrong, values that are present but unreadable, the order
  fields only some requests carry, and an id that is a path segment.

  Everything is decided against a plug; nothing leaves the process.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Rest
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

  defp responding(body, status) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  # The options every call here shares: the answer, and no retry of it.
  defp answering(body, status \\ 200), do: [plug: responding(body, status), retry_attempts: 0]

  defp limit_request(overrides \\ %{}) do
    Map.merge(
      %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        price: Decimal.new("40000"),
        order_type: :limit,
        time_in_force: :gtc
      },
      overrides
    )
  end

  describe "the alias map" do
    test "a market the catalogue lists from both sides is one entry each way" do
      body = %{
        "products" => [
          %{"product_id" => "XLM-USDC", "alias" => "XLM-USD"},
          %{"product_id" => "XLM-USD", "alias" => "XLM-USDC"}
        ]
      }

      assert {:ok, map} = Rest.get_alias_map(answering(body))
      assert map == %{"XLM-USDC" => ["XLM-USD"], "XLM-USD" => ["XLM-USDC"]}
    end
  end

  describe "how a read classifies what the venue answers" do
    test "a 404 on a single account is a refusal that names no symbol" do
      opts = [uuid: "no-such-account"] ++ answering(%{"message" => "gone"}, 404)

      assert {:refused, :not_found} = Rest.get_accounts(@credentials, opts)
    end

    test "a 404 on a symbol read is :not_listed, on every symbol read" do
      opts = answering(%{"message" => "gone"}, 404)

      assert {:refused, :not_listed} = Rest.get_product("BTC-USD", opts)
      assert {:refused, :not_listed} = Rest.get_trades("BTC-USD", [limit: 5] ++ opts)
      assert {:refused, :not_listed} = Rest.get_order_book("BTC-USD", opts)
    end

    test "the venue's own words ride in the refusal" do
      opts = answering(%{"error_details" => "bad key"}, 401)

      assert {:refused, {:venue_error, 401, "bad key"}} = Rest.get_server_time(opts)
    end

    test "a refusal the venue gave no words for is still a refusal" do
      opts = answering(%{"other" => 1}, 401)

      assert {:refused, {:venue_error, 401}} = Rest.get_server_time(opts)
    end

    test "a 4xx that is neither a refusal nor a missing thing may be transient: an error" do
      opts = answering(%{"message" => "x"}, 409)

      assert {:error, {:exchange_error, :coinbase, "HTTP 409: " <> _body}} =
               Rest.get_server_time(opts)
    end

    test "orders, previews and edit previews classify the same way" do
      opts = answering(%{"message" => "no"}, 401)
      edit = %{price: Decimal.new("1"), quantity: Decimal.new("1")}

      assert {:refused, {:venue_error, 401, "no"}} = Rest.get_orders(@credentials, opts)

      assert {:refused, {:venue_error, 401, "no"}} =
               Rest.preview_order(@credentials, limit_request(), opts)

      assert {:refused, {:venue_error, 401, "no"}} =
               Rest.preview_replace(@credentials, "order-1", edit, opts)
    end
  end

  describe "an answer whose shape is wrong" do
    test "a time that is not an object" do
      assert {:error, :unexpected_response_shape} = Rest.get_server_time(answering(["no"]))
    end

    test "a margin window that is not an object" do
      opts = answering(["no"])

      assert {:error, :unexpected_response_shape} =
               Rest.get_current_margin_window(@credentials, opts)
    end

    test "an order preview that is not an object is unreadable, not an empty preview" do
      opts = answering(["no"])

      assert {:error, :unexpected_response_shape} =
               Rest.preview_order(@credentials, limit_request(), opts)
    end
  end

  describe "a value that is present and unreadable" do
    test "a trade time that is not text is refused, never replaced by now" do
      body = %{"trades" => [%{"time" => 123, "price" => "1", "size" => "1"}]}

      assert {:error, {:unparseable_venue_timestamp, 123}} =
               Rest.get_price("BTC-USD", answering(body))
    end

    test "a top-of-book time that cannot be read is nil, not a guess" do
      book = %{"product_id" => "BTC-USD", "bids" => [], "asks" => [], "time" => "not-a-time"}
      opts = [credentials: @credentials] ++ answering(%{"pricebooks" => [book]})

      assert {:ok, %Types.TopOfBook{} = top} = Rest.get_top_of_book("BTC-USD", opts)
      assert top.venue_time == nil
      assert top.bid == nil
      assert top.ask == nil
    end

    test "a portfolio id the venue sends as a number is its decimal text" do
      body = %{"portfolios" => [%{"uuid" => 7, "name" => "Default", "type" => "DEFAULT"}]}

      assert {:ok, [%Types.Portfolio{id: "7"}]} =
               Rest.list_portfolios(@credentials, answering(body))
    end

    test "an order whose configuration holds something other than a leaf has no size" do
      order = %{
        "order_id" => "abc-123",
        "product_id" => "BTC-USD",
        "side" => "BUY",
        "order_type" => "LIMIT",
        "status" => "OPEN",
        "order_configuration" => %{"limit_limit_gtc" => "not-a-leaf"},
        "created_time" => "2026-08-31T12:00:00Z"
      }

      opts = answering(%{"order" => order})

      assert {:ok, %Types.Order{} = read} = Rest.get_order(@credentials, "abc-123", opts)
      assert read.quantity == nil
    end

    test "an order status filter that is neither a word nor an atom is refused" do
      assert {:error, {:invalid_status, 5}} = Rest.validate_order_filters(status: 5)
    end
  end

  describe "what the order request may carry" do
    test "margin_type :cross is the venue's CROSS" do
      assert {:ok, plan} = Rest.order_plan(limit_request(%{margin_type: :cross}), :place)

      assert plan.margin == %{"margin_type" => "CROSS"}
    end

    test "a stop direction already in the venue's spelling is sent as given" do
      request =
        limit_request(%{
          order_type: :stop_limit,
          stop_price: Decimal.new("39000"),
          stop_direction: "STOP_DIRECTION_STOP_UP"
        })

      assert {:ok, plan} = Rest.order_plan(request, :place)

      leaf = plan.configuration["stop_limit_stop_limit_gtc"]
      assert leaf["stop_direction"] == "STOP_DIRECTION_STOP_UP"
    end
  end

  describe "closing a position" do
    test "the venue saying the client order id was used before is unconfirmed, with the id" do
      # The earlier attempt of this same call may be the one that closed it; "rejected" would
      # tell the caller nothing happened.
      body = %{
        "success" => false,
        "error_response" => %{"new_order_failure_reason" => "DUPLICATE_CLIENT_ORDER_ID"}
      }

      opts = [client_order_id: "close-1"] ++ answering(body)

      assert {:error, {:order_unconfirmed, "close-1", :duplicate_client_order_id}} =
               Rest.close_position(@credentials, "BTC-USD", opts)
    end
  end

  describe "an id that is a path segment" do
    test "a single dot is escaped rather than navigated" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"position" => %{}}))
      end

      opts = [plug: plug, retry_attempts: 0]

      assert {:ok, _position} = Rest.get_futures_position(@credentials, ".", opts)

      assert_receive {:path, path}, 5_000
      assert path == "/api/v3/brokerage/cfm/positions/%2E"
    end
  end
end

defmodule DpExchange.Coinbase.PositionAndEditPreviewTest do
  @moduledoc """
  The two order endpoints this package had no facade for.

  Both are here because neither can be assembled from the calls that already exist, and the
  assertions worth the most are about what the package refuses to invent: a side the venue
  never states, and an `:ok` where the venue answered `200` with an error inside it.
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
    api_secret: "-----BEGIN EC PRIVATE KEY-----"
  }

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  describe "close_position/3 — the venue sizes it, not the caller" do
    test "a success returns the order the venue placed" do
      body = %{
        "success" => true,
        "success_response" => %{"order_id" => "close-1"},
        "order_configuration" => %{"market_market_ioc" => %{"base_size" => "3"}}
      }

      assert {:ok, %Types.Order{} = order} =
               Rest.close_position(@credentials, "BTC-USD",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert order.id == "close-1"
      assert order.symbol == "BTC-USD"
      assert order.status == :pending
      assert order.provider == :coinbase
    end

    test "the order type and time in force are read from the venue's echo, not assumed" do
      # The caller never states either. The venue's order_configuration key names both at
      # once, and that echo is the only statement of what this order is.
      body = %{
        "success" => true,
        "success_response" => %{"order_id" => "close-1"},
        "order_configuration" => %{"market_market_ioc" => %{"base_size" => "3"}}
      }

      assert {:ok, order} =
               Rest.close_position(@credentials, "BTC-USD",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert order.order_type == :market
      assert order.time_in_force == :ioc
      assert Decimal.equal?(order.quantity, Decimal.new("3"))
    end

    test "a configuration key this package does not know leaves both nil" do
      body = %{
        "success" => true,
        "success_response" => %{"order_id" => "close-1"},
        "order_configuration" => %{"twap_twap_gtd" => %{"base_size" => "3"}}
      }

      assert {:ok, order} =
               Rest.close_position(@credentials, "BTC-USD",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert order.order_type == nil
      assert order.time_in_force == nil
      # The size is still the venue's own number and is still readable.
      assert Decimal.equal?(order.quantity, Decimal.new("3"))
    end

    test "the side is nil, and stays nil" do
      # A closing order's side is the opposite of the position's, and this package never read
      # the position. `:sell` would be right most of the time, which is what makes it
      # dangerous: a short position closes with a buy and nothing here would say so.
      body = %{
        "success" => true,
        "success_response" => %{"order_id" => "close-1"},
        "order_configuration" => %{"market_market_ioc" => %{"base_size" => "3"}}
      }

      assert {:ok, order} =
               Rest.close_position(@credentials, "BTC-USD",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert order.side == nil
      refute order.side == :sell
    end

    test "a response with no configuration at all is still an order" do
      body = %{"success" => true, "success_response" => %{"order_id" => "close-1"}}

      assert {:ok, order} =
               Rest.close_position(@credentials, "BTC-USD",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert order.order_type == nil
      assert order.quantity == nil
    end

    test "a 200 saying success: false is a refusal, not a closed position" do
      body = %{"success" => false, "error_response" => %{"error" => "NO_OPEN_POSITION"}}

      assert {:refused, {:close_rejected, "NO_OPEN_POSITION"}} =
               Rest.close_position(@credentials, "BTC-USD",
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "an unreadable body is an error rather than a silent success" do
      assert {:error, :unexpected_response_shape} =
               Rest.close_position(@credentials, "BTC-USD",
                 plug: responding(%{}),
                 retry_attempts: 0
               )
    end

    test "size partial-closes when given, and is absent otherwise" do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"success" => false}))
      end

      Rest.close_position(@credentials, "BTC-USD", size: "2", plug: plug, retry_attempts: 0)
      assert_receive {:sent, %{"size" => "2", "product_id" => "BTC-USD"}}

      Rest.close_position(@credentials, "BTC-USD", plug: plug, retry_attempts: 0)
      assert_receive {:sent, sent}
      refute Map.has_key?(sent, "size")
    end

    test "a client order id is generated when the caller gives none" do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"success" => false}))
      end

      Rest.close_position(@credentials, "BTC-USD", plug: plug, retry_attempts: 0)
      assert_receive {:sent, %{"client_order_id" => generated}}
      assert is_binary(generated) and generated != ""
    end
  end

  describe "preview_replace/4 — pricing an amendment, not a fresh order" do
    test "it sends the edit body to the edit_preview path" do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, conn.request_path, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"errors" => []}))
      end

      assert {:ok, _preview} =
               Rest.preview_replace(@credentials, "abc-123", %{price: "41000"},
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:sent, path, sent}
      assert path =~ "edit_preview"
      assert sent == %{"order_id" => "abc-123", "price" => "41000"}
    end

    test "the venue's numbers come back, including the ones only an edit has" do
      body = %{
        "errors" => [],
        "order_total" => "20500.00",
        "commission_total" => "10.25",
        "base_size" => "0.5",
        "best_bid" => "40990",
        "best_ask" => "41010",
        "average_filled_price" => "40800",
        "order_margin_total" => "2050",
        "slippage" => "0.002"
      }

      assert {:ok, preview} =
               Rest.preview_replace(@credentials, "abc-123", %{price: "41000"},
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(preview.order_total, Decimal.new("20500.00"))
      # average_filled_price is the resting order's, and is the reason this is not
      # preview_order/3 with an id: a fresh order has no fills to average.
      assert Decimal.equal?(preview.average_filled_price, Decimal.new("40800"))
      assert Decimal.equal?(preview.order_margin_total, Decimal.new("2050"))
    end

    test "a 200 carrying errors is a refusal" do
      body = %{"errors" => [%{"edit_failure_reason" => "ORDER_ALREADY_FILLED"}]}

      assert {:refused, {:edit_preview_rejected, [%{"edit_failure_reason" => _reason}]}} =
               Rest.preview_replace(@credentials, "abc-123", %{price: "41000"},
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "an edit the venue does not support is refused before the request" do
      exploding = fn _conn -> raise "must not ask the venue to price an edit it refuses" end

      assert {:error, {:unsupported_order_edit, [:side]}} =
               Rest.preview_replace(@credentials, "abc-123", %{side: :sell},
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "an empty change set is an error, not a preview of nothing" do
      exploding = fn _conn -> raise "must not price an edit with nothing in it" end

      assert {:error, :no_order_changes} =
               Rest.preview_replace(@credentials, "abc-123", %{},
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "an unreadable body is an error" do
      plug = fn conn -> Plug.Conn.resp(conn, 200, "not json") end

      assert {:error, _reason} =
               Rest.preview_replace(@credentials, "abc-123", %{price: "1"},
                 plug: plug,
                 retry_attempts: 0
               )
    end
  end
end

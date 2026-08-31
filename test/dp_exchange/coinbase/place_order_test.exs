defmodule DpExchange.Coinbase.PlaceOrderTest do
  @moduledoc """
  Coinbase names the order type and the time-in-force in a single key, and the set of names
  is sparse. These assertions are about the pairs that do **not** exist.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Rest
  alias DpExchange.Core.{Config, Types}

  @moduletag :capture_log

  # The same process-scoped limiter seam the other suites use: a real module answering from
  # configuration, not a mock.
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

  defp responding(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp accepted, do: %{"success" => true, "success_response" => %{"order_id" => "abc-123"}}

  defp place(request, plug) do
    Rest.place_order(@credentials, request, plug: plug, retry_attempts: 0)
  end

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

  describe "the type/time-in-force pairs the venue does not name" do
    test "a limit IOC is refused rather than sent as the nearest key" do
      # There is no `limit_limit_ioc`. Sending `limit_limit_fok` instead would place an
      # order that fills-or-kills where the caller asked for immediate-or-cancel, and every
      # field in the request would look correct.
      assert {:error, {:unsupported_order_combination, :limit, :ioc}} =
               place(limit_request(%{time_in_force: :ioc}), responding(accepted()))
    end

    test "a market GTC is refused" do
      # A market order rests for no time at all; `market_market_gtc` does not exist and
      # would be meaningless if it did.
      assert {:error, {:unsupported_order_combination, :market, :gtc}} =
               place(
                 limit_request(%{order_type: :market, time_in_force: :gtc}),
                 responding(accepted())
               )
    end

    test "a stop-limit IOC is refused" do
      assert {:error, {:unsupported_order_combination, :stop_limit, :ioc}} =
               place(
                 limit_request(%{order_type: :stop_limit, time_in_force: :ioc}),
                 responding(accepted())
               )
    end

    test "the refusal happens before the request is sent" do
      # No HTTP call should be made for a pair the venue cannot accept. A plug that raises
      # proves it: if the refusal came from the response, this would blow up instead.
      exploding = fn _conn -> raise "the venue must not be called for an impossible pair" end

      assert {:error, {:unsupported_order_combination, :limit, :ioc}} =
               place(limit_request(%{time_in_force: :ioc}), exploding)
    end
  end

  describe "the pairs it does name" do
    test "a limit GTC is placed and comes back as an Order" do
      assert {:ok, %Types.Order{} = order} = place(limit_request(), responding(accepted()))

      assert order.id == "abc-123"
      assert order.symbol == "BTC-USD"
      assert order.side == :buy
      assert order.order_type == :limit
      assert order.time_in_force == :gtc
      assert order.status == :pending
      assert order.provider == :coinbase
    end

    test "every pair in the table builds a configuration the venue would accept" do
      pairs = [
        {:market, :ioc},
        {:market, :fok},
        {:limit, :gtc},
        {:limit, :gtd},
        {:limit, :fok},
        {:stop_limit, :gtc},
        {:stop_limit, :gtd}
      ]

      for {type, tif} <- pairs do
        request =
          limit_request(%{
            order_type: type,
            time_in_force: tif,
            stop_price: Decimal.new("39000")
          })

        assert {:ok, _order} = place(request, responding(accepted())),
               "#{type}/#{tif} is in the table but did not build"
      end
    end
  end

  describe "sizing and price are required, never defaulted" do
    test "a limit order with no price is an error" do
      request = limit_request() |> Map.delete(:price)

      assert {:error, :missing_limit_price} = place(request, responding(accepted()))
    end

    test "a stop-limit with no stop price is an error" do
      request =
        limit_request(%{order_type: :stop_limit}) |> Map.delete(:stop_price)

      assert {:error, :missing_stop_price} = place(request, responding(accepted()))
    end

    test "a market order with neither base nor quote size is an error" do
      request =
        limit_request(%{order_type: :market, time_in_force: :ioc}) |> Map.delete(:quantity)

      assert {:error, :missing_order_size} = place(request, responding(accepted()))
    end
  end

  describe "a 200 that says success: false is not a placed order" do
    test "a rejection is refused, not returned as an order" do
      # The HTTP call succeeded and the order did not. Reading the status code alone would
      # report a placed order that does not exist.
      body = %{
        "success" => false,
        "error_response" => %{"error" => "INSUFFICIENT_FUND"}
      }

      assert {:refused, {:order_rejected, "INSUFFICIENT_FUND"}} =
               place(limit_request(), responding(body))
    end

    test "a rejection with no readable detail still refuses" do
      assert {:refused, {:order_rejected, :unspecified}} =
               place(limit_request(), responding(%{"success" => false}))
    end
  end

  describe "client_order_id" do
    test "a caller's own id is used, because it is the venue's idempotency key" do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(accepted()))
      end

      assert {:ok, _order} = place(limit_request(%{client_order_id: "mine-1"}), plug)
      assert_receive {:sent, %{"client_order_id" => "mine-1"}}
    end

    test "one is generated when absent, and it is a distinct v4 UUID each time" do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(accepted()))
      end

      assert {:ok, _first_order} = place(limit_request(), plug)
      assert_receive {:sent, %{"client_order_id" => first}}

      assert {:ok, _second_order} = place(limit_request(), plug)
      assert_receive {:sent, %{"client_order_id" => second}}

      assert first =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
      refute first == second
    end
  end

  describe "sizing a market order" do
    test "a quote_size sizes in the quote currency, not the base" do
      # "Spend $100 of USD" and "buy 100 BTC" are different orders. The venue takes either,
      # under different keys, and picking the wrong one is a trade of wildly the wrong size.
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(accepted()))
      end

      request =
        limit_request(%{order_type: :market, time_in_force: :ioc, quote_size: Decimal.new("100")})
        |> Map.delete(:quantity)

      assert {:ok, _order} = place(request, plug)

      assert_receive {:sent,
                      %{
                        "order_configuration" => %{
                          "market_market_ioc" => %{"quote_size" => "100"}
                        }
                      }}
    end

    test "a base quantity wins when both are given, and is sent as base_size" do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(accepted()))
      end

      request =
        limit_request(%{order_type: :market, time_in_force: :ioc, quote_size: Decimal.new("100")})

      assert {:ok, _order} = place(request, plug)

      assert_receive {:sent, %{"order_configuration" => %{"market_market_ioc" => leaf}}}

      assert leaf["base_size"] == "0.5"
      refute Map.has_key?(leaf, "quote_size")
    end
  end

  describe "optional flags reach the venue only when given" do
    setup do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(accepted()))
      end

      {:ok, plug: plug}
    end

    test "post_only is sent when set", %{plug: plug} do
      assert {:ok, _order} = place(limit_request(%{post_only: true}), plug)
      assert_receive {:sent, %{"order_configuration" => %{"limit_limit_gtc" => leaf}}}
      assert leaf["post_only"] == "true"
    end

    test "post_only is absent when unset, not sent as false", %{plug: plug} do
      # `false` is a decision the caller did not make. Sending it would tell the venue the
      # order may take liquidity, which is the opposite of what silence means here.
      assert {:ok, _order} = place(limit_request(), plug)
      assert_receive {:sent, %{"order_configuration" => %{"limit_limit_gtc" => leaf}}}
      refute Map.has_key?(leaf, "post_only")
    end

    test "end_time is sent for a GTD order", %{plug: plug} do
      assert {:ok, _order} =
               place(
                 limit_request(%{time_in_force: :gtd, end_time: "2026-09-01T00:00:00Z"}),
                 plug
               )

      assert_receive {:sent, %{"order_configuration" => %{"limit_limit_gtd" => leaf}}}
      assert leaf["end_time"] == "2026-09-01T00:00:00Z"
    end
  end

  describe "the request the venue actually receives" do
    test "side is upper-cased, because the venue takes BUY and SELL" do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(accepted()))
      end

      assert {:ok, _order} = place(limit_request(%{side: :sell}), plug)
      assert_receive {:sent, %{"side" => "SELL", "product_id" => "BTC-USD"}}
    end
  end
end

defmodule DpExchange.Coinbase.OrderLifecycleTest do
  @moduledoc """
  Cancelling, reading and listing orders.

  The assertions worth the most here are about the venue answering `200` while saying no:
  cancellation is a batch endpoint that refuses per order, so the HTTP status says nothing
  about whether anything was cancelled.
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

  defp order_json(overrides \\ %{}) do
    Map.merge(
      %{
        "order_id" => "abc-123",
        "product_id" => "BTC-USD",
        "side" => "BUY",
        "order_type" => "LIMIT",
        "time_in_force" => "GOOD_UNTIL_CANCELLED",
        "status" => "OPEN",
        # Deliberately different from filled_size below: this is the field the fix reads
        # :quantity from, and a fixture where the two agree would not catch a regression
        # back to reading both from filled_size.
        "order_configuration" => %{
          "limit_limit_gtc" => %{"base_size" => "1.0", "limit_price" => "40000"}
        },
        "filled_size" => "0.25",
        "average_filled_price" => "40100.5",
        "total_fees" => "1.20",
        "fee_currency" => "USD",
        "created_time" => "2026-08-31T12:00:00Z"
      },
      overrides
    )
  end

  describe "cancel_order/3 — a 200 is not a cancellation" do
    test "a per-order success cancels" do
      body = %{"results" => [%{"order_id" => "abc-123", "success" => true}]}

      assert {:ok, :cancelled} =
               Rest.cancel_order(@credentials, "abc-123",
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "a per-order failure refuses, carrying the venue's reason" do
      # The HTTP call succeeded and nothing was cancelled. This is the case that would look
      # like success to anything reading only the status code.
      body = %{
        "results" => [
          %{
            "order_id" => "abc-123",
            "success" => false,
            "failure_reason" => "UNKNOWN_CANCEL_ORDER"
          }
        ]
      }

      assert {:refused, {:cancel_rejected, "UNKNOWN_CANCEL_ORDER"}} =
               Rest.cancel_order(@credentials, "abc-123",
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "a results array that does not mention the order is an error, not a cancellation" do
      # The venue answered about orders and none of them was this one. Neither cancelled nor
      # refused — nobody said.
      body = %{"results" => [%{"order_id" => "someone-else", "success" => true}]}

      assert {:error, :order_not_in_response} =
               Rest.cancel_order(@credentials, "abc-123",
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "a body with no results at all is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.cancel_order(@credentials, "abc-123",
                 plug: responding(%{}),
                 retry_attempts: 0
               )
    end
  end

  describe "get_order/3" do
    test "returns an Order with the venue's own fields" do
      body = %{"order" => order_json()}

      assert {:ok, %Types.Order{} = order} =
               Rest.get_order(@credentials, "abc-123", plug: responding(body), retry_attempts: 0)

      assert order.id == "abc-123"
      assert order.symbol == "BTC-USD"
      assert order.side == :buy
      assert order.order_type == :limit
      assert order.time_in_force == :gtc
      assert order.status == :open
      assert Decimal.equal?(order.quantity, Decimal.new("1.0"))
      assert Decimal.equal?(order.filled_quantity, Decimal.new("0.25"))
      assert Decimal.equal?(order.average_price, Decimal.new("40100.5"))
      assert order.fee_currency == "USD"
      assert order.provider == :coinbase
    end

    test "quantity is the originally-requested size, not the filled amount — a partial fill has quantity > filled_quantity" do
      # Filed as a live bug: to_order/1 read both :quantity and :filled_quantity from the
      # venue's filled_size, so remaining_quantity == quantity - filled_quantity was always
      # zero for a fetched order, even one genuinely still open and partially filled.
      body = %{"order" => order_json(%{"status" => "OPEN", "filled_size" => "0.25"})}

      assert {:ok, order} =
               Rest.get_order(@credentials, "abc-123", plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(order.quantity, Decimal.new("1.0"))
      assert Decimal.equal?(order.filled_quantity, Decimal.new("0.25"))
      refute Decimal.equal?(order.quantity, order.filled_quantity)
    end

    test "a quote-sized market order leaf has no base_size, so quantity is nil rather than a guess" do
      body = %{
        "order" =>
          order_json(%{
            "order_configuration" => %{"market_market_ioc" => %{"quote_size" => "500"}}
          })
      }

      assert {:ok, order} =
               Rest.get_order(@credentials, "abc-123", plug: responding(body), retry_attempts: 0)

      assert order.quantity == nil
    end

    test "a missing order_configuration leaves quantity nil rather than crashing" do
      body = %{"order" => order_json() |> Map.delete("order_configuration")}

      assert {:ok, order} =
               Rest.get_order(@credentials, "abc-123", plug: responding(body), retry_attempts: 0)

      assert order.quantity == nil
    end

    test "a body with no order key is unreadable, not a missing order" do
      # A parse failure and "no such order" are different answers, and a caller retrying on
      # the first is right while a caller retrying on the second is chasing nothing.
      assert {:error, :unexpected_response_shape} =
               Rest.get_order(@credentials, "abc-123", plug: responding(%{}), retry_attempts: 0)
    end
  end

  describe "the venue's status vocabulary" do
    for {venue, expected} <- [
          {"PENDING", :pending},
          {"QUEUED", :open},
          {"OPEN", :open},
          {"CANCEL_QUEUED", :open},
          {"FILLED", :filled},
          {"CANCELLED", :cancelled},
          {"EXPIRED", :expired},
          {"FAILED", :rejected}
        ] do
      test "#{venue} maps to #{expected}" do
        body = %{"order" => order_json(%{"status" => unquote(venue)})}

        assert {:ok, order} =
                 Rest.get_order(@credentials, "abc-123",
                   plug: responding(body),
                   retry_attempts: 0
                 )

        assert order.status == unquote(expected)
      end
    end

    test "CANCEL_QUEUED is open, because the order can still fill" do
      # The dangerous mapping would be :cancelled. An order accepted for cancellation is
      # still live until the venue says otherwise, and telling a caller it is gone invites
      # a second order for the same exposure.
      body = %{"order" => order_json(%{"status" => "CANCEL_QUEUED"})}

      assert {:ok, order} =
               Rest.get_order(@credentials, "abc-123", plug: responding(body), retry_attempts: 0)

      assert order.status == :open
      refute order.status == :cancelled
    end

    test "a status the venue invents later is nil, never a guess" do
      body = %{"order" => order_json(%{"status" => "SOMETHING_NEW"})}

      assert {:ok, order} =
               Rest.get_order(@credentials, "abc-123", plug: responding(body), retry_attempts: 0)

      assert order.status == nil
    end
  end

  describe "get_orders/2" do
    test "returns the page the venue sent" do
      body = %{"orders" => [order_json(), order_json(%{"order_id" => "def-456"})]}

      assert {:ok, [first, second]} =
               Rest.get_orders(@credentials, plug: responding(body), retry_attempts: 0)

      assert first.id == "abc-123"
      assert second.id == "def-456"
    end

    test "filters are sent to the venue rather than applied here" do
      # A client-side filter over one page would silently drop matching orders that were on
      # the next one.
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"orders" => []}))
      end

      assert {:ok, []} =
               Rest.get_orders(@credentials,
                 status: :open,
                 symbol: "BTC-USD",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, query}
      assert query =~ "order_status=OPEN"
      assert query =~ "product_ids=BTC-USD"
    end

    test "an empty page is an empty list, not an error" do
      assert {:ok, []} =
               Rest.get_orders(@credentials,
                 plug: responding(%{"orders" => []}),
                 retry_attempts: 0
               )
    end

    test "a body with no orders key is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_orders(@credentials, plug: responding(%{}), retry_attempts: 0)
    end
  end

  describe "every field the venue names is mapped, and everything else is nil" do
    # These are the clauses that decide what a caller sees when the venue sends a word this
    # package does not know. `nil` is the answer in every case: a caller branching on :buy
    # must not be handed :buy because that was the closest atom to hand.

    for {venue, expected} <- [{"BUY", :buy}, {"SELL", :sell}] do
      test "side #{venue} maps to #{expected}" do
        body = %{"order" => order_json(%{"side" => unquote(venue)})}

        assert {:ok, order} =
                 Rest.get_order(@credentials, "abc-123",
                   plug: responding(body),
                   retry_attempts: 0
                 )

        assert order.side == unquote(expected)
      end
    end

    test "an unknown side is nil" do
      body = %{"order" => order_json(%{"side" => "SIDEWAYS"})}

      assert {:ok, order} =
               Rest.get_order(@credentials, "abc-123", plug: responding(body), retry_attempts: 0)

      assert order.side == nil
    end

    for {venue, expected} <- [{"MARKET", :market}, {"LIMIT", :limit}, {"STOP_LIMIT", :stop_limit}] do
      test "order type #{venue} maps to #{expected}" do
        body = %{"order" => order_json(%{"order_type" => unquote(venue)})}

        assert {:ok, order} =
                 Rest.get_order(@credentials, "abc-123",
                   plug: responding(body),
                   retry_attempts: 0
                 )

        assert order.order_type == unquote(expected)
      end
    end

    test "an unknown order type is nil" do
      body = %{"order" => order_json(%{"order_type" => "BRACKET"})}

      assert {:ok, order} =
               Rest.get_order(@credentials, "abc-123", plug: responding(body), retry_attempts: 0)

      assert order.order_type == nil
    end

    for {venue, expected} <- [
          {"GOOD_UNTIL_CANCELLED", :gtc},
          {"GOOD_UNTIL_DATE_TIME", :gtd},
          {"IMMEDIATE_OR_CANCEL", :ioc},
          {"FILL_OR_KILL", :fok}
        ] do
      test "time in force #{venue} maps to #{expected}" do
        body = %{"order" => order_json(%{"time_in_force" => unquote(venue)})}

        assert {:ok, order} =
                 Rest.get_order(@credentials, "abc-123",
                   plug: responding(body),
                   retry_attempts: 0
                 )

        assert order.time_in_force == unquote(expected)
      end
    end

    test "an unknown time in force is nil" do
      body = %{"order" => order_json(%{"time_in_force" => "GOOD_TILL_LUNCH"})}

      assert {:ok, order} =
               Rest.get_order(@credentials, "abc-123", plug: responding(body), retry_attempts: 0)

      assert order.time_in_force == nil
    end

    test "a missing product_id leaves the symbol nil rather than crashing" do
      body = %{"order" => order_json() |> Map.delete("product_id")}

      assert {:ok, order} =
               Rest.get_order(@credentials, "abc-123", plug: responding(body), retry_attempts: 0)

      assert order.symbol == nil
    end

    test "an unparsable created_time is nil, not the local clock" do
      body = %{"order" => order_json(%{"created_time" => "not a date"})}

      assert {:ok, order} =
               Rest.get_order(@credentials, "abc-123", plug: responding(body), retry_attempts: 0)

      assert order.created_at == nil
    end

    test "a missing created_time is nil" do
      body = %{"order" => order_json() |> Map.delete("created_time")}

      assert {:ok, order} =
               Rest.get_order(@credentials, "abc-123", plug: responding(body), retry_attempts: 0)

      assert order.created_at == nil
    end
  end

  describe "filter values" do
    test "a status given as a string is upper-cased like an atom is" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"orders" => []}))
      end

      assert {:ok, []} =
               Rest.get_orders(@credentials, status: "open", plug: plug, retry_attempts: 0)

      assert_receive {:query, query}
      assert query =~ "order_status=OPEN"
    end

    test "a limit is passed through" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"orders" => []}))
      end

      assert {:ok, []} = Rest.get_orders(@credentials, limit: 25, plug: plug, retry_attempts: 0)
      assert_receive {:query, query}
      assert query =~ "limit=25"
    end
  end
end

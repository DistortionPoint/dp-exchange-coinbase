defmodule DpExchange.Coinbase.OrderInputHardeningTest do
  @moduledoc """
  What the order, edit, cancel, history and fill paths refuse instead of sending or
  returning (2026-10-10 audit against `docs/reference/coinbase/openapi/at-spec.yaml`).

  Each case is a value that used to reach the wire, or come back as a complete-looking
  answer, with a plausible shape and the wrong meaning: an upcased `:hold` side, a float sent
  in scientific notation, a `price: nil` edit sent as `""`, a first page returned as the
  whole list, a fill dropped for want of a `trade_type`.
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

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  defp responding(body), do: fn conn -> json(conn, body) end

  defp capturing(body, pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(pid, {:sent, conn.request_path, raw})
      json(conn, body)
    end
  end

  defp never_sent, do: fn _conn -> raise "the venue must not be called" end

  defp opts(plug), do: [plug: plug, retry_attempts: 0]

  defp accepted, do: %{"success" => true, "success_response" => %{"order_id" => "abc-123"}}

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

  defp order_row(overrides \\ %{}) do
    Map.merge(
      %{
        "order_id" => "abc-123",
        "product_id" => "BTC-USD",
        "side" => "BUY",
        "order_type" => "LIMIT",
        "status" => "OPEN"
      },
      overrides
    )
  end

  defp fill_row(overrides \\ %{}) do
    Map.merge(
      %{
        "trade_id" => "t-1",
        "order_id" => "o-1",
        "trade_time" => "2026-08-31T09:59:59Z",
        "trade_type" => "FILL",
        "price" => "10000",
        "size" => "1",
        "product_id" => "BTC-USD",
        "side" => "BUY"
      },
      overrides
    )
  end

  describe "place_order/3 side" do
    test "only buy and sell are sent" do
      for bad <- [:hold, "buyy", "", 1, %{"side" => "buy"}] do
        assert {:error, {:invalid_side, ^bad}} =
                 Rest.place_order(@credentials, limit_request(%{side: bad}), opts(never_sent()))
      end
    end

    test "a string spelling is normalised and the returned order carries the atom" do
      me = self()

      assert {:ok, %Types.Order{side: :sell}} =
               Rest.place_order(
                 @credentials,
                 limit_request(%{side: "Sell"}),
                 opts(capturing(accepted(), me))
               )

      assert_receive {:sent, _path, raw}
      assert Jason.decode!(raw)["side"] == "SELL"
    end
  end

  describe "place_order/3 amounts" do
    test "a float is sent in plain notation, never scientific" do
      me = self()

      request = limit_request(%{quantity: 1.0e-8, price: 0.1})

      assert {:ok, _order} =
               Rest.place_order(@credentials, request, opts(capturing(accepted(), me)))

      assert_receive {:sent, _path, raw}
      leaf = Jason.decode!(raw)["order_configuration"]["limit_limit_gtc"]
      # Numerically 1.0e-8; the digits after the point are the venue-readable plain form.
      refute leaf["base_size"] =~ ~r/e/i
      assert Decimal.equal?(Decimal.new(leaf["base_size"]), Decimal.new("0.00000001"))
      assert leaf["limit_price"] == "0.1"
    end

    test "a value that is not a finite positive number is refused before sending" do
      for {field, bad} <- [
            {:quantity, "abc"},
            {:quantity, ""},
            {:quantity, 0},
            {:quantity, Decimal.new("-1")},
            {:quantity, "NaN"},
            {:quantity, Decimal.new("Infinity")},
            {:price, %{}},
            {:price, :free}
          ] do
        request = limit_request(%{field => bad})

        assert {:error, {:invalid_order_amount, ^field, ^bad}} =
                 Rest.place_order(@credentials, request, opts(never_sent())),
               inspect({field, bad})
      end
    end

    test "quote_size and stop_price are checked as well" do
      market = %{
        symbol: "BTC-USD",
        side: :buy,
        order_type: :market,
        time_in_force: :ioc,
        quote_size: "x"
      }

      assert {:error, {:invalid_order_amount, :quote_size, "x"}} =
               Rest.place_order(@credentials, market, opts(never_sent()))

      assert {:error, {:invalid_order_amount, :stop_price, 0}} =
               Rest.place_order(
                 @credentials,
                 limit_request(%{order_type: :stop_limit, stop_price: 0}),
                 opts(never_sent())
               )
    end

    test "a stop price is echoed on the placed order" do
      request = limit_request(%{order_type: :stop_limit, stop_price: "39000"})

      assert {:ok, %Types.Order{stop_price: stop}} =
               Rest.place_order(@credentials, request, opts(responding(accepted())))

      assert Decimal.equal?(stop, Decimal.new("39000"))
    end
  end

  describe "place_order/3 client_order_id" do
    test "an empty or non-string id is refused, not sent as the venue's shared key" do
      for bad <- ["", 123, :id] do
        assert {:error, {:invalid_client_order_id, ^bad}} =
                 Rest.place_order(
                   @credentials,
                   limit_request(%{client_order_id: bad}),
                   opts(never_sent())
                 )
      end
    end

    test "a supplied id is sent unchanged and an absent one is generated" do
      me = self()

      assert {:ok, _result} =
               Rest.place_order(
                 @credentials,
                 limit_request(%{client_order_id: "mine-1"}),
                 opts(capturing(accepted(), me))
               )

      assert_receive {:sent, _path, raw}
      assert Jason.decode!(raw)["client_order_id"] == "mine-1"

      assert {:ok, _result} =
               Rest.place_order(@credentials, limit_request(), opts(capturing(accepted(), me)))

      assert_receive {:sent, _path, raw}
      assert byte_size(Jason.decode!(raw)["client_order_id"]) == 36
    end
  end

  describe "place_order/3 and close_position/3 envelopes" do
    test "success true with no success_response is accepted and unidentified" do
      # `success` is the only field the spec requires of `NewOrderResponse`. An error here
      # reads as "nothing was placed", and a retry places a second order.
      assert {:ok, %{id: nil, status: :pending}} =
               Rest.place_order(
                 @credentials,
                 limit_request(),
                 opts(responding(%{"success" => true}))
               )

      assert {:ok, %{id: nil, status: :pending}} =
               Rest.close_position(
                 @credentials,
                 "BTC-USD",
                 opts(responding(%{"success" => true}))
               )
    end

    test "an order id that is not a non-empty string is not reported as one" do
      for bad <- ["", 7, %{}] do
        body = %{"success" => true, "success_response" => %{"order_id" => bad}}

        assert {:ok, %{id: nil}} =
                 Rest.place_order(@credentials, limit_request(), opts(responding(body)))
      end
    end

    test "a 200 with success false is a refusal carrying the venue's reason" do
      body = %{
        "success" => false,
        "error_response" => %{"new_order_failure_reason" => "DUPLICATE_CLIENT_ORDER_ID"}
      }

      assert {:refused, {:order_rejected, "DUPLICATE_CLIENT_ORDER_ID"}} =
               Rest.place_order(@credentials, limit_request(), opts(responding(body)))
    end

    test "close_position sends a plain-notation size and refuses a bad one or a bad id" do
      me = self()

      assert {:ok, _result} =
               Rest.close_position(
                 @credentials,
                 "BTC-USD",
                 [size: Decimal.new("1.5E+1")] ++ opts(capturing(accepted(), me))
               )

      assert_receive {:sent, _path, raw}
      assert Jason.decode!(raw)["size"] == "15"

      assert {:error, {:invalid_order_amount, :size, "lots"}} =
               Rest.close_position(
                 @credentials,
                 "BTC-USD",
                 [size: "lots"] ++ opts(never_sent())
               )

      assert {:error, {:invalid_client_order_id, ""}} =
               Rest.close_position(
                 @credentials,
                 "BTC-USD",
                 [client_order_id: ""] ++ opts(never_sent())
               )
    end
  end

  describe "replace_order/4 and preview_replace/4" do
    test "a nil price or size is not 'given'" do
      for changes <- [
            %{price: nil, quantity: Decimal.new("1")},
            %{price: Decimal.new("1"), quantity: nil}
          ] do
        assert {:error, :missing_required_edit_field} =
                 Rest.replace_order(@credentials, "abc", changes, opts(never_sent()))

        assert {:error, :missing_required_edit_field} =
                 Rest.preview_replace(@credentials, "abc", changes, opts(never_sent()))
      end

      assert {:error, :no_order_changes} =
               Rest.replace_order(
                 @credentials,
                 "abc",
                 %{price: nil, quantity: nil},
                 opts(never_sent())
               )
    end

    test "an amount that is not a finite positive number is refused" do
      changes = %{price: "cheap", quantity: Decimal.new("1")}

      assert {:error, {:invalid_order_amount, :price, "cheap"}} =
               Rest.replace_order(@credentials, "abc", changes, opts(never_sent()))

      assert {:error, {:invalid_order_amount, :quantity, 0}} =
               Rest.preview_replace(
                 @credentials,
                 "abc",
                 %{price: 1, quantity: 0},
                 opts(never_sent())
               )
    end

    test "an order id that names nothing is refused" do
      changes = %{price: 1, quantity: 1}

      for bad <- [nil, "", :abc] do
        assert {:error, {:invalid_id, :order_id, ^bad}} =
                 Rest.replace_order(@credentials, bad, changes, opts(never_sent()))
      end
    end

    test "a float is sent in plain notation" do
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, conn.request_path, raw})

        if conn.request_path =~ "edit",
          do: json(conn, %{"success" => true}),
          else: json(conn, %{"order" => order_row()})
      end

      assert {:ok, _order} =
               Rest.replace_order(
                 @credentials,
                 "abc-123",
                 %{price: 1.0e-7, quantity: 2},
                 opts(plug)
               )

      assert_receive {:sent, "/api/v3/brokerage/orders/edit", raw}
      %{"price" => price, "size" => "2"} = Jason.decode!(raw)
      refute price =~ ~r/e/i
      assert Decimal.equal?(Decimal.new(price), Decimal.new("0.0000001"))
    end
  end

  describe "cancel_order/3 and get_order/3 ids" do
    test "an id that names no order is refused before anything is sent" do
      for bad <- [nil, "", :abc, %{}] do
        assert {:error, {:invalid_id, :order_id, ^bad}} =
                 Rest.cancel_order(@credentials, bad, opts(never_sent()))

        assert {:error, {:invalid_id, :order_id, ^bad}} =
                 Rest.get_order(@credentials, bad, opts(never_sent()))
      end
    end

    test "an order id is percent-encoded into the read path" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})
        json(conn, %{"order" => order_row(%{"order_id" => "a/b"})})
      end

      assert {:ok, %{id: "a/b"}} = Rest.get_order(@credentials, "a/b", opts(plug))
      assert_receive {:path, "/api/v3/brokerage/orders/historical/a%2Fb"}
    end
  end

  describe "orders without an id" do
    test "get_order/3 refuses an order naming no id" do
      for row <- [Map.delete(order_row(), "order_id"), order_row(%{"order_id" => ""})] do
        assert {:error, {:missing_required_field, :order_id}} =
                 Rest.get_order(@credentials, "abc-123", opts(responding(%{"order" => row})))
      end
    end

    test "get_orders/2 refuses the whole list rather than carrying an untrackable order" do
      body = %{"orders" => [order_row(), Map.delete(order_row(), "order_id")]}

      assert {:error, {:missing_required_field, :order_id}} =
               Rest.get_orders(@credentials, opts(responding(body)))
    end

    test "get_orders/2 keeps the venue's order of the rows" do
      body = %{
        "orders" => [order_row(%{"order_id" => "b"}), order_row(%{"order_id" => "a"})]
      }

      assert {:ok, orders} = Rest.get_orders(@credentials, opts(responding(body)))
      assert Enum.map(orders, & &1.id) == ["b", "a"]
    end
  end

  describe "get_orders/2 pagination" do
    test "has_next true with no usable cursor is an error, not a short list" do
      for extra <- [%{}, %{"cursor" => ""}, %{"cursor" => 5}] do
        body = Map.merge(%{"orders" => [order_row()], "has_next" => true}, extra)

        assert {:error, :pagination_cursor_missing} =
                 Rest.get_orders(@credentials, opts(responding(body)))
      end
    end

    test "an empty page that says proof_token_required is withheld data, not no orders" do
      body = %{"orders" => [], "has_next" => false, "proof_token_required" => true}

      assert {:refused, :proof_token_required} =
               Rest.get_orders(@credentials, opts(responding(body)))
    end

    test "a page with orders is returned even when the flag is set" do
      body = %{"orders" => [order_row()], "has_next" => false, "proof_token_required" => true}
      assert {:ok, [_one]} = Rest.get_orders(@credentials, opts(responding(body)))
    end
  end

  describe "get_trade_history/2" do
    test "a row with no trade_type is refused, not dropped" do
      for row <- [Map.delete(fill_row(), "trade_type"), fill_row(%{"trade_type" => nil})] do
        body = %{"fills" => [fill_row(), row], "cursor" => ""}

        assert {:error, {:missing_required_field, :trade_type}} =
                 Rest.get_trade_history(@credentials, opts(responding(body)))
      end
    end

    test "an unwanted but stated trade_type is still excluded" do
      body = %{"fills" => [fill_row(), fill_row(%{"trade_type" => "REVERSAL"})], "cursor" => ""}
      assert {:ok, [_only]} = Rest.get_trade_history(@credentials, opts(responding(body)))
    end

    test "an empty page that says proof_token_required is withheld data, not no fills" do
      body = %{"fills" => [], "cursor" => "", "proof_token_required" => true}

      assert {:refused, :proof_token_required} =
               Rest.get_trade_history(@credentials, opts(responding(body)))
    end
  end

  describe "portfolio ids" do
    test "a portfolio uuid is percent-encoded into the path" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})
        json(conn, %{"breakdown" => %{}})
      end

      assert {:ok, %{}} = Rest.get_portfolio_breakdown(@credentials, "p/../q", opts(plug))
      assert_receive {:path, "/api/v3/brokerage/portfolios/p%2F..%2Fq"}
    end
  end
end

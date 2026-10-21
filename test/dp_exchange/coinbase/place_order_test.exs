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

  # Refuses every request the way a full bucket does: nothing leaves the process.
  defmodule ThrottlingLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :rate_limit_timeout}
    @impl true
    def check(_provider, _weight, _opts), do: {:rate_limited, 2_000}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  # Lets the first request through and refuses every later one, per calling process.
  defmodule RefuseAfterFirstLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts) do
      if Process.get(:first_acquire_done, false) do
        {:error, :rate_limit_timeout}
      else
        Process.put(:first_acquire_done, true)
        :ok
      end
    end

    @impl true
    def check(_provider, _weight, _opts), do: {:rate_limited, 2_000}
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

      # Each leaf gets exactly the fields its own schema carries: a market order has no
      # price, a limit order no stop price, and only a GTD order an expiry.
      for {type, tif} <- pairs do
        assert {:ok, _order} = place(request_for(type, tif), responding(accepted())),
               "#{type}/#{tif} is in the table but did not build"
      end
    end
  end

  defp never_sent, do: fn _conn -> raise "the venue must not be called" end

  defp market_request(overrides \\ %{}) do
    Map.merge(
      %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        order_type: :market,
        time_in_force: :ioc
      },
      overrides
    )
  end

  @expiry "2026-09-01T00:00:00Z"

  defp request_for(:market, tif), do: market_request(%{time_in_force: tif})

  defp request_for(:limit, :gtd),
    do: limit_request(%{time_in_force: :gtd, end_time: @expiry})

  defp request_for(:limit, tif), do: limit_request(%{time_in_force: tif})

  defp request_for(:stop_limit, :gtd),
    do: stop_request(%{time_in_force: :gtd, end_time: @expiry})

  defp request_for(:stop_limit, tif), do: stop_request(%{time_in_force: tif})

  describe "fields the type does not use are refused, never dropped" do
    test "a price or a stop price on a market order" do
      assert {:error, {:unexpected_field, :price}} =
               place(market_request(%{price: Decimal.new("40000")}), never_sent())

      assert {:error, {:unexpected_field, :stop_price}} =
               place(market_request(%{stop_price: "1"}), never_sent())
    end

    test "a stop price on a limit order" do
      assert {:error, {:unexpected_field, :stop_price}} =
               place(limit_request(%{stop_price: Decimal.new("39000")}), never_sent())
    end

    test "a quote size on a stop-limit order (its leaf carries base_size only)" do
      request =
        limit_request(%{
          order_type: :stop_limit,
          stop_price: Decimal.new("39000"),
          quote_size: "10"
        })

      assert {:error, {:unexpected_field, :quote_size}} = place(request, never_sent())
    end

    test "post_only: true on a market order" do
      assert {:error, {:unexpected_field, :post_only}} =
               place(market_request(%{post_only: true}), never_sent())
    end

    test "post_only: false means absent where the leaf has no such field" do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(accepted()))
      end

      for request <- [
            market_request(%{post_only: false}),
            limit_request(%{time_in_force: :fok, post_only: false}),
            limit_request(%{
              order_type: :stop_limit,
              stop_price: Decimal.new("39000"),
              post_only: false
            })
          ] do
        assert {:ok, _order} = place(request, plug)
        assert_receive {:sent, %{"order_configuration" => config}}, 5_000
        [leaf] = Map.values(config)
        refute Map.has_key?(leaf, "post_only")
      end
    end

    test "post_only: true is still refused on limit FOK and stop-limit leaves" do
      assert {:error, {:unexpected_field, :post_only}} =
               place(limit_request(%{time_in_force: :fok, post_only: true}), never_sent())
    end

    test "a limit order is sized by quote_size under the leaf's quote_size key" do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(accepted()))
      end

      for tif <- [:gtc, :fok] do
        request =
          limit_request(%{time_in_force: tif, quote_size: "10"}) |> Map.delete(:quantity)

        assert {:ok, order} = place(request, plug)
        assert order.quantity == nil
        assert_receive {:sent, %{"order_configuration" => config}}, 5_000
        [leaf] = Map.values(config)
        assert leaf["quote_size"] == "10"
        assert leaf["limit_price"] == "40000"
        refute Map.has_key?(leaf, "base_size")
      end
    end

    test "a limit order with both sizes or neither is refused before sending" do
      assert {:error, {:unexpected_field, :quote_size}} =
               place(limit_request(%{quote_size: "10"}), never_sent())

      assert {:error, {:missing_field, :quantity}} =
               place(Map.delete(limit_request(), :quantity), never_sent())

      assert {:error, {:invalid_quote_size, 10.0}} =
               place(
                 limit_request(%{quote_size: 10.0}) |> Map.delete(:quantity),
                 never_sent()
               )
    end

    test "the same checks run in preview_order/3" do
      assert {:error, {:unexpected_field, :price}} =
               Rest.preview_order(@credentials, market_request(%{price: "1"}),
                 plug: never_sent(),
                 retry_attempts: 0
               )
    end
  end

  describe "order type and time-in-force are required, never defaulted" do
    test "no order_type is {:missing_field, :order_type}, not a limit order" do
      assert {:error, {:missing_field, :order_type}} =
               place(Map.delete(limit_request(), :order_type), never_sent())
    end

    test "no time_in_force is {:missing_field, :time_in_force}, not GTC" do
      assert {:error, {:missing_field, :time_in_force}} =
               place(Map.delete(limit_request(), :time_in_force), never_sent())

      # A market order with no tif was refused for a tif the caller never named.
      assert {:error, {:missing_field, :time_in_force}} =
               place(Map.delete(market_request(), :time_in_force), never_sent())
    end

    test "an unknown type is unsupported_order_type" do
      for type <- [:stop, :trailing, "limit", 5] do
        assert {:error, {:unsupported_order_type, ^type}} =
                 place(limit_request(%{order_type: type}), never_sent())
      end
    end

    test "a GTD order without its expiry is {:missing_field, :end_time}" do
      assert {:error, {:missing_field, :end_time}} =
               place(limit_request(%{time_in_force: :gtd}), never_sent())

      stop = limit_request(%{order_type: :stop_limit, time_in_force: :gtd, stop_price: "1"})
      assert {:error, {:missing_field, :end_time}} = place(stop, never_sent())
    end

    test "a GTD expiry is checked with the time in force, before sizing and prices (DV10)" do
      # Each of these also carries a field that would be refused LATER (an unreadable price,
      # no quantity); the expiry is what is reported.
      broken = %{time_in_force: :gtd, price: "abc"}

      assert {:error, {:missing_field, :end_time}} =
               place(limit_request(broken), never_sent())

      assert {:error, {:missing_field, :end_time}} =
               place(Map.delete(limit_request(%{time_in_force: :gtd}), :quantity), never_sent())

      assert {:error, {:invalid_end_time, 5}} =
               place(limit_request(Map.put(broken, :end_time, 5)), never_sent())

      assert {:error, {:invalid_end_time, "  "}} =
               place(limit_request(Map.put(broken, :end_time, "  ")), never_sent())

      # With a readable expiry the later checks run, in their usual order.
      assert {:error, {:invalid_price, "abc"}} =
               place(limit_request(Map.put(broken, :end_time, @expiry)), never_sent())
    end

    test "sizing errors are tagged tuples: neither is missing quantity, both is unexpected (DV4)" do
      assert {:error, {:missing_field, :quantity}} =
               place(Map.delete(limit_request(), :quantity), never_sent())

      assert {:error, {:unexpected_field, :quote_size}} =
               place(limit_request(%{quote_size: "10"}), never_sent())

      market = %{symbol: "BTC-USD", side: :buy, order_type: :market, time_in_force: :ioc}
      assert {:error, {:missing_field, :quantity}} = place(market, never_sent())

      assert {:error, {:unexpected_field, :quote_size}} =
               place(Map.merge(market, %{quantity: "1", quote_size: "10"}), never_sent())
    end

    test "a text end_time that is not RFC3339 with a zone is refused, never sent" do
      for bad <- ["tomorrow", "  ", "2026-09-01T00:00:00", "2026-09-01"] do
        assert {:error, {:invalid_end_time, ^bad}} =
                 place(limit_request(%{time_in_force: :gtd, end_time: bad}), never_sent())
      end
    end

    test "an end_time that is neither text nor a DateTime is refused" do
      assert {:error, {:invalid_end_time, 5}} =
               place(limit_request(%{time_in_force: :gtd, end_time: 5}), never_sent())
    end
  end

  describe "sizing and price are required, never defaulted" do
    test "a limit order with no price is an error" do
      request = limit_request() |> Map.delete(:price)

      assert {:error, {:missing_field, :price}} = place(request, responding(accepted()))
    end

    test "a stop-limit with no stop price is an error" do
      request =
        limit_request(%{order_type: :stop_limit}) |> Map.delete(:stop_price)

      assert {:error, {:missing_field, :stop_price}} = place(request, responding(accepted()))
    end

    test "a market order with neither base nor quote size is an error" do
      request =
        limit_request(%{order_type: :market, time_in_force: :ioc}) |> Map.delete(:quantity)

      assert {:error, {:missing_field, :quantity}} = place(request, responding(accepted()))
    end
  end

  describe "a write that cannot be signed is refused here, never sent unsigned" do
    # `place_order/3` has no public path — every caller of `json_request/5` is a write.
    # A malformed secret used to produce an *unauthenticated* POST that was actually
    # sent, because `Auth.rest_headers/4` swallowed the signing error and returned the
    # content-type header alone, and neither `Rest.request/5` nor `Rest.json_request/5`
    # ever checked whether an `Authorization` header came back. The venue answers that
    # with an opaque 401, which reads as a credential problem at Coinbase rather than a
    # malformed key here.
    test "a malformed api_secret refuses locally rather than posting an unsigned order" do
      me = self()

      plug = fn conn ->
        send(me, :request_was_sent)
        Plug.Conn.resp(conn, 200, "{}")
      end

      assert {:error, :invalid_base64} =
               Rest.place_order(
                 %{@credentials | api_secret: "not base64 !!"},
                 limit_request(),
                 plug: plug,
                 retry_attempts: 0
               )

      refute_receive :request_was_sent, 500
    end

    test "credentials that cannot sign at all are refused by name" do
      me = self()

      plug = fn conn ->
        send(me, :request_was_sent)
        Plug.Conn.resp(conn, 200, "{}")
      end

      assert {:error, {:missing_credentials, :coinbase}} =
               Rest.place_order(%{}, limit_request(), plug: plug, retry_attempts: 0)

      refute_receive :request_was_sent, 500
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

    test "new_order_failure_reason is read — the current, required field, not just the deprecated one" do
      # `NewOrderErrorResponse.new_order_failure_reason` is the current field and is
      # required (docs/reference/coinbase/openapi/at-spec.yaml:7962-7967); `error` above is
      # "(Deprecated)" (at-spec.yaml:7947-7950). This used to read only the deprecated one.
      body = %{
        "success" => false,
        "error_response" => %{
          "new_order_failure_reason" => "UNSUPPORTED_ORDER_CONFIGURATION",
          "error" => "INSUFFICIENT_FUND"
        }
      }

      assert {:refused, {:order_rejected, "UNSUPPORTED_ORDER_CONFIGURATION"}} =
               place(limit_request(), responding(body))
    end

    test "message and error_details are read when the structured reason is absent" do
      message_body = %{
        "success" => false,
        "error_response" => %{"message" => "The order configuration was invalid"}
      }

      assert {:refused, {:order_rejected, "The order configuration was invalid"}} =
               place(limit_request(), responding(message_body))

      details_body = %{
        "success" => false,
        "error_response" => %{
          "error_details" => "Market orders cannot be placed with empty order sizes"
        }
      }

      assert {:refused,
              {:order_rejected, "Market orders cannot be placed with empty order sizes"}} =
               place(limit_request(), responding(details_body))
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

      request = market_request(%{quote_size: Decimal.new("100")}) |> Map.delete(:quantity)

      assert {:ok, _order} = place(request, plug)

      assert_receive {:sent,
                      %{
                        "order_configuration" => %{
                          "market_market_ioc" => %{"quote_size" => "100"}
                        }
                      }}
    end

    test "both a base quantity and a quote size is refused before anything is sent" do
      # This used to be "a base quantity wins". Two sizes describe two different orders,
      # and choosing one spent money on an order the caller did not describe (2026-10-10).
      me = self()

      plug = fn conn ->
        send(me, :sent)
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
      end

      request = market_request(%{quote_size: Decimal.new("100")})

      assert {:error, {:unexpected_field, :quote_size}} = place(request, plug)
      refute_received :sent
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

    test "post_only is sent when set, as a JSON boolean, not the string \"true\"", %{
      plug: plug
    } do
      # `post_only` is documented as a JSON boolean
      # (docs/reference/coinbase/openapi/at-spec.yaml:7803, :7839). This fixture used to pin
      # the wrong shape: `put_unless_nil/3`'s catch-all ran every non-Decimal value through
      # `to_string/1`, so `true` became the string `"true"` on the wire — a shape the venue's
      # schema does not accept for this field.
      assert {:ok, _order} = place(limit_request(%{post_only: true}), plug)
      assert_receive {:sent, %{"order_configuration" => %{"limit_limit_gtc" => leaf}}}
      assert leaf["post_only"] == true
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

    test "a %DateTime{} end_time is sent RFC3339, with a T, not to_string's space", %{
      plug: plug
    } do
      # `end_time` is documented RFC3339
      # (docs/reference/coinbase/openapi/at-spec.yaml:7828-7831, :9640-9643).
      # `to_string(%DateTime{})` goes through `String.Chars` and renders a space where RFC3339
      # requires `T` — `"2026-09-01 00:00:00Z"`, which is not a timestamp this venue reads.
      end_time = DateTime.new!(~D[2026-09-01], ~T[00:00:00], "Etc/UTC")

      assert {:ok, _order} =
               place(limit_request(%{time_in_force: :gtd, end_time: end_time}), plug)

      assert_receive {:sent, %{"order_configuration" => %{"limit_limit_gtd" => leaf}}}
      assert leaf["end_time"] == "2026-09-01T00:00:00Z"
      refute leaf["end_time"] =~ " "
    end

    test "post_only on a leaf whose schema does not carry it is refused locally", _context do
      # `LimitLimitFok` has no `post_only` field
      # (docs/reference/coinbase/openapi/at-spec.yaml:7765-7783); neither does either
      # stop-limit leaf (:9596-9650). This used to add it unconditionally to every limit or
      # stop-limit leaf, so a caller's `post_only` landed silently in a shape the venue never
      # documented for FOK or stop-limit orders.
      exploding = fn _conn -> raise "must not send a field the leaf's schema does not carry" end

      assert {:error, {:unexpected_field, :post_only}} =
               place(
                 limit_request(%{time_in_force: :fok, post_only: true}),
                 exploding
               )

      assert {:error, {:unexpected_field, :post_only}} =
               place(
                 limit_request(%{
                   order_type: :stop_limit,
                   time_in_force: :gtc,
                   stop_price: Decimal.new("39000"),
                   post_only: true
                 }),
                 exploding
               )
    end

    test "end_time on a leaf whose schema does not carry it is refused locally" do
      exploding = fn _conn -> raise "must not send a field the leaf's schema does not carry" end

      assert {:error, {:unexpected_field, :end_time}} =
               place(
                 limit_request(%{time_in_force: :fok, end_time: "2026-09-01T00:00:00Z"}),
                 exploding
               )

      assert {:error, {:unexpected_field, :end_time}} =
               place(limit_request(%{end_time: "2026-09-01T00:00:00Z"}), exploding)

      assert {:error, {:unexpected_field, :end_time}} =
               place(
                 limit_request(%{
                   order_type: :stop_limit,
                   time_in_force: :gtc,
                   stop_price: Decimal.new("39000"),
                   end_time: "2026-09-01T00:00:00Z"
                 }),
                 exploding
               )
    end
  end

  describe "stop_direction — never inferred from side" do
    defp stop_request(overrides \\ %{}) do
      limit_request(
        Map.merge(
          %{
            order_type: :stop_limit,
            time_in_force: :gtc,
            stop_price: Decimal.new("39000")
          },
          overrides
        )
      )
    end

    test "absent when the caller does not give one" do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(accepted()))
      end

      assert {:ok, _order} = place(stop_request(), plug)
      assert_receive {:sent, %{"order_configuration" => %{"stop_limit_stop_limit_gtc" => leaf}}}
      refute Map.has_key?(leaf, "stop_direction")
    end

    test ":up and :down map to the venue's enum strings" do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(accepted()))
      end

      assert {:ok, _order} = place(stop_request(%{stop_direction: :up}), plug)
      assert_receive {:sent, %{"order_configuration" => %{"stop_limit_stop_limit_gtc" => leaf}}}
      assert leaf["stop_direction"] == "STOP_DIRECTION_STOP_UP"

      assert {:ok, _order} = place(stop_request(%{stop_direction: :down}), plug)
      assert_receive {:sent, %{"order_configuration" => %{"stop_limit_stop_limit_gtc" => leaf}}}
      assert leaf["stop_direction"] == "STOP_DIRECTION_STOP_DOWN"
    end

    test "is not inferred from side — a sell with no stop_direction sends none" do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(accepted()))
      end

      assert {:ok, _order} = place(stop_request(%{side: :sell}), plug)
      assert_receive {:sent, %{"order_configuration" => %{"stop_limit_stop_limit_gtc" => leaf}}}
      refute Map.has_key?(leaf, "stop_direction")
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

  describe "preview_order/3" do
    test "returns the venue's numbers without placing anything" do
      body = %{
        "order_total" => "20005.00",
        "commission_total" => "10.00",
        "base_size" => "0.5",
        "best_bid" => "39990",
        "best_ask" => "40010",
        "slippage" => "0.001",
        "preview_id" => "prev-1",
        "errs" => []
      }

      assert {:ok, preview} =
               Rest.preview_order(@credentials, limit_request(),
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(preview.order_total, Decimal.new("20005.00"))
      assert Decimal.equal?(preview.commission_total, Decimal.new("10.00"))
      assert preview.preview_id == "prev-1"
    end

    test "a preview carrying errors is a refusal, not a preview" do
      # The venue answers 200 with a populated `errs` for an order it would reject. Handing
      # that back as a successful preview would tell a caller its order is fine when the
      # venue has already said otherwise.
      body = %{"errs" => ["INSUFFICIENT_FUND"], "order_total" => "0"}

      assert {:refused, {:preview_rejected, ["INSUFFICIENT_FUND"]}} =
               Rest.preview_order(@credentials, limit_request(),
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "a warning is passed through and does NOT make it a refusal" do
      # A warning is the venue saying "this will execute, and you may not like how".
      body = %{"errs" => [], "warning" => "PREVIEW_WARNING_SLIPPAGE", "order_total" => "1"}

      assert {:ok, preview} =
               Rest.preview_order(@credentials, limit_request(),
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert preview.warning == "PREVIEW_WARNING_SLIPPAGE"
    end

    test "an impossible type/time-in-force pair is refused before previewing" do
      exploding = fn _conn -> raise "must not call the venue for an impossible pair" end

      assert {:error, {:unsupported_order_combination, :limit, :ioc}} =
               Rest.preview_order(@credentials, limit_request(%{time_in_force: :ioc}),
                 plug: exploding,
                 retry_attempts: 0
               )
    end
  end

  describe "replace_order/4" do
    test "an accepted edit reads the order back rather than echoing the request" do
      # The venue's edit response carries no order body. Building one from the request would
      # report what was asked for as though the venue had confirmed it.
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        body =
          if conn.request_path =~ "edit" do
            %{"success" => true}
          else
            %{
              "order" => %{
                "order_id" => "abc-123",
                "product_id" => "BTC-USD",
                "side" => "BUY",
                "status" => "OPEN"
              }
            }
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, order} =
               Rest.replace_order(
                 @credentials,
                 "abc-123",
                 %{price: Decimal.new("41000"), quantity: Decimal.new("0.5")},
                 plug: plug
               )

      assert order.id == "abc-123"
      assert order.status == :open
      assert_receive {:path, edit_path}
      assert edit_path =~ "edit"
      assert_receive {:path, read_path}
      assert read_path =~ "historical"
    end

    test "a rejected edit refuses with the venue's reason" do
      body = %{
        "success" => false,
        "errors" => [%{"edit_failure_reason" => "INVALID_PRICE_PRECISION"}]
      }

      assert {:refused, {:edit_rejected, "INVALID_PRICE_PRECISION"}} =
               Rest.replace_order(
                 @credentials,
                 "abc-123",
                 %{price: Decimal.new("41000"), quantity: Decimal.new("0.5")},
                 plug: responding(body)
               )
    end

    test "an edit of an order that is no longer working is refused, never read back as success" do
      # `ONLY_OPEN_ORDERS_CAN_BE_EDITED` is one of `EditOrderFailureReason`'s values
      # (at-spec.yaml:6749). A 200 saying `success: false` for a filled or cancelled order must
      # not be turned into an `{:ok, order}` by the read-back that follows a real edit.
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        body = %{
          "success" => false,
          "errors" => [%{"edit_failure_reason" => "ONLY_OPEN_ORDERS_CAN_BE_EDITED"}]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:refused, {:edit_rejected, "ONLY_OPEN_ORDERS_CAN_BE_EDITED"}} =
               Rest.replace_order(
                 @credentials,
                 "abc-123",
                 %{price: Decimal.new("41000"), quantity: Decimal.new("0.5")},
                 plug: plug
               )

      assert_receive {:path, edit_path}, 5_000
      assert edit_path =~ "/orders/edit"
      # Exactly one request: the venue's refusal ends it, with no read-back.
      refute_receive {:path, _another}, 500
    end

    test "preview_failure_reason is read when edit_failure_reason is absent" do
      # `EditOrderError` carries both fields
      # (docs/reference/coinbase/openapi/at-spec.yaml:6726-6734). This used to read only
      # `edit_failure_reason` and report `:unspecified` even when the entry named the
      # reason under the other field.
      body = %{
        "success" => false,
        "errors" => [%{"preview_failure_reason" => "PREVIEW_INSUFFICIENT_FUND"}]
      }

      assert {:refused, {:edit_rejected, "PREVIEW_INSUFFICIENT_FUND"}} =
               Rest.replace_order(
                 @credentials,
                 "abc-123",
                 %{price: Decimal.new("41000"), quantity: Decimal.new("0.5")},
                 plug: responding(body)
               )
    end

    test "changing anything but price or size is refused, not silently dropped" do
      # A caller trying to change the side is describing a different order. Editing only the
      # price would leave it holding one it did not ask for.
      exploding = fn _conn -> raise "must not call the venue for an unsupported edit" end

      assert {:error, {:unsupported_order_field, :side}} =
               Rest.replace_order(@credentials, "abc-123", %{side: :sell}, plug: exploding)

      # The first unread key, whatever else is wrong with the map.
      assert {:error, {:unsupported_order_field, :side}} =
               Rest.replace_order(@credentials, "abc-123", %{side: :sell, price: "x"},
                 plug: exploding
               )
    end

    test "a present price or quantity is judged as place_order judges it, nil included" do
      exploding = fn _conn -> raise "must not call the venue for an invalid change" end

      for {changes, expected} <- [
            {%{price: nil}, {:invalid_price, nil}},
            {%{quantity: nil}, {:invalid_quantity, nil}},
            {%{price: "cheap"}, {:invalid_price, "cheap"}},
            {%{price: 1.5}, {:invalid_price, 1.5}},
            {%{quantity: "0"}, {:invalid_quantity, "0"}}
          ] do
        assert {:error, expected} ==
                 Rest.replace_order(@credentials, "abc-123", changes, plug: exploding)
      end
    end

    test "an edit that changes nothing is an error" do
      exploding = fn _conn -> raise "must not call the venue with no changes" end

      assert {:error, {:invalid_order_request, %{}}} =
               Rest.replace_order(@credentials, "abc-123", %{}, plug: exploding)
    end

    test "price alone, or size alone, reads the order and sends the unchanged field beside it" do
      # `EditOrderRequest` requires order_id, price AND size, all three
      # (docs/reference/coinbase/openapi/at-spec.yaml:6809-6852), and `Core.Venue.replace_order/4`
      # does not require a change to name both, so the other is taken from the order.
      me = self()

      order = %{
        "order_id" => "abc-123",
        "status" => "OPEN",
        "order_configuration" => %{
          "limit_limit_gtc" => %{"base_size" => "0.75", "limit_price" => "40000"}
        }
      }

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:request, conn.method, conn.request_path, raw})

        body =
          if conn.request_path =~ "/orders/edit",
            do: %{"success" => true},
            else: %{"order" => order}

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, _order} =
               Rest.replace_order(@credentials, "abc-123", %{price: Decimal.new("41000")},
                 plug: plug
               )

      assert_receive {:request, "GET", "/api/v3/brokerage/orders/historical/abc-123", _}, 5_000
      assert_receive {:request, "POST", "/api/v3/brokerage/orders/edit", raw}, 5_000

      assert Jason.decode!(raw) == %{
               "order_id" => "abc-123",
               "price" => "41000",
               "size" => "0.75"
             }

      assert {:ok, _order} =
               Rest.replace_order(@credentials, "abc-123", %{quantity: Decimal.new("0.5")},
                 plug: plug
               )

      assert_receive {:request, "POST", "/api/v3/brokerage/orders/edit", raw}, 5_000
      assert Jason.decode!(raw) == %{"order_id" => "abc-123", "price" => "40000", "size" => "0.5"}
    end

    test "a field the order does not state is unavailable, and nothing is sent" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "order" => %{
              "order_id" => "abc-123",
              "order_configuration" => %{"market_market_ioc" => %{"quote_size" => "10"}}
            }
          })
        )
      end

      assert {:error, {:order_field_unavailable, :quantity}} =
               Rest.replace_order(@credentials, "abc-123", %{price: Decimal.new("41000")},
                 plug: plug
               )

      refute_receive {:path, "/api/v3/brokerage/orders/edit"}, 500
    end

    test "the edit body carries both price and size, as strings" do
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:body, conn.request_path, raw})

        if conn.request_path =~ "edit" do
          Plug.Conn.resp(conn, 200, Jason.encode!(%{"success" => true}))
        else
          Plug.Conn.resp(
            conn,
            200,
            Jason.encode!(%{"order" => %{"order_id" => "abc-123", "status" => "OPEN"}})
          )
        end
        |> Plug.Conn.put_resp_content_type("application/json")
      end

      assert {:ok, _order} =
               Rest.replace_order(
                 @credentials,
                 "abc-123",
                 %{price: Decimal.new("41000"), quantity: Decimal.new("0.5")},
                 plug: plug
               )

      assert_receive {:body, path, raw}
      assert path =~ "edit"

      assert Jason.decode!(raw) == %{
               "order_id" => "abc-123",
               "price" => "41000",
               "size" => "0.5"
             }
    end
  end

  test "a normalized or very small number is sent in full notation, never scientific" do
    # `Decimal.to_string/1` defaults to SCIENTIFIC, and `to_string/1` on a `%Decimal{}`
    # reaches the same default through `String.Chars`. So a price or size carrying an
    # exponent went onto the wire as `"1.5E+2"` or `"1E-8"` — not a number this venue
    # reads, and a different order if it read it at all.
    #
    # An exponent is not exotic: `Decimal.normalize/1`, the ordinary way to strip trailing
    # zeros, turns `150.00` into `1.5E+2`, and anything below a millionth carries one by
    # construction. A caller normalising a price before placing an order is doing something
    # entirely reasonable.
    me = self()

    plug = fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(me, {:sent, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(accepted()))
    end

    request =
      limit_request(%{
        price: Decimal.normalize(Decimal.new("150.00")),
        quantity: Decimal.new("0.00000001")
      })

    place(request, plug)

    assert_receive {:sent, body}
    leaf = body["order_configuration"]["limit_limit_gtc"]

    assert leaf["limit_price"] == "150"
    assert leaf["base_size"] == "0.00000001"

    refute String.contains?(leaf["limit_price"], "E")
    refute String.contains?(leaf["base_size"], "E")
  end

  describe "a retried order carries the SAME idempotency key" do
    test "every attempt sends the client_order_id generated for the first" do
      # `Core.HttpClient` retries anything that is not a 4xx, including a timeout and a
      # connection reset — exactly the failures where the venue may have received and acted
      # on the request. That is only safe because this venue documents `client_order_id` as
      # an idempotency key and this package generates one when the caller gives none, so a
      # retry asks the venue to complete the SAME order rather than place another.
      #
      # The property that makes it true is that the key is generated once, while the body is
      # built, and the retry loop re-sends that body unchanged. Nothing pinned it: move the
      # generation inside the loop and every attempt becomes a distinct order, with the
      # suite still green. `dp_exchange_schwab` and `dp_exchange_gemini` have no such key and
      # therefore do not retry these writes at all.
      me = self()

      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        decoded = if raw == "", do: %{}, else: Jason.decode!(raw)
        send(me, {:attempt, decoded["client_order_id"]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, Jason.encode!(%{"message" => "unavailable"}))
      end

      Rest.place_order(@credentials, limit_request(),
        plug: plug,
        retry_attempts: 3,
        retry_delay: 1
      )

      ids = drain_attempts([])

      assert length(ids) > 1,
             "the retry loop must actually have retried for this to mean anything"

      assert Enum.all?(ids, &is_binary/1), "every attempt must carry a client_order_id"
      assert length(Enum.uniq(ids)) == 1, "a retry must not mint a new key: got #{inspect(ids)}"
    end

    defp drain_attempts(acc) do
      receive do
        {:attempt, id} -> drain_attempts([id | acc])
      after
        300 -> Enum.reverse(acc)
      end
    end
  end

  describe "a retried order" do
    test "carries a token minted for its own attempt, not the first attempt's" do
      # The JWT expires 120 seconds after it is minted, and the default retry budget runs
      # past that: a last retry carrying the first attempt's token was refused as a
      # credential failure. Each token carries a random nonce, so two attempts signed
      # separately never share one.
      me = self()

      plug = fn conn ->
        send(me, {:authorization, Plug.Conn.get_req_header(conn, "authorization")})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, Jason.encode!(%{"message" => "unavailable"}))
      end

      Rest.place_order(@credentials, limit_request(),
        plug: plug,
        retry_attempts: 2,
        retry_delay: 1
      )

      assert_received {:authorization, [first]}
      assert_received {:authorization, [second]}
      refute first == second
    end
  end

  describe "an order the caller can track, or an error (2026-10-10)" do
    test "a missing quantity, symbol or side is a named refusal, not a KeyError" do
      for field <- [:quantity, :side] do
        assert {:error, {:missing_field, ^field}} =
                 place(Map.delete(limit_request(), field), responding(accepted()))
      end

      # An absent symbol is `{:invalid_symbol, nil}` on every venue of the family (DV2).
      assert {:error, {:invalid_symbol, nil}} =
               place(Map.delete(limit_request(), :symbol), responding(accepted()))
    end

    test "the placed order echoes Decimals, not the caller's raw values" do
      request = limit_request(%{quantity: "0.5", price: 40_000})
      assert {:ok, order} = place(request, responding(accepted()))
      assert Decimal.equal?(order.quantity, Decimal.new("0.5"))
      assert Decimal.equal?(order.price, Decimal.new(40_000))
    end
  end

  describe "the order of the local checks" do
    test "a request that is not a map is refused, not a BadMapError" do
      for bad <- [nil, [symbol: "BTC-USD"], "order"] do
        assert {:error, {:invalid_order_request, ^bad}} = place(bad, never_sent())
      end
    end

    test "unknown keys come before the symbol" do
      assert {:error, {:unsupported_order_field, :bogus}} =
               place(limit_request(%{symbol: nil, bogus: 1}), never_sent())
    end

    test "symbol, then side, then type, then the pair, then quantity, then prices" do
      assert {:error, {:invalid_symbol, "  "}} =
               place(limit_request(%{symbol: "  ", side: :hold}), never_sent())

      assert {:error, {:invalid_side, :hold}} =
               place(limit_request(%{side: :hold, order_type: :stop}), never_sent())

      assert {:error, {:unsupported_order_type, :stop}} =
               place(limit_request(%{order_type: :stop, time_in_force: :ioc}), never_sent())

      assert {:error, {:unsupported_order_combination, :limit, :ioc}} =
               place(limit_request(%{time_in_force: :ioc, quantity: 0}), never_sent())

      assert {:error, {:invalid_quantity, 0}} =
               place(limit_request(%{quantity: 0, price: "x"}), never_sent())

      assert {:error, {:invalid_price, "x"}} =
               place(limit_request(%{price: "x", client_order_id: ""}), never_sent())

      assert {:error, {:invalid_client_order_id, "  "}} =
               place(limit_request(%{client_order_id: "  "}), never_sent())
    end

    test "a string side is accepted case-insensitively" do
      assert {:ok, %Types.Order{side: :buy}} =
               place(limit_request(%{side: "BUY"}), responding(accepted()))
    end

    test "a float amount is refused: it has already lost digits" do
      assert {:error, {:invalid_quantity, 0.5}} =
               place(limit_request(%{quantity: 0.5}), never_sent())

      assert {:error, {:invalid_price, 40_000.0}} =
               place(limit_request(%{price: 40_000.0}), never_sent())

      assert {:error, {:invalid_stop_price, 1.5}} =
               place(stop_request(%{stop_price: 1.5}), never_sent())

      market = market_request(%{quote_size: 10.0}) |> Map.delete(:quantity)
      assert {:error, {:invalid_quote_size, 10.0}} = place(market, never_sent())
    end

    test "credentials are checked after the request, before anything is sent" do
      assert {:error, {:missing_credentials, :coinbase}} =
               Rest.place_order(%{}, limit_request(), plug: never_sent(), retry_attempts: 0)

      assert {:error, {:invalid_quantity, 0}} =
               Rest.place_order(%{}, limit_request(%{quantity: 0}),
                 plug: never_sent(),
                 retry_attempts: 0
               )
    end
  end

  describe "a write that may have reached the venue is {:order_unconfirmed, id, reason}" do
    defp capturing(response_fun) do
      me = self()

      fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(raw)})
        response_fun.(conn)
      end
    end

    test "a 2xx that is not a map, or carries no success, proves nothing" do
      for body <- [[], "ok", %{}, %{"success_response" => %{"order_id" => "x"}}] do
        assert {:error, {:order_unconfirmed, "mine-1", :unexpected_response_shape}} =
                 place(limit_request(%{client_order_id: "mine-1"}), responding(body))
      end
    end

    test "a generated client_order_id is the one returned" do
      plug = capturing(fn conn -> Plug.Conn.resp(conn, 200, "[]") end)

      assert {:error, {:order_unconfirmed, id, :unexpected_response_shape}} =
               place(limit_request(), plug)

      assert_receive {:sent, %{"client_order_id" => ^id}}, 5_000
      assert byte_size(id) == 36
    end

    test "retries exhausted on a 5xx: unconfirmed, with the id every attempt carried" do
      plug =
        capturing(fn conn ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(503, Jason.encode!(%{"message" => String.duplicate("x", 5_000)}))
        end)

      assert {:error, {:order_unconfirmed, id, {:exchange_error, :coinbase, text}}} =
               Rest.place_order(@credentials, limit_request(),
                 plug: plug,
                 retry_attempts: 2,
                 retry_delay: 1
               )

      assert is_binary(text) and byte_size(text) <= 256
      assert_receive {:sent, %{"client_order_id" => ^id}}, 5_000
      assert_receive {:sent, %{"client_order_id" => ^id}}, 5_000
    end

    test "DUPLICATE_CLIENT_ORDER_ID is unconfirmed, not a rejection" do
      body = %{
        "success" => false,
        "error_response" => %{"new_order_failure_reason" => "DUPLICATE_CLIENT_ORDER_ID"}
      }

      assert {:error, {:order_unconfirmed, "mine-2", :duplicate_client_order_id}} =
               place(limit_request(%{client_order_id: "mine-2"}), responding(body))
    end

    test "other rejections and the venue's 4xx answers stay refusals" do
      assert {:refused, {:order_rejected, "INSUFFICIENT_FUND"}} =
               place(
                 limit_request(),
                 responding(%{
                   "success" => false,
                   "error_response" => %{"new_order_failure_reason" => "INSUFFICIENT_FUND"}
                 })
               )

      assert {:refused, {:venue_error, 400, "bad size"}} =
               place(limit_request(), responding(%{"message" => "bad size"}, 400))
    end

    test "EVERY 4xx to the first attempt is a refusal; 429 is a plain error (DV6)" do
      for status <- [400, 401, 403, 409, 415, 422, 418] do
        assert {:refused, {:venue_error, ^status, "no"}} =
                 place(limit_request(), responding(%{"message" => "no"}, status))
      end

      assert {:error, reason} = place(limit_request(), responding(%{"message" => "slow"}, 429))
      refute match?({:order_unconfirmed, _id, _why}, reason)

      # The same for the other writes that share the decision.
      assert {:refused, {:venue_error, 409, "no"}} =
               Rest.close_position(@credentials, "BTC-USD",
                 plug: responding(%{"message" => "no"}, 409),
                 retry_attempts: 0
               )
    end

    test "a 4xx answered to an internal retry is unconfirmed, not a refusal (DV6)" do
      for answer <- [400, 409, 422] do
        counter = :counters.new(1, [])

        plug = fn conn ->
          :counters.add(counter, 1, 1)
          status = if :counters.get(counter, 1) == 1, do: 503, else: answer

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(status, Jason.encode!(%{"message" => "x"}))
        end

        id = "retry-#{answer}"

        assert {:error, {:order_unconfirmed, ^id, _reason}} =
                 Rest.place_order(
                   @credentials,
                   limit_request(%{client_order_id: id}),
                   plug: plug,
                   retry_attempts: 3,
                   retry_delay: 1
                 )

        # One 503, then the 4xx: exactly two attempts were sent.
        assert :counters.get(counter, 1) == 2
      end
    end

    test "our own rate limiter refusing is decided before sending: a plain error" do
      Config.put_override(:rate_limit_module, ThrottlingLimiter)

      assert {:error, {:exchange_error, :coinbase, "Throttled by our own rate limiter" <> _rest}} =
               place(limit_request(), never_sent())
    end

    test "the limiter refusing a retry after a 5xx was sent is unconfirmed, not plain" do
      Config.put_override(:rate_limit_module, RefuseAfterFirstLimiter)
      me = self()

      plug = fn conn ->
        send(me, :attempt_sent)
        Plug.Conn.resp(conn, 503, Jason.encode!(%{"message" => "down"}))
      end

      assert {:error, {:order_unconfirmed, id, {:exchange_error, :coinbase, text}}} =
               Rest.place_order(@credentials, limit_request(),
                 plug: plug,
                 retry_attempts: 3,
                 retry_delay: 1
               )

      assert byte_size(id) == 36
      assert text =~ "Throttled by our own rate limiter"
      assert_receive :attempt_sent, 5_000
      refute_received :attempt_sent

      # The same for close_position/3, with the limiter's first-request allowance reset.
      Process.put(:first_acquire_done, false)

      assert {:error, {:order_unconfirmed, "close-2", {:exchange_error, :coinbase, _text}}} =
               Rest.close_position(@credentials, "BTC-USD",
                 client_order_id: "close-2",
                 plug: plug,
                 retry_attempts: 3,
                 retry_delay: 1
               )
    end

    test "a signing failure is a plain error, nothing was sent" do
      assert {:error, :invalid_base64} =
               Rest.place_order(
                 %{@credentials | api_secret: "not base64 !!"},
                 limit_request(),
                 plug: never_sent(),
                 retry_attempts: 0
               )
    end

    test "close_position carries its client_order_id the same way" do
      assert {:error, {:order_unconfirmed, "close-1", :unexpected_response_shape}} =
               Rest.close_position(@credentials, "BTC-USD",
                 client_order_id: "close-1",
                 plug: responding([]),
                 retry_attempts: 0
               )
    end
  end

  describe "replace_order/4 and the unconfirmed / unread answers" do
    @edit %{price: Decimal.new("41000"), quantity: Decimal.new("0.5")}

    defp replace(plug, order_id \\ "abc-123") do
      Rest.replace_order(@credentials, order_id, @edit, plug: plug)
    end

    test "a 2xx that is not a success answer is unconfirmed, with no client_order_id" do
      for body <- [[], %{}, "ok"] do
        assert {:error, {:order_unconfirmed, nil, :unexpected_response_shape}} =
                 replace(responding(body))
      end
    end

    test "a 5xx on the edit is unconfirmed (sent once)" do
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        responding(%{"message" => "down"}, 503).(conn)
      end

      assert {:error, {:order_unconfirmed, nil, {:exchange_error, :coinbase, _text}}} =
               replace(plug)

      # An edit has no idempotency key: a retry would be a second edit, so it is sent once.
      assert :counters.get(counter, 1) == 1
    end

    test "an accepted edit whose read-back fails is replace_accepted_unread" do
      # JSON content type, or the body arrives undecoded as a string and reads as unusable.
      plug = fn conn ->
        conn = Plug.Conn.put_resp_content_type(conn, "application/json")

        if conn.request_path =~ "edit",
          do: Plug.Conn.resp(conn, 200, Jason.encode!(%{"success" => true})),
          else: Plug.Conn.resp(conn, 404, Jason.encode!(%{"message" => "gone"}))
      end

      assert {:error, {:replace_accepted_unread, "abc-123", :not_found}} = replace(plug)
    end

    test "a refused edit stays a refusal and a blank id is refused locally" do
      assert {:refused, {:venue_error, 400, "no"}} =
               replace(responding(%{"message" => "no"}, 400))

      for bad <- [nil, "", "  ", :abc] do
        assert {:error, {:invalid_order_id, ^bad}} = replace(never_sent(), bad)
      end
    end
  end

  describe "orders that are not there are :not_found; transport keeps its tag" do
    test "a 404 on an order read or cancel is {:refused, :not_found}" do
      gone = responding(%{"message" => "gone"}, 404)
      opts = [plug: gone, retry_attempts: 0]

      assert {:refused, :not_found} = Rest.get_order(@credentials, "abc", opts)
      # A cancel is sent once and reads no retry keys.
      assert {:refused, :not_found} = Rest.cancel_order(@credentials, "abc", plug: gone)
    end

    test "a 404 on a symbol is still :not_listed" do
      assert {:refused, :not_listed} =
               Rest.get_price("NOPE-USD", plug: responding(%{}, 404), retry_attempts: 0)
    end

    test "a transport failure keeps Core's {:exchange_error, :coinbase, message} tag" do
      assert {:error, {:exchange_error, :coinbase, message}} =
               Rest.get_order(@credentials, "abc",
                 plug: responding(%{"message" => "down"}, 503),
                 retry_attempts: 0
               )

      assert is_binary(message)
    end

    test "an order id that is blank is refused before credentials and the wire" do
      for bad <- [nil, "", "  ", :abc, %{}] do
        assert {:error, {:invalid_order_id, ^bad}} =
                 Rest.get_order(%{}, bad, plug: never_sent(), retry_attempts: 0)

        assert {:error, {:invalid_order_id, ^bad}} =
                 Rest.cancel_order(%{}, bad, plug: never_sent())
      end
    end
  end
end

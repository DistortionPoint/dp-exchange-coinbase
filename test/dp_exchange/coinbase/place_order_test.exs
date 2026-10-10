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

      refute_receive :request_was_sent
    end

    test "credentials that cannot sign at all are refused by name" do
      me = self()

      plug = fn conn ->
        send(me, :request_was_sent)
        Plug.Conn.resp(conn, 200, "{}")
      end

      assert {:error, {:missing_credentials, :coinbase}} =
               Rest.place_order(%{}, limit_request(), plug: plug, retry_attempts: 0)

      refute_receive :request_was_sent
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

    test "both a base quantity and a quote size is refused before anything is sent" do
      # This used to be "a base quantity wins". Two sizes describe two different orders,
      # and choosing one spent money on an order the caller did not describe (2026-10-10).
      me = self()

      plug = fn conn ->
        send(me, :sent)
        conn |> Plug.Conn.put_resp_content_type("application/json") |> Plug.Conn.resp(200, "{}")
      end

      request =
        limit_request(%{order_type: :market, time_in_force: :ioc, quote_size: Decimal.new("100")})

      assert {:error, :ambiguous_order_size} = place(request, plug)
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

      assert {:error, {:unsupported_order_field, :post_only, {:limit, :fok}}} =
               place(
                 limit_request(%{time_in_force: :fok, post_only: true}),
                 exploding
               )

      assert {:error, {:unsupported_order_field, :post_only, {:stop_limit, :gtc}}} =
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

      assert {:error, {:unsupported_order_field, :end_time, {:limit, :fok}}} =
               place(
                 limit_request(%{time_in_force: :fok, end_time: "2026-09-01T00:00:00Z"}),
                 exploding
               )

      assert {:error, {:unsupported_order_field, :end_time, {:limit, :gtc}}} =
               place(limit_request(%{end_time: "2026-09-01T00:00:00Z"}), exploding)

      assert {:error, {:unsupported_order_field, :end_time, {:stop_limit, :gtc}}} =
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
                 plug: plug,
                 retry_attempts: 0
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
                 plug: responding(body),
                 retry_attempts: 0
               )
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
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "changing anything but price or size is refused, not silently dropped" do
      # A caller trying to change the side is describing a different order. Editing only the
      # price would leave it holding one it did not ask for.
      exploding = fn _conn -> raise "must not call the venue for an unsupported edit" end

      assert {:error, {:unsupported_order_edit, [:side]}} =
               Rest.replace_order(@credentials, "abc-123", %{side: :sell},
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "an edit that changes nothing is an error" do
      exploding = fn _conn -> raise "must not call the venue with no changes" end

      assert {:error, :no_order_changes} =
               Rest.replace_order(@credentials, "abc-123", %{},
                 plug: exploding,
                 retry_attempts: 0
               )
    end

    test "price alone, or size alone, is refused locally rather than sent half-built" do
      # `EditOrderRequest` requires order_id, price AND size, all three
      # (docs/reference/coinbase/openapi/at-spec.yaml:6809-6852). This used to send whichever
      # one the caller supplied and drop the other with `put_unless_nil/3` — a body shape the
      # venue does not document and this package never measured the venue's handling of.
      exploding = fn _conn -> raise "must not send a half-built edit" end

      assert {:error, :missing_required_edit_field} =
               Rest.replace_order(@credentials, "abc-123", %{price: Decimal.new("41000")},
                 plug: exploding,
                 retry_attempts: 0
               )

      assert {:error, :missing_required_edit_field} =
               Rest.replace_order(@credentials, "abc-123", %{quantity: Decimal.new("0.5")},
                 plug: exploding,
                 retry_attempts: 0
               )
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
                 plug: plug,
                 retry_attempts: 0
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
      for field <- [:quantity, :symbol, :side] do
        assert {:error, {:missing_field, ^field}} =
                 place(Map.delete(limit_request(), field), responding(accepted()))
      end
    end

    test "the placed order echoes Decimals, not the caller's raw values" do
      request = limit_request(%{quantity: "0.5", price: 40_000})
      assert {:ok, order} = place(request, responding(accepted()))
      assert Decimal.equal?(order.quantity, Decimal.new("0.5"))
      assert Decimal.equal?(order.price, Decimal.new(40_000))
    end
  end
end

defmodule DpExchange.Coinbase.PrivateSurfaceReviewTest do
  @moduledoc """
  The private surface refuses a malformed argument by name, before a request, and the fake
  refuses the same things in the same shapes.

  Each of these used to raise in the caller's process (`FunctionClauseError` on a non-string
  id, `Protocol.UndefinedError` building a query from a map) or went to the venue as given
  (an enum filter outside the spec's list, a `limit` of 0, an inverted fill window), and the
  fake answered `:ok` for most of them.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Fake, IdempotencyKey, Prime, Rest}
  alias DpExchange.Core.Config

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

  @summary %{"fee_tier" => %{"taker_fee_rate" => "0.001"}}
  @base "/api/v3/brokerage"

  # Reports every request that reaches the venue to the test process, then answers `body`.
  defp capturing(body) do
    test_pid = self()

    fn conn ->
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_string})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp opts(body \\ %{}, extra \\ []),
    do: Keyword.merge([plug: capturing(body), retry_attempts: 0], extra)

  describe "an id that becomes a path segment" do
    test "must be a non-empty string; anything else is refused without a request" do
      for bad <- [nil, 1, %{}, :atom, ""] do
        conversion = opts(%{}, from: "a", to: "b")

        assert {:error, {:invalid_id, :payment_method_id, ^bad}} =
                 Rest.get_payment_method(@credentials, bad, opts())

        assert {:error, {:invalid_id, :portfolio_uuid, ^bad}} =
                 Rest.get_portfolio_breakdown(@credentials, bad, opts())

        assert {:error, {:invalid_id, :portfolio_uuid, ^bad}} =
                 Rest.delete_portfolio(@credentials, bad, opts())

        assert {:error, {:invalid_id, :portfolio_uuid, ^bad}} =
                 Rest.rename_portfolio(@credentials, bad, "Name", opts())

        assert {:error, {:invalid_id, :trade_id, ^bad}} =
                 Rest.commit_conversion(@credentials, bad, conversion)

        assert {:error, {:invalid_id, :trade_id, ^bad}} =
                 Rest.get_conversion(@credentials, bad, conversion)

        assert {:error, {:invalid_id, :product_id, ^bad}} =
                 Rest.get_futures_position(@credentials, bad, opts())
      end

      refute_received {:request, _method, _path, _query}
    end

    test "a portfolio name must be a non-empty string on create and on rename" do
      for bad <- [nil, "", 1, %{}] do
        assert {:error, :name_required} =
                 Rest.rename_portfolio(@credentials, "pf-1", bad, opts())

        assert {:error, :name_required} =
                 Rest.create_portfolio(@credentials, [name: bad] ++ opts())
      end

      refute_received {:request, _method, _path, _query}
    end

    test "the fake refuses the same ids in the same shapes" do
      for bad <- [nil, 1, %{}, "", "  "] do
        assert Fake.get_order(@credentials, bad) == {:error, {:invalid_order_id, bad}}
        assert Fake.cancel_order(@credentials, bad) == {:error, {:invalid_order_id, bad}}

        assert Fake.get_payment_method(@credentials, bad) ==
                 {:error, {:invalid_id, :payment_method_id, bad}}

        assert Fake.rename_account(bad, "Name", credentials: @credentials) ==
                 {:error, {:invalid_id, :portfolio_uuid, bad}}

        assert Fake.commit_conversion(bad, from: "a", to: "b", credentials: @credentials) ==
                 {:error, {:invalid_id, :trade_id, bad}}

        assert Fake.get_conversion(bad, from: "a", to: "b", credentials: @credentials) ==
                 {:error, {:invalid_id, :trade_id, bad}}
      end

      for bad <- [1, %{}, ""] do
        assert Fake.get_accounts(@credentials, uuid: bad) == {:error, {:invalid_id, :uuid, bad}}

        assert {:error, {:invalid_id, :uuid, ^bad}} =
                 Rest.get_accounts(@credentials, [uuid: bad] ++ opts())
      end

      for bad <- [nil, "", 1, %{}] do
        assert Fake.rename_account("pf-1", bad, credentials: @credentials) ==
                 {:error, :name_required}

        assert Fake.create_account(name: bad, credentials: @credentials) ==
                 {:error, :name_required}
      end
    end
  end

  describe "the accounts page size" do
    test "is an integer in 1..250 on balances and accounts, or nothing is sent" do
      for bad <- [0, -1, 251, "5", %{}, 1.5] do
        assert {:error, {:invalid_limit, ^bad}} =
                 Rest.get_balances(@credentials, [limit: bad] ++ opts())

        assert {:error, {:invalid_limit, ^bad}} =
                 Rest.get_accounts(@credentials, [limit: bad] ++ opts())

        assert Fake.get_balances(@credentials, limit: bad) == {:error, {:invalid_limit, bad}}
        assert Fake.get_accounts(@credentials, limit: bad) == {:error, {:invalid_limit, bad}}
      end

      refute_received {:request, _method, _path, _query}
    end

    test "250 is the documented maximum and is sent" do
      body = %{"accounts" => [], "has_next" => false}

      assert {:ok, []} = Rest.get_balances(@credentials, [limit: 250] ++ opts(body))
      assert_receive {:request, "GET", @base <> "/accounts", "limit=250"}, 5_000
    end
  end

  describe "enum filters" do
    test "get_fees/2 and get_trade_volume/2 send only the spec's words" do
      filters = [product_type: "SPOT", contract_expiry_type: "PERPETUAL", product_venue: "CBE"]

      assert {:ok, _fees} = Rest.get_fees(@credentials, filters ++ opts(@summary))

      assert_receive {:request, "GET", @base <> "/transaction_summary", query}, 5_000
      assert query =~ "product_type=SPOT"
      assert query =~ "contract_expiry_type=PERPETUAL"
      assert query =~ "product_venue=CBE"

      for {key, bad} <- [
            {:product_type, "spot"},
            {:product_type, :SPOT},
            {:product_type, %{}},
            {:contract_expiry_type, "WEEKLY"},
            {:product_venue, "NYSE"}
          ] do
        expected = {:error, {:invalid_option, key, bad}}
        filtered = [{key, bad}]

        assert expected == Rest.get_fees(@credentials, filtered ++ opts(@summary))
        assert expected == Rest.get_trade_volume(@credentials, filtered ++ opts(@summary))
        assert expected == Fake.get_fees(@credentials, filtered)
        assert expected == Fake.get_trade_volume(@credentials, filtered)
      end

      refute_received {:request, _method, _path, _query}
    end

    test "list_portfolios/2 sends only the spec's portfolio types" do
      assert {:ok, []} =
               Rest.list_portfolios(
                 @credentials,
                 [portfolio_type: "CONSUMER"] ++ opts(%{"portfolios" => []})
               )

      assert_receive {:request, "GET", @base <> "/portfolios", "portfolio_type=CONSUMER"}, 5_000

      for bad <- ["consumer", "FUTURE", %{}, 1] do
        expected = {:error, {:invalid_option, :portfolio_type, bad}}

        assert expected == Rest.list_portfolios(@credentials, [portfolio_type: bad] ++ opts())
        assert expected == Fake.list_portfolios(credentials: @credentials, portfolio_type: bad)
      end

      refute_received {:request, _method, _path, _query}
    end

    test "get_current_margin_window/2 sends only the spec's margin profile types" do
      regular = "MARGIN_PROFILE_TYPE_RETAIL_REGULAR"

      window = [margin_profile_type: regular] ++ opts()
      assert {:ok, _window} = Rest.get_current_margin_window(@credentials, window)

      assert_receive {:request, "GET", _path, query}, 5_000
      assert query == "margin_profile_type=" <> regular

      assert {:error, {:invalid_option, :margin_profile_type, "RETAIL"}} =
               Rest.get_current_margin_window(
                 @credentials,
                 [margin_profile_type: "RETAIL"] ++ opts()
               )

      refute_received {:request, _method, _path, _query}
    end

    test "a portfolio breakdown currency must be a non-empty string" do
      for bad <- ["", 1, %{}] do
        assert {:error, {:invalid_option, :currency, ^bad}} =
                 Rest.get_portfolio_breakdown(@credentials, "pf-1", [currency: bad] ++ opts())
      end

      refute_received {:request, _method, _path, _query}
    end
  end

  describe "fill filters" do
    test "order ids are strings and are sent as repeated keys" do
      body = %{"fills" => [], "cursor" => ""}

      assert {:ok, []} =
               Rest.get_trade_history(@credentials, [order_id: ["o-1", "o-2"]] ++ opts(body))

      assert_receive {:request, "GET", @base <> "/orders/historical/fills", query}, 5_000
      assert query == "order_ids=o-1&order_ids=o-2"
    end

    test "a bad order id, bound or window is refused locally, in the fake too" do
      early = ~U[2026-08-01 00:00:00Z]
      late = ~U[2026-08-02 00:00:00Z]

      for {filter, expected} <- [
            {[order_id: ""], {:error, {:invalid_order_id, ""}}},
            {[order_id: [1]], {:error, {:invalid_order_id, [1]}}},
            {[order_id: %{}], {:error, {:invalid_order_id, %{}}}},
            {[start: "2026-08-01"], {:error, {:invalid_time, :start, "2026-08-01"}}},
            {[end: %{}], {:error, {:invalid_time, :end, %{}}}},
            {[start: late, end: early], {:error, {:invalid_range, [start: late, end: early]}}},
            {[start: early, end: early], {:error, {:invalid_range, [start: early, end: early]}}}
          ] do
        assert expected == Rest.get_trade_history(@credentials, filter ++ opts())
        assert expected == Fake.get_trade_history(@credentials, filter)
      end

      refute_received {:request, _method, _path, _query}
    end

    test "an ordered window is sent in RFC 3339" do
      body = %{"fills" => [], "cursor" => ""}
      window = [start: ~U[2026-08-01 00:00:00Z], end: ~U[2026-08-02 00:00:00Z]]

      assert {:ok, []} = Rest.get_trade_history(@credentials, window ++ opts(body))
      assert_receive {:request, "GET", _path, query}, 5_000
      assert query =~ "start_sequence_timestamp=2026-08-01T00%3A00%3A00Z"
      assert query =~ "end_sequence_timestamp=2026-08-02T00%3A00%3A00Z"
    end
  end

  describe "conversions and transfers" do
    test "a quote needs a positive Decimal and named accounts, in the fake too" do
      amount = Decimal.new("1")

      for {from, to, amt, expected} <- [
            {"USD", "USDC", 1.5, {:error, {:invalid_amount, 1.5}}},
            {"USD", "USDC", Decimal.new("0"), {:error, {:invalid_amount, Decimal.new("0")}}},
            {nil, "USDC", amount, {:error, {:invalid_id, :from, nil}}},
            {"USD", "", amount, {:error, {:invalid_id, :to, ""}}}
          ] do
        assert expected == Rest.quote_conversion(@credentials, from, to, amt, opts())
        assert expected == Fake.quote_conversion(from, to, amt, credentials: @credentials)
      end

      refute_received {:request, _method, _path, _query}
    end

    test "an empty account on a commit or a read is the same refusal as a missing one" do
      for conversion <- [[from: "", to: "b"], [from: "a", to: ""]] do
        assert {:error, :from_and_to_required} =
                 Rest.commit_conversion(@credentials, "t-1", conversion ++ opts())

        assert {:error, :from_and_to_required} =
                 Rest.get_conversion(@credentials, "t-1", conversion ++ opts())
      end

      refute_received {:request, _method, _path, _query}
    end

    test "a transfer needs an asset and both portfolios named" do
      amount = Decimal.new("1")

      for asset <- [nil, "", 1] do
        expected = {:error, {:invalid_asset, asset}}
        transfer = [from: "a", to: "b"]

        auth = [credentials: @credentials]

        assert expected == Rest.transfer_internal(@credentials, asset, amount, transfer ++ opts())
        assert expected == Fake.transfer_internal(asset, amount, transfer, auth)
      end

      for transfer <- [[from: "", to: "b"], [from: "a", to: ""]] do
        assert {:error, :missing_portfolio} =
                 Rest.transfer_internal(@credentials, "USD", amount, transfer ++ opts())

        assert {:error, :missing_portfolio} =
                 Fake.transfer_internal("USD", amount, transfer, credentials: @credentials)
      end

      assert {:error, {:invalid_amount, 2}} =
               Fake.transfer_internal("USD", 2, [from: "a", to: "b"], credentials: @credentials)

      refute_received {:request, _method, _path, _query}
    end

    test "the fake issues a new conversion id per quote and keeps each one's state" do
      auth = [credentials: @credentials]
      conversion = [from: "USD", to: "USDC"] ++ auth

      assert {:ok, first} = Fake.quote_conversion("USD", "USDC", Decimal.new("1"), auth)
      assert {:ok, %{status: :committed}} = Fake.commit_conversion(first.id, conversion)
      assert {:ok, second} = Fake.quote_conversion("USD", "USDC", Decimal.new("2"), auth)

      assert first.id != second.id
      assert {:ok, %{status: :settled}} = Fake.get_conversion(first.id, conversion)
      assert {:ok, %{status: :quoted}} = Fake.get_conversion(second.id, conversion)
    end
  end

  describe "futures sweeps" do
    test "a 200 saying success false is a refusal, not an ok" do
      declined = opts(%{"success" => false})

      assert {:refused, :sweep_not_scheduled} =
               Rest.schedule_futures_sweep(@credentials, [usd_amount: "5"] ++ declined)

      assert {:refused, :sweep_not_cancelled} = Rest.cancel_futures_sweep(@credentials, declined)
    end

    test "success true, and a body that does not say, are passed through" do
      assert {:ok, %{"success" => true}} =
               Rest.schedule_futures_sweep(@credentials, opts(%{"success" => true}))

      assert {:ok, %{}} = Rest.cancel_futures_sweep(@credentials, opts(%{}))
    end
  end

  describe "closing a position" do
    test "refuses a bad symbol, client order id or size the same way in the fake" do
      for {close_opts, symbol, expected} <- [
            {[], nil, {:error, {:invalid_symbol, nil}}},
            {[], "", {:error, {:invalid_symbol, ""}}},
            {[client_order_id: ""], "BIT-28JUL23-CDE", {:error, {:invalid_client_order_id, ""}}},
            {[size: "abc"], "BIT-28JUL23-CDE", {:error, {:invalid_quantity, "abc"}}},
            {[size: 0], "BIT-28JUL23-CDE", {:error, {:invalid_quantity, 0}}}
          ] do
        assert expected == Rest.close_position(@credentials, symbol, close_opts ++ opts())
        assert expected == Fake.close_position(@credentials, symbol, close_opts)
      end

      refute_received {:request, _method, _path, _query}
    end
  end

  describe "editing an order" do
    test "the fake refuses an id the real call refuses, before the credential" do
      changes = %{price: "1", quantity: "1"}
      expected = {:error, {:invalid_order_id, nil}}

      assert expected == Rest.replace_order(@credentials, nil, changes, opts())
      assert expected == Rest.preview_replace(@credentials, nil, changes, opts())
      assert expected == Fake.replace_order(@credentials, nil, changes)
      assert expected == Fake.preview_replace(@credentials, nil, changes)
      assert expected == Fake.replace_order(%{}, nil, changes)

      refute_received {:request, _method, _path, _query}
    end

    test "a stated preview failure reason is not hidden behind an unset edit reason" do
      changes = %{price: "1", quantity: "1"}

      for {errors, reason} <- [
            {[
               %{
                 "edit_failure_reason" => "UNKNOWN_EDIT_ORDER_FAILURE_REASON",
                 "preview_failure_reason" => "PREVIEW_INVALID_LIMIT_PRICE"
               }
             ], "PREVIEW_INVALID_LIMIT_PRICE"},
            {[
               %{
                 "edit_failure_reason" => "ORDER_NOT_FOUND",
                 "preview_failure_reason" => "PREVIEW_INVALID_LIMIT_PRICE"
               }
             ], "ORDER_NOT_FOUND"},
            {[
               %{
                 "edit_failure_reason" => "UNKNOWN_EDIT_ORDER_FAILURE_REASON",
                 "preview_failure_reason" => "UNKNOWN_PREVIEW_FAILURE_REASON"
               }
             ], "UNKNOWN_EDIT_ORDER_FAILURE_REASON"},
            {[%{"preview_failure_reason" => "PREVIEW_INVALID_PRICE_PRECISION"}],
             "PREVIEW_INVALID_PRICE_PRECISION"},
            {[], :unspecified}
          ] do
        body = %{"success" => false, "errors" => errors}

        assert {:refused, {:edit_rejected, ^reason}} =
                 Rest.replace_order(@credentials, "ord-1", changes, opts(body))
      end
    end
  end

  describe "Prime transaction validators" do
    @prime %{access_key: "k", passphrase: "p", signing_key: "s"}

    test "take at most 100 ids, each a non-empty string" do
      good = Enum.map(1..100, &"tx-#{&1}")
      too_many = good ++ ["tx-101"]

      for bad <- [too_many, [1], ["a", ""], ["a", nil], ["a" | "b"]] do
        assert {:error, {:invalid_transaction_ids, ^bad}} =
                 Prime.query_transaction_validators(
                   @prime,
                   "pf-1",
                   [transaction_ids: bad] ++ opts()
                 )
      end

      refute_received {:request, _method, _path, _query}

      assert {:ok, _result} =
               Prime.query_transaction_validators(
                 @prime,
                 "pf-1",
                 [transaction_ids: good] ++ opts()
               )

      assert_receive {:request, "POST", path, ""}, 5_000
      assert path == "/v1/portfolios/pf-1/staking/transaction-validators/query"
    end

    test "none at all is still the missing-ids refusal" do
      assert {:error, :missing_transaction_ids} =
               Prime.query_transaction_validators(@prime, "pf-1", opts())

      assert {:error, :missing_transaction_ids} =
               Prime.query_transaction_validators(
                 @prime,
                 "pf-1",
                 [transaction_ids: []] ++ opts()
               )
    end
  end

  describe "IdempotencyKey" do
    test "generates canonical v4 UUIDs that do not repeat" do
      keys = for _n <- 1..200, do: IdempotencyKey.generate()

      for key <- keys do
        assert key =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
      end

      assert length(Enum.uniq(keys)) == 200
    end
  end
end

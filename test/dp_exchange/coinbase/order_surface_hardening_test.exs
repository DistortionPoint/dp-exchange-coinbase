defmodule DpExchange.Coinbase.OrderSurfaceHardeningTest do
  @moduledoc """
  Tick J: what the order, sweep, conversion, history and Prime paths refuse instead of
  raising in the caller's process, sending a billion-character amount, or silently dropping.

  Every refusal case uses a plug that raises if the venue is called, so a value that reaches
  the wire fails the test rather than passing it.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Fake, Prime, Rest}
  alias DpExchange.Core.Config

  @moduletag :capture_log

  @wait 5_000

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

  @prime_credentials %{
    access_key: "prime-key",
    passphrase: "prime-passphrase",
    signing_key: "prime-signing-key"
  }

  # An exponent no venue quotes. Built as a literal: `Decimal.new/1` raises on it.
  @huge %Decimal{sign: 1, coef: 1, exp: 999_999_999}

  defp capturing(body, pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(pid, {:sent, conn.request_path, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
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

  describe "a request or edit that is not a map" do
    test "place_order and preview_order refuse it before anything is sent" do
      for bad <- [nil, [symbol: "BTC-USD"], "BTC-USD"] do
        assert {:error, {:invalid_order_request, ^bad}} =
                 Rest.place_order(@credentials, bad, opts(never_sent()))

        assert {:error, {:invalid_order_request, ^bad}} =
                 Rest.preview_order(@credentials, bad, opts(never_sent()))

        assert {:error, {:invalid_order_request, ^bad}} = Rest.order_plan(bad, :place)
      end
    end

    test "replace_order and preview_replace refuse changes that are not a map" do
      for bad <- [nil, [price: 1], "x"] do
        assert {:error, {:invalid_order_changes, ^bad}} =
                 Rest.replace_order(@credentials, "abc-123", bad, opts(never_sent()))

        assert {:error, {:invalid_order_changes, ^bad}} =
                 Rest.preview_replace(@credentials, "abc-123", bad, opts(never_sent()))

        assert {:error, {:invalid_order_changes, ^bad}} = Rest.validate_order_edit(bad)
      end
    end
  end

  describe "an amount with an absurd scale" do
    test "an order price, size or stop of 1E+999999999 is refused, not rendered" do
      for {field, tag} <- [price: :invalid_price, quantity: :invalid_quantity] do
        assert {:error, {^tag, _value}} =
                 Rest.place_order(
                   @credentials,
                   limit_request(%{field => @huge}),
                   opts(never_sent())
                 )
      end
    end

    test "a float whose plain notation would be hundreds of digits is refused" do
      assert {:error, {:invalid_price, 1.0e300}} =
               Rest.place_order(
                 @credentials,
                 limit_request(%{price: 1.0e300}),
                 opts(never_sent())
               )
    end

    test "an edit with an absurd price is refused" do
      assert {:error, {:invalid_price, _value}} =
               Rest.replace_order(
                 @credentials,
                 "abc-123",
                 %{price: @huge, quantity: Decimal.new("1")},
                 opts(never_sent())
               )
    end

    test "a conversion quote, an internal transfer and a Prime stake refuse it" do
      assert {:error, {:invalid_amount, @huge}} =
               Rest.quote_conversion(@credentials, "USD", "USDC", @huge, opts(never_sent()))

      assert {:error, {:invalid_amount, @huge}} =
               Rest.transfer_internal(
                 @credentials,
                 "USD",
                 @huge,
                 opts(never_sent()) ++ [from: "a", to: "b"]
               )

      assert {:error, {:invalid_amount, @huge}} =
               Prime.stake_portfolio(
                 @prime_credentials,
                 "pf-1",
                 "ETH",
                 @huge,
                 opts(never_sent())
               )

      assert {:error, {:invalid_amount, @huge}} =
               Prime.stake_wallet(
                 @prime_credentials,
                 "pf-1",
                 "w-1",
                 "ETH",
                 @huge,
                 opts(never_sent())
               )
    end
  end

  describe "perpetual order fields" do
    test "leverage and margin_type are sent when the request names them" do
      me = self()

      assert {:ok, _order} =
               Rest.place_order(
                 @credentials,
                 limit_request(%{leverage: 5, margin_type: :isolated}),
                 opts(capturing(accepted(), me))
               )

      assert_receive {:sent, _path, raw}, @wait
      body = Jason.decode!(raw)
      assert body["leverage"] == "5"
      assert body["margin_type"] == "ISOLATED"
    end

    test "they are not sent when the request does not name them" do
      me = self()

      assert {:ok, _order} =
               Rest.place_order(@credentials, limit_request(), opts(capturing(accepted(), me)))

      assert_receive {:sent, _path, raw}, @wait
      body = Jason.decode!(raw)
      refute Map.has_key?(body, "leverage")
      refute Map.has_key?(body, "margin_type")
    end

    test "preview_order carries them too" do
      me = self()

      assert {:ok, _preview} =
               Rest.preview_order(
                 @credentials,
                 limit_request(%{leverage: "2.5", margin_type: "CROSS"}),
                 opts(capturing(%{"order_total" => "1", "errs" => []}, me))
               )

      assert_receive {:sent, _path, raw}, @wait
      body = Jason.decode!(raw)
      assert body["leverage"] == "2.5"
      assert body["margin_type"] == "CROSS"
    end

    test "a leverage or margin type the schema does not describe is refused" do
      for bad <- [0, -1, "abc", "", @huge] do
        assert {:error, {:invalid_leverage, ^bad}} =
                 Rest.place_order(
                   @credentials,
                   limit_request(%{leverage: bad}),
                   opts(never_sent())
                 )
      end

      for bad <- [:portfolio, "cross", 1] do
        assert {:error, {:invalid_margin_type, ^bad}} =
                 Rest.place_order(
                   @credentials,
                   limit_request(%{margin_type: bad}),
                   opts(never_sent())
                 )
      end

      assert {:error, {:invalid_leverage, 0}} =
               Rest.order_plan(limit_request(%{leverage: 0}), :place)
    end
  end

  describe "schedule_futures_sweep/2 amounts" do
    test "a present amount that is not a finite positive number is refused" do
      # A float is refused on this money-moving amount as on an order field: it has already
      # lost digits before it gets here.
      for bad <- ["", "abc", 0, "0", -5, "-1", @huge, Decimal.new("NaN"), %{}, 150.0, 1.5e-8] do
        sweep_opts = [usd_amount: bad] ++ opts(never_sent())

        assert {:error, {:invalid_amount, ^bad}} =
                 Rest.schedule_futures_sweep(@credentials, sweep_opts)
      end
    end

    test "a valid amount is sent in plain notation, and an absent one is sent as nothing" do
      me = self()

      assert {:ok, _result} =
               Rest.schedule_futures_sweep(
                 @credentials,
                 [usd_amount: "150.0"] ++ opts(capturing(%{"success" => true}, me))
               )

      assert_receive {:sent, _path, raw}, @wait
      assert Jason.decode!(raw) == %{"usd_amount" => "150.0"}

      assert {:ok, _result} =
               Rest.schedule_futures_sweep(@credentials, opts(capturing(%{"ok" => 1}, me)))

      assert_receive {:sent, _path, raw}, @wait
      assert Jason.decode!(raw) == %{}
    end
  end

  describe "get_orders/2 and get_trade_history/2 filters" do
    test "a symbol filter that is not a non-empty string or a list of them is refused" do
      for bad <- [:btc, "", [nil], [], ["BTC-USD", 5]] do
        assert {:error, {:invalid_symbol, _bad}} =
                 Rest.get_orders(@credentials, [symbol: bad] ++ opts(never_sent()))

        assert {:error, {:invalid_symbol, _bad}} =
                 Rest.get_trade_history(@credentials, [symbol: bad] ++ opts(never_sent()))
      end
    end

    test "a page size that is not a positive integer is refused" do
      for bad <- [0, -5, "25", 2.5] do
        assert {:error, {:invalid_limit, ^bad}} =
                 Rest.get_orders(@credentials, [limit: bad] ++ opts(never_sent()))

        assert {:error, {:invalid_limit, ^bad}} =
                 Rest.get_trade_history(@credentials, [limit: bad] ++ opts(never_sent()))
      end
    end

    test "trade_types must be a list of strings, before any page is fetched" do
      for bad <- ["FILL", [:fill], 5] do
        assert {:error, {:invalid_trade_types, ^bad}} =
                 Rest.get_trade_history(@credentials, [trade_types: bad] ++ opts(never_sent()))
      end
    end

    test "a list of symbols is sent as repeated product_ids" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"fills" => []}))
      end

      assert {:ok, []} =
               Rest.get_trade_history(
                 @credentials,
                 [symbol: ["BTC-USD", "ETH-USD"]] ++ opts(plug)
               )

      assert_receive {:query, query}, @wait
      assert query =~ "product_ids=BTC-USD"
      assert query =~ "product_ids=ETH-USD"
    end
  end

  describe "Prime options that are not the shape they are read as" do
    test "extra must be a map" do
      for bad <- ["x", [1, 2], 5] do
        assert {:error, {:invalid_extra, ^bad}} =
                 Prime.stake_portfolio(
                   @prime_credentials,
                   "pf-1",
                   "ETH",
                   Decimal.new("1"),
                   opts(never_sent()) ++ [extra: bad]
                 )

        assert {:error, {:invalid_extra, ^bad}} =
                 Prime.unstake_wallet(
                   @prime_credentials,
                   "pf-1",
                   "w-1",
                   "ETH",
                   Decimal.new("1"),
                   opts(never_sent()) ++ [extra: bad]
                 )

        assert {:error, {:invalid_extra, ^bad}} =
                 Prime.query_transaction_validators(
                   @prime_credentials,
                   "pf-1",
                   opts(never_sent()) ++ [transaction_ids: ["t"], extra: bad]
                 )
      end
    end

    test "claim_rewards refuses an inputs value that is not a map" do
      assert {:error, {:invalid_inputs, "all"}} =
               Prime.claim_rewards(
                 @prime_credentials,
                 "pf-1",
                 "w-1",
                 opts(never_sent()) ++ [body: %{"inputs" => "all"}, amount: Decimal.new("1")]
               )

      assert {:error, {:invalid_inputs, 5}} =
               Prime.claim_rewards(
                 @prime_credentials,
                 "pf-1",
                 "w-1",
                 opts(never_sent()) ++ [body: %{inputs: 5}]
               )
    end
  end

  describe "the fake refuses the filters Rest refuses" do
    test "get_orders and get_trade_history answer Rest's errors, before the credential" do
      assert {:error, {:invalid_symbol, :btc}} = Fake.get_orders(@credentials, symbol: :btc)
      assert {:error, {:invalid_symbol, :btc}} = Fake.get_orders(nil, symbol: :btc)
      assert {:error, {:invalid_limit, 0}} = Fake.get_orders(@credentials, limit: 0)
      assert {:error, {:invalid_status, :nope}} = Fake.get_orders(@credentials, status: :nope)

      assert {:error, {:invalid_symbol, ""}} =
               Fake.get_trade_history(@credentials, symbol: "")

      assert {:error, {:invalid_limit, "5"}} =
               Fake.get_trade_history(@credentials, limit: "5")

      assert {:error, {:invalid_trade_types, "FILL"}} =
               Fake.get_trade_history(@credentials, trade_types: "FILL")
    end

    test "a symbol list narrows the fake's answer instead of raising" do
      assert {:ok, [fill]} =
               Fake.get_trade_history(@credentials, symbol: ["BTC-USD", "ETH-USD"])

      assert fill.symbol == "BTC-USD"
      assert {:ok, []} = Fake.get_trade_history(@credentials, symbol: ["ETH-USD"])
      assert {:ok, [_open]} = Fake.get_orders(@credentials, symbol: ["btc-usd"])
    end
  end

  describe "every order request key is read or refused by name" do
    test "keys the spec defines but this package does not build are refused" do
      for key <- [
            :reduce_only,
            :attached_order_configuration,
            :prediction_metadata,
            :equity_order_metadata,
            :cost_basis_method,
            "symbol"
          ] do
        request = limit_request(%{key => "x"})

        assert {:error, {:unsupported_order_field, ^key}} =
                 Rest.place_order(@credentials, request, opts(never_sent()))

        assert {:error, {:unsupported_order_field, ^key}} =
                 Rest.preview_order(@credentials, request, opts(never_sent()))

        assert {:error, {:unsupported_order_field, ^key}} =
                 Fake.place_order(@credentials, request)
      end
    end

    test "the keys Core's conformance request sends are all accepted" do
      core = %{
        symbol: "BTC-USD",
        side: :buy,
        order_type: :limit,
        time_in_force: :gtc,
        quantity: Decimal.new("0.001"),
        price: Decimal.new("1")
      }

      assert {:ok, _plan} = Rest.order_plan(core, :place)
      assert {:ok, _plan} = Rest.order_plan(core, :preview)
    end

    test "retail_portfolio_id, preview_id and sor_preference are sent when valid" do
      me = self()

      request =
        limit_request(%{
          retail_portfolio_id: "11111111-1111-1111-1111-111111111111",
          preview_id: "b40bbff9-17ce-4726-8b64-9de7ae57ad26",
          sor_preference: "SOR_ENABLED"
        })

      assert {:ok, _order} =
               Rest.place_order(@credentials, request, opts(capturing(accepted(), me)))

      assert_receive {:sent, _path, raw}, @wait
      body = Jason.decode!(raw)
      assert body["retail_portfolio_id"] == "11111111-1111-1111-1111-111111111111"
      assert body["preview_id"] == "b40bbff9-17ce-4726-8b64-9de7ae57ad26"
      assert body["sor_preference"] == "SOR_ENABLED"
    end

    test "their types are validated, and preview_id is not a preview field" do
      for {key, bad} <- [retail_portfolio_id: "", preview_id: 5, sor_preference: "FAST"] do
        assert {:error, {:invalid_order_field, ^key, ^bad}} =
                 Rest.place_order(
                   @credentials,
                   limit_request(%{key => bad}),
                   opts(never_sent())
                 )
      end

      assert {:error, {:unsupported_order_field, :preview_id}} =
               Rest.preview_order(
                 @credentials,
                 limit_request(%{preview_id: "b40bbff9-17ce-4726-8b64-9de7ae57ad26"}),
                 opts(never_sent())
               )

      assert {:error, {:unsupported_order_field, :preview_id}} =
               Fake.preview_order(
                 @credentials,
                 limit_request(%{preview_id: "b40bbff9-17ce-4726-8b64-9de7ae57ad26"})
               )
    end
  end

  describe "Prime idempotency keys are UUIDs" do
    @bad_keys [
      "test-key-1",
      "mine",
      "6f1d2a40-0000-4000-8000-00000000001",
      "6f1d2a4000004000800000000000001",
      "g0000000-0000-4000-8000-000000000001",
      7
    ]

    test "a caller key that is not 8-4-4-4-12 hex is refused before anything is sent" do
      for bad <- @bad_keys do
        assert {:error, {:invalid_idempotency_key, ^bad}} =
                 Prime.stake_portfolio(
                   @prime_credentials,
                   "pf-1",
                   "ETH",
                   Decimal.new("1"),
                   opts(never_sent()) ++ [idempotency_key: bad]
                 )

        assert {:error, {:invalid_idempotency_key, ^bad}} =
                 Prime.claim_rewards(
                   @prime_credentials,
                   "pf-1",
                   "w-1",
                   opts(never_sent()) ++ [body: %{"idempotency_key" => bad}]
                 )
      end
    end

    test "an upper-case UUID is accepted, and a generated key is a UUID" do
      me = self()

      assert {:ok, _staked} =
               Prime.stake_portfolio(
                 @prime_credentials,
                 "pf-1",
                 "ETH",
                 Decimal.new("1"),
                 opts(capturing(%{"ok" => true}, me)) ++
                   [idempotency_key: "6F1D2A40-0000-4000-8000-00000000ABCD"]
               )

      assert_receive {:sent, _path, raw}, @wait
      assert Jason.decode!(raw)["idempotency_key"] == "6F1D2A40-0000-4000-8000-00000000ABCD"

      for _attempt <- 1..20 do
        assert DpExchange.Coinbase.IdempotencyKey.generate() =~
                 ~r/\A[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}\z/
      end
    end
  end
end

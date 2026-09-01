defmodule DpExchange.CoinbaseTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase
  alias DpExchange.Coinbase.Fake
  alias DpExchange.Core.{Capabilities, Venue}

  doctest Coinbase

  describe "declaration" do
    test "identity is present and well-formed" do
      assert Coinbase.provider_name() == "Coinbase"
      assert Coinbase.runtime_id() == :coinbase
      assert Coinbase.asset_classes() == [:crypto]
    end

    test "capabilities/0 needs no credentials and no network" do
      # A consumer decides whether to use the package at all from this, so it has to be
      # answerable at boot.
      task = Task.async(fn -> Coinbase.capabilities() end)
      assert %Capabilities{} = Task.await(task, 500)
    end

    test "every declared endpoint is a real facade callback" do
      callbacks = Venue.behaviour_info(:callbacks)

      for {endpoint, _maturity} <- Coinbase.capabilities().endpoints do
        assert endpoint in callbacks
      end
    end

    test "nothing claims :proven — nothing has run in production" do
      # `:proven` is earned by production use, not by careful implementation. A package
      # that has never traded declaring it would be the exact dishonesty D15 prevents.
      assert Capabilities.endpoints_at(Coinbase.capabilities(), :proven) == []
    end
  end

  describe "the ceilings are declared honestly" do
    test "measured_against says which parts were measured and which inherited" do
      # An unlabelled number is worse than a missing one. The granularities were probed;
      # the ceilings were not, and the declaration says so rather than implying both.
      caps = Coinbase.capabilities()

      assert caps.measured_at == ~D[2026-08-28]
      assert caps.measured_against =~ "measured live"
      assert caps.measured_against =~ "NOT measured"
    end

    test "credentials buy a higher ceiling, and both are declared" do
      caps = Coinbase.capabilities()

      assert caps.credential_benefit == :higher_ceiling
      assert caps.authenticated_ceiling.limit > caps.public_ceiling.limit
    end
  end

  describe "unsupported endpoints return the atom and do not raise" do
    @credentials %{api_key: "k", api_secret: "cw=="}

    test "every endpoint declared :unsupported actually refuses" do
      caps = Coinbase.capabilities()

      for {name, arity} <- Capabilities.endpoints_at(caps, :unsupported) do
        args =
          case {name, arity} do
            {:withdraw, 5} ->
              ["BTC", "bitcoin", Decimal.new("1"), "addr", []]

            {:estimate_withdrawal_fee, 4} ->
              ["BTC", "bitcoin", Decimal.new("1"), []]

            {n, 4} when n in [:quote_conversion, :convert] ->
              ["BTC", "USD", Decimal.new("1"), []]

            {:get_deposit_address, 3} ->
              ["BTC", "bitcoin", []]

            {:create_watchlist, 3} ->
              ["name", [], []]

            {:get_financials, 3} ->
              ["BTC-USD", :balance_sheet, []]

            {:rename_account, 3} ->
              ["id", "name", []]

            {:stake, 3} ->
              ["BTC", Decimal.new("1"), []]

            {:unstake, 3} ->
              ["BTC", Decimal.new("1"), []]

            {n, 2}
            when n in [
                   :get_funding,
                   :get_contract_stats,
                   :get_option_chain,
                   :get_option_expirations,
                   :get_top_of_book
                 ] ->
              ["BTC-USD", []]

            {n, 2}
            when n in [
                   :get_option_greeks,
                   :get_watchlist,
                   :update_watchlist,
                   :delete_watchlist,
                   :get_filings,
                   :get_screener,
                   :commit_conversion,
                   :get_conversion
                 ] ->
              ["id", []]

            {:replace_order, 4} ->
              [@credentials, "id", %{}, []]

            {_name, 1} ->
              [[]]

            {n, 2}
            when n in [
                   :get_balances,
                   :get_accounts,
                   :get_fees,
                   :get_transfers,
                   :get_orders,
                   :get_trade_history,
                   :test_connection,
                   :get_rate_limit_status
                 ] ->
              [@credentials, []]

            {_name, 2} ->
              ["BTC-USD", []]

            {_name, 3} ->
              [@credentials, "id", []]
          end

        assert {:error, :not_supported} = apply(Coinbase, name, args),
               "#{name}/#{arity} declares :unsupported but did not return the atom"
      end
    end
  end

  describe "market_status/1" do
    test "a crypto venue is always open" do
      assert {:ok, :open} = Coinbase.market_status([])
    end
  end

  describe "coverage/1 with no feed running" do
    test "answers empty rather than crashing" do
      # A consumer may ask before starting the venue. Empty is the honest answer: nothing
      # is arriving.
      assert Coinbase.coverage(feed: :a_feed_nobody_started) == %{}
    end
  end

  describe "child_spec/1" do
    test "is present and names itself from opts" do
      Code.ensure_loaded!(Coinbase)
      assert function_exported?(Coinbase, :child_spec, 1)

      assert %{id: :my_coinbase} = Coinbase.child_spec(name: :my_coinbase)
      assert %{id: Coinbase} = Coinbase.child_spec([])
    end
  end

  describe "market data delegates to the REST module" do
    defmodule PermissiveLimiter do
      @moduledoc false
      @behaviour DpExchange.Core.RateLimitBehaviour
      @impl true
      def acquire(_p, _w, _o), do: :ok
      @impl true
      def check(_p, _w, _o), do: :ok
      @impl true
      def record(_p, _w, _o), do: :ok
    end

    setup do
      DpExchange.Core.Config.put_override(:rate_limit_module, PermissiveLimiter)
      :ok
    end

    test "get_price reaches the venue path" do
      body = %{
        "trades" => [
          %{
            "product_id" => "BTC-USD",
            "price" => "1",
            "size" => "2",
            "time" => "2026-08-28T12:00:00Z",
            "bid" => "",
            "ask" => ""
          }
        ]
      }

      plug = fn conn -> Req.Test.json(conn, body) end

      assert {:ok, quote_struct} =
               Coinbase.get_price("BTC-USD", plug: plug, retry_attempts: 0)

      assert quote_struct.symbol == "BTC-USD"
    end

    test "get_symbols reaches the venue path" do
      plug = fn conn -> Req.Test.json(conn, %{"products" => [%{"product_id" => "BTC-USD"}]}) end

      assert {:ok, ~w(BTC-USD)} = Coinbase.get_symbols(plug: plug, retry_attempts: 0)
    end

    test "get_historical_prices refuses a width Coinbase does not serve" do
      assert {:error, {:unsupported_timeframe, "12h"}} =
               Coinbase.get_historical_prices("BTC-USD", "12h")
    end
  end

  describe "streaming delegates to the feed" do
    test "subscribe, coverage and unsubscribe all reach the running feed" do
      # `url:` points the socket at a closed port. **Without it this test opened a real
      # connection to Coinbase**, which is a tier-1 run reaching the live venue — the
      # same violation this package's own conformance suite was fixed for. A consumer
      # testing against this venue uses the fake; a test of the wiring points the socket
      # somewhere that cannot answer.
      id = System.unique_integer([:positive])

      opts = [
        name: :"venue_#{id}",
        limiter: :"limiter_#{id}",
        feed: :"feed_#{id}",
        url: "ws://127.0.0.1:1/nowhere"
      ]

      start_supervised!(%{id: opts[:name], start: {Coinbase, :start_link, [opts]}})

      # The socket cannot connect, so subscribe reports the failure rather than claiming
      # a subscription that will never deliver.
      assert {:error, _reason} = Coinbase.subscribe(~w(BTC-USD), opts)

      # Coverage is observed, so nothing arrived and nothing is covered.
      assert Coinbase.coverage(opts) == %{}

      assert :ok = Coinbase.unsubscribe(~w(BTC-USD), opts)
      assert :ok = Coinbase.update_symbols(~w(ETH-USD), opts)
      assert :ok = Coinbase.subscribe_notices(opts)
    end
  end

  describe "the fake's order lifecycle matches the venue's" do
    @fake_credentials %{api_key: "k", api_secret: "s"}

    test "placing an order the venue would accept succeeds" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        price: Decimal.new("40000")
      }

      assert {:ok, order} = Fake.place_order(@fake_credentials, request)
      assert order.status == :pending
      assert order.provider == :coinbase
    end

    test "placing a pair the venue does NOT name is refused by the fake too" do
      # A fake that accepted everything would let a consumer's suite pass on an order the
      # venue will reject, which is the failure a fake exists to prevent rather than cause.
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        order_type: :limit,
        time_in_force: :ioc
      }

      assert {:error, {:unsupported_order_combination, :limit, :ioc}} =
               Fake.place_order(@fake_credentials, request)
    end

    test "cancelling a known order succeeds" do
      assert {:ok, :cancelled} = Fake.cancel_order(@fake_credentials, "fake-order-1")
    end

    test "cancelling an order that cannot be cancelled refuses, as the venue does" do
      assert {:refused, {:cancel_rejected, _reason}} =
               Fake.cancel_order(@fake_credentials, "already-filled")
    end

    test "cancelling an unknown order refuses" do
      assert {:refused, {:cancel_rejected, _reason}} =
               Fake.cancel_order(@fake_credentials, "no-such-order")
    end

    test "reading a known order returns it" do
      assert {:ok, order} = Fake.get_order(@fake_credentials, "fake-order-1")
      assert order.id == "fake-order-1"
      assert order.status == :open
    end

    test "reading an unknown order refuses" do
      assert {:refused, :not_found} = Fake.get_order(@fake_credentials, "no-such-order")
    end

    test "listing returns the fake's orders" do
      assert {:ok, [order]} = Fake.get_orders(@fake_credentials)
      assert order.provider == :coinbase
    end
  end

  describe "the fake's preview and edit match the venue's surface" do
    test "a preview returns totals without placing" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        price: Decimal.new("40000")
      }

      assert {:ok, preview} = Fake.preview_order(@fake_credentials, request)
      assert Decimal.positive?(preview.order_total)
      assert preview.preview_id
    end

    test "a preview of an impossible pair is refused, as the venue would" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        order_type: :market,
        time_in_force: :gtc
      }

      assert {:error, {:unsupported_order_combination, :market, :gtc}} =
               Fake.preview_order(@fake_credentials, request)
    end

    test "editing price or size is accepted" do
      assert {:ok, order} =
               Fake.replace_order(@fake_credentials, "fake-order-1", %{
                 price: Decimal.new("41000")
               })

      assert order.id == "fake-order-1"
    end

    test "editing anything else is refused, matching the venue's edit surface" do
      assert {:error, {:unsupported_order_edit, [:time_in_force]}} =
               Fake.replace_order(@fake_credentials, "fake-order-1", %{time_in_force: :ioc})
    end
  end

  describe "the facade delegates the order surface" do
    # These go through DpExchange.Coinbase rather than Rest, which is the module a consumer
    # actually calls. A delegate wired to the wrong function would pass every Rest test.
    @creds %{api_key: "organizations/x/apiKeys/y", api_secret: "-----BEGIN EC PRIVATE KEY-----"}

    defmodule FacadeLimiter do
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
      DpExchange.Core.Config.put_override(:rate_limit_module, FacadeLimiter)
      :ok
    end

    defp json_plug(body) do
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end
    end

    test "place_order reaches the venue through the facade" do
      body = %{"success" => true, "success_response" => %{"order_id" => "via-facade"}}

      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        price: Decimal.new("40000")
      }

      assert {:ok, order} =
               Coinbase.place_order(@creds, request, plug: json_plug(body), retry_attempts: 0)

      assert order.id == "via-facade"
    end

    test "cancel_order reaches the venue through the facade" do
      body = %{"results" => [%{"order_id" => "abc", "success" => true}]}

      assert {:ok, :cancelled} =
               Coinbase.cancel_order(@creds, "abc", plug: json_plug(body), retry_attempts: 0)
    end

    test "get_order reaches the venue through the facade" do
      body = %{"order" => %{"order_id" => "abc", "product_id" => "BTC-USD", "status" => "OPEN"}}

      assert {:ok, order} =
               Coinbase.get_order(@creds, "abc", plug: json_plug(body), retry_attempts: 0)

      assert order.id == "abc"
    end

    test "get_orders reaches the venue through the facade" do
      assert {:ok, []} =
               Coinbase.get_orders(@creds, plug: json_plug(%{"orders" => []}), retry_attempts: 0)
    end

    test "preview_order reaches the venue through the facade" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        price: Decimal.new("40000")
      }

      assert {:ok, preview} =
               Coinbase.preview_order(@creds, request,
                 plug: json_plug(%{"errs" => [], "order_total" => "1"}),
                 retry_attempts: 0
               )

      assert Decimal.equal?(preview.order_total, Decimal.new("1"))
    end

    test "replace_order refuses an unsupported edit through the facade" do
      assert {:error, {:unsupported_order_edit, [:side]}} =
               Coinbase.replace_order(@creds, "abc", %{side: :sell}, retry_attempts: 0)
    end
  end
end

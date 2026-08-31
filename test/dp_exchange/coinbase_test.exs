defmodule DpExchange.CoinbaseTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase
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
end

defmodule DpExchange.Coinbase.ResponseShapeTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Config

  # **A response of the wrong JSON shape is an answer, never a raise.**
  #
  # `Core.Venue`'s error discipline is that a facade call answers — `{:ok, _}`,
  # `{:error, _}`, `{:refused, _}` — and does not raise in the caller's process. These are
  # the calls that did, found by feeding every active facade callback a set of plausible
  # but wrong bodies: `[]`, `null`, `{}`, an object whose list fields are all `null`, and
  # `{"data": {}}`. Each row below is one body that used to raise, and the exception it
  # raised. Driven through the FACADE, with the HTTP layer replaced by a `plug:`, so what
  # is measured is exactly the decode path a consumer reaches.
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
    api_key: "organizations/o/apiKeys/k",
    api_secret: Base.encode64(:crypto.strong_rand_bytes(64))
  }

  defp answering(body), do: fn conn -> Req.Test.json(conn, body) end

  defp base(body) do
    [
      plug: answering(body),
      retry_attempts: 0,
      credentials: @credentials,
      account_id: "acct",
      account_number: "acct",
      account_hash: "acct"
    ]
  end

  defp answers_without_raising(label, fun) do
    result =
      try do
        fun.()
      rescue
        error -> {:raised, error}
      end

    refute match?({:raised, _error}, result),
           "coinbase: #{label} raised #{inspect(result)} — a response shape it did not " <>
             "expect must be refused, not raised in the caller's process"

    result
  end

  # Every one of these read `%{"key" => list}` without `when is_list(list)`, so a
  # `null` list got past the match and raised `Protocol.UndefinedError` further down.
  # Each module already had an `{:error, :unexpected_response_shape}` fall-through; the
  # guard is what routes `null` to it.
  test "a list field that is null is refused, on every endpoint that reads one" do
    body = Map.new(~w(accounts products fills candles data results orders), &{&1, nil})
    v = DpExchange.Coinbase

    for {label, call} <- [
          {"get_accounts/2", fn -> v.get_accounts(@credentials, base(body)) end},
          {"get_balances/2", fn -> v.get_balances(@credentials, base(body)) end},
          {"get_trade_history/2", fn -> v.get_trade_history(@credentials, base(body)) end},
          {"get_symbols/1", fn -> v.get_symbols(base(body)) end},
          {"get_market_overview/1", fn -> v.get_market_overview(base(body)) end},
          {"list_instruments/1", fn -> v.list_instruments(base(body)) end},
          {"get_historical_prices/4",
           fn -> v.get_historical_prices("BTC-USD", "1h", [], base(body)) end}
        ] do
      assert {:error, _reason} = answers_without_raising(label, call)
    end
  end

  # **A value of the wrong type INSIDE a well-shaped body is an answer too.** The test above
  # covers a list that is `null`; these cover a list whose rows are not objects, and a field
  # of the wrong type within a row. A REST mutation fuzz (2026-09-27) replaced every nested
  # value of a real body with `nil`, `true`, `[]`, `[%{}]`, a map, a string and numbers
  # past every range, one at a time. 255 of those mutations raised. Each call below is one
  # of the decode paths they raised out of.
  describe "a value of the wrong type inside a response" do
    alias DpExchange.Coinbase.{Rest, SymbolFormat}

    defp opts(body), do: [plug: answering(body), retry_attempts: 0]

    test "a row that is not an object refuses the reply" do
      summary = %{"fee_tier" => %{}, "volume_breakdown" => ["x"]}

      for {label, call, body} <- [
            {"get_balances", fn b -> Rest.get_balances(@credentials, opts(b)) end,
             %{"accounts" => [true], "has_next" => false}},
            {"get_positions", fn b -> Rest.get_positions(@credentials, opts(b)) end,
             %{"positions" => [true]}},
            {"get_trade_history", fn b -> Rest.get_trade_history(@credentials, opts(b)) end,
             %{"fills" => [true], "cursor" => ""}},
            {"get_historical_prices",
             fn b -> Rest.get_historical_prices("BTC-USD", "1h", [], opts(b)) end,
             %{"candles" => [true]}},
            {"get_trades", fn b -> Rest.get_trades("BTC-USD", opts(b)) end,
             %{"trades" => [true]}},
            {"get_price", fn b -> Rest.get_price("BTC-USD", opts(b)) end, %{"trades" => [true]}},
            {"get_orders", fn b -> Rest.get_orders(@credentials, opts(b)) end,
             %{"orders" => [true], "has_next" => false}},
            {"get_order", fn b -> Rest.get_order(@credentials, "abc", opts(b)) end,
             %{"order" => true}},
            {"get_order_book", fn b -> Rest.get_order_book("BTC-USD", opts(b)) end,
             %{"pricebook" => true}},
            {"get_top_of_book",
             fn b -> Rest.get_top_of_book("BTC-USD", [credentials: @credentials] ++ opts(b)) end,
             %{"pricebooks" => [true]}},
            {"list_portfolios", fn b -> Rest.list_portfolios(@credentials, opts(b)) end,
             %{"portfolios" => [true]}},
            {"get_trade_volume", fn b -> Rest.get_trade_volume(@credentials, opts(b)) end,
             summary}
          ] do
        assert {:error, :unexpected_response_shape} ==
                 answers_without_raising(label, fn -> call.(body) end),
               label
      end
    end

    test "a catalogue row naming no product is skipped, not raised on" do
      # One malformed row among hundreds used to take the whole catalogue with it.
      named = %{"product_id" => "BTC-USD", "alias" => "BTC-USDC"}
      body = %{"products" => [named, %{"product_id" => %{}}, true, %{}, [%{}]]}
      btc = SymbolFormat.to_canonical_symbol("BTC-USD")

      assert {:ok, [^btc]} = Rest.get_symbols(opts(body))
      assert {:ok, [%{symbol: ^btc}]} = Rest.list_instruments(opts(body))
      assert {:ok, overview} = Rest.get_market_overview(opts(body))
      assert Map.keys(overview) == [btc]
      assert {:ok, %{^btc => _aliased}} = Rest.get_alias_map(opts(body))
    end

    test "an id or product of the wrong type is refused on a fill and nil on an order" do
      fill = %{
        "trade_time" => "2026-08-31T09:59:59Z",
        "trade_type" => "FILL",
        "price" => "1",
        "size" => "1",
        "order_id" => "o",
        "product_id" => "BTC-USD",
        "side" => "BUY"
      }

      history = fn row ->
        Rest.get_trade_history(@credentials, opts(%{"fills" => [row], "cursor" => ""}))
      end

      assert {:error, :unexpected_response_shape} = history.(%{fill | "order_id" => %{}})
      assert {:error, :unexpected_response_shape} = history.(%{fill | "order_id" => [1]})

      assert {:error, {:missing_required_field, :symbol}} =
               history.(%{fill | "product_id" => %{}})

      order = %{"order_id" => "abc", "product_id" => %{"a" => nil}}

      assert {:ok, %{id: "abc", symbol: nil}} =
               Rest.get_order(@credentials, "abc", opts(%{"order" => order}))
    end

    test "an accepted order with an unreadable success_response is still accepted" do
      # `success: true` means an order is live at the venue. An error here would tell the
      # caller nothing was placed.
      body = %{"success" => true, "success_response" => true}

      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("1"),
        price: Decimal.new("1"),
        order_type: :limit,
        time_in_force: :gtc
      }

      assert {:ok, %{id: nil, status: :pending}} =
               Rest.place_order(@credentials, request, opts(body))

      assert {:ok, %{id: nil, status: :pending}} =
               Rest.close_position(@credentials, "BTC-USD", opts(body))
    end

    test "a cancel result row that is not an object is not about the order" do
      assert {:error, :order_not_in_response} =
               Rest.cancel_order(@credentials, "abc", opts(%{"results" => [true]}))
    end
  end
end

defmodule DpExchange.Coinbase.ReadSymbolTest do
  @moduledoc """
  A symbol that names no product is refused by the market-data reads, in the caller, and the
  Fake refuses identically. `SymbolFormat.to_exchange_symbol/1` has no clause for a
  non-binary, so `nil` or `:btc` raised `FunctionClauseError` and `""` built
  `/products//ticker`. Also: a body the caller supplied that JSON cannot encode is a value,
  not a raise.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Fake, Rest}

  @moduletag :capture_log

  @credentials %{
    api_key: "organizations/x/apiKeys/y",
    api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
  }

  @bad_symbols [nil, "", " ", "\t\n", :btc, 42, ["BTC-USD"]]

  # A plug that reports any request it receives. None is expected.
  defp reporting(test_pid) do
    fn conn ->
      send(test_pid, {:request_sent, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, "{}")
    end
  end

  describe "Rest refuses a symbol that names no product, sending nothing" do
    test "every symbol-taking read" do
      me = self()
      opts = [plug: reporting(me), retry_attempts: 0, credentials: @credentials]

      for bad <- @bad_symbols do
        expected = {:error, {:invalid_symbol, bad}}

        assert expected == Rest.get_price(bad, opts)
        assert expected == Rest.get_top_of_book(bad, opts)
        assert expected == Rest.get_order_book(bad, opts)
        assert expected == Rest.get_trades(bad, [limit: 5] ++ opts)
        assert expected == Rest.quantization(bad, opts)
        assert expected == Rest.get_product(bad, opts)

        assert expected == Rest.get_historical_prices(bad, "1h", [], opts)
      end

      refute_receive {:request_sent, _path}, 50
    end

    test "the timeframe is refused before the symbol, and the symbol before the options" do
      assert {:error, {:unsupported_timeframe, "3h"}} =
               Rest.get_historical_prices(nil, "3h", [], [])

      assert {:error, {:invalid_symbol, nil}} = Rest.get_trades(nil, [])
      assert {:error, {:invalid_symbol, nil}} = Fake.get_trades(nil, [])

      assert {:error, {:invalid_symbol, nil}} =
               Rest.get_historical_prices(nil, "1h", [], limt: 1)
    end

    test "validate_symbol/1 accepts a non-empty string" do
      assert :ok = Rest.validate_symbol("BTC-USD")
      assert {:error, {:invalid_symbol, ""}} = Rest.validate_symbol("")
    end
  end

  describe "the Fake refuses the same symbols the same way" do
    test "every symbol-taking read" do
      for bad <- @bad_symbols do
        expected = {:error, {:invalid_symbol, bad}}
        creds = [credentials: @credentials]

        assert expected == Fake.get_price(bad, [])
        assert expected == Fake.get_top_of_book(bad, creds)
        assert expected == Fake.get_order_book(bad, [])
        assert expected == Fake.get_trades(bad, limit: 5)
        assert expected == Fake.quantization(bad)
        assert expected == Fake.get_historical_prices(bad, "1h", [], [])
      end
    end

    test "a lower-case listed symbol is listed for quantization, as the real path upper-cases" do
      assert {:ok, %{status: "online"}} = Fake.quantization("btc-usd")
      assert {:refused, :not_listed} = Fake.quantization("DOGE-USD")
    end
  end

  describe "Fake.get_orders/2 takes a list of statuses, as the real path does" do
    test "a list matches the union, not a FunctionClauseError" do
      assert {:ok, [%{status: :open}]} =
               Fake.get_orders(@credentials, status: [:open, :pending])

      assert {:ok, []} = Fake.get_orders(@credentials, status: [:filled, :cancelled])
    end
  end

  describe "the Fake refuses a staking id the real path refuses" do
    @prime %{access_key: "k", passphrase: "p", signing_key: "s"}

    test "portfolio and wallet ids are path segments" do
      for bad <- ["", "x/../y", "a?b", 7] do
        expected = {:error, {:invalid_portfolio_id, bad}}
        opts = [portfolio_id: bad, credentials: @prime]

        assert expected == Fake.stake("ETH", Decimal.new("1"), opts)
        assert expected == Fake.unstake("ETH", Decimal.new("1"), opts)
      end

      assert {:error, {:invalid_wallet_id, "w/1"}} =
               Fake.stake("ETH", Decimal.new("1"),
                 portfolio_id: "pf-1",
                 wallet_id: "w/1",
                 credentials: @prime
               )
    end

    test "a wallet-scoped call refuses an asset that is not a name, as the real path does" do
      # The wallet body carries no currency, so the real path now VERIFIES the asset against
      # the wallet; an asset that cannot name one is `{:invalid_asset, _}` in both scopes.
      assert {:error, {:invalid_asset, :eth}} =
               Fake.stake(:eth, Decimal.new("1"),
                 portfolio_id: "pf-1",
                 wallet_id: "w-1",
                 credentials: @prime
               )
    end
  end

  describe "a request body JSON cannot encode" do
    test "is refused as a value, not raised" do
      opts = [retry_attempts: 0]

      assert {:error, :unencodable_body} =
               Rest.quote_conversion(
                 @credentials,
                 "USD",
                 "USDC",
                 Decimal.new("10"),
                 [trade_incentive_metadata: %{"x" => {:not, :json}}] ++ opts
               )
    end
  end
end

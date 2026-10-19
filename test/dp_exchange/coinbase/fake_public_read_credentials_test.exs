defmodule DpExchange.Coinbase.FakePublicReadCredentialsTest do
  @moduledoc """
  The public reads that sign when handed a credential refuse a malformed one on both sides.

  `get_price/2`, `get_symbols/1`, `get_market_overview/1` and `list_instruments/1` already
  agreed with the real path on this; `get_order_book/2`, `get_trades/2` and
  `get_historical_prices/4` did not. Each real read takes the authenticated path when it is
  given a credential, signs the request, and answers
  `{:error, {:missing_credentials | :invalid_credentials, :coinbase}}` for one that cannot
  sign, before anything is sent and so ahead of the venue's word on the symbol. The fake
  ignored `opts[:credentials]` there, so a consumer's test with a mistyped key went green
  against it and was refused in production.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Fake, Rest}
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

  # A venue that would answer 404 to anything: the request must never get that far.
  defp not_found do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "NOT_FOUND"}))
    end
  end

  defp transport, do: [plug: not_found(), retry_attempts: 1]

  defp bad_credentials do
    [
      %{api_key: "k"},
      %{api_key: " ", api_secret: "s"},
      %{api_key: "k ", api_secret: "s"},
      %{api_key: 1, api_secret: 2}
    ]
  end

  describe "get_order_book/2" do
    test "a malformed credential is refused as the real read refuses it" do
      for bad <- bad_credentials() do
        opts = [credentials: bad] ++ transport()
        from_real = Rest.get_order_book("BTC-USD", opts)

        assert {:error, {code, :coinbase}} = from_real
        assert code in [:missing_credentials, :invalid_credentials]
        assert Fake.get_order_book("BTC-USD", opts) == from_real
      end
    end

    test "and ahead of the venue's word on the symbol" do
      opts = [credentials: %{api_key: "k"}] ++ transport()

      assert Rest.get_order_book("ZZZ-USD", opts) == Fake.get_order_book("ZZZ-USD", opts)
      assert {:error, {:missing_credentials, :coinbase}} = Fake.get_order_book("ZZZ-USD", opts)
    end

    test "no credential, an empty one and a good one are served; an unlisted symbol is refused" do
      for creds <- [nil, %{}, @credentials] do
        assert {:ok, %Types.OrderBook{}} = Fake.get_order_book("BTC-USD", credentials: creds)
      end

      assert {:refused, :not_listed} =
               Fake.get_order_book("ZZZ-USD", credentials: @credentials)
    end
  end

  describe "get_trades/2" do
    test "a malformed credential is refused as the real read refuses it" do
      for bad <- bad_credentials() do
        opts = [credentials: bad, limit: 5] ++ transport()
        from_real = Rest.get_trades("BTC-USD", opts)

        assert {:error, {code, :coinbase}} = from_real
        assert code in [:missing_credentials, :invalid_credentials]
        assert Fake.get_trades("BTC-USD", opts) == from_real
      end
    end

    test "and ahead of the venue's word on the symbol, but after the local option checks" do
      opts = [credentials: %{api_key: "k"}, limit: 5] ++ transport()

      assert Rest.get_trades("ZZZ-USD", opts) == Fake.get_trades("ZZZ-USD", opts)

      # The missing `:limit` is a local refusal, so it wins over the credential on both sides.
      no_limit = [credentials: %{api_key: "k"}] ++ transport()
      assert {:error, :missing_limit} = Rest.get_trades("BTC-USD", no_limit)
      assert Fake.get_trades("BTC-USD", no_limit) == {:error, :missing_limit}
    end

    test "no credential, an empty one and a good one are served" do
      for creds <- [nil, %{}, @credentials] do
        assert {:ok, [_older, _newer]} =
                 Fake.get_trades("BTC-USD", credentials: creds, limit: 5)
      end
    end
  end

  describe "get_historical_prices/4" do
    test "a malformed credential is refused as the real read refuses it" do
      for bad <- bad_credentials() do
        opts = [credentials: bad] ++ transport()
        from_real = Rest.get_historical_prices("BTC-USD", "1h", [], opts)

        assert {:error, {code, :coinbase}} = from_real
        assert code in [:missing_credentials, :invalid_credentials]
        assert Fake.get_historical_prices("BTC-USD", "1h", [], opts) == from_real
      end
    end

    test "and ahead of the venue's word on the symbol, but after the timeframe check" do
      opts = [credentials: %{api_key: "k"}] ++ transport()

      assert Rest.get_historical_prices("ZZZ-USD", "1h", [], opts) ==
               Fake.get_historical_prices("ZZZ-USD", "1h", [], opts)

      assert {:error, {:unsupported_timeframe, "12h"}} =
               Fake.get_historical_prices("BTC-USD", "12h", [], opts)

      assert Rest.get_historical_prices("BTC-USD", "12h", [], opts) ==
               Fake.get_historical_prices("BTC-USD", "12h", [], opts)
    end

    test "no credential, an empty one and a good one are served" do
      for creds <- [nil, %{}, @credentials] do
        assert {:ok, _bars} =
                 Fake.get_historical_prices("BTC-USD", "1h", [], credentials: creds)
      end
    end
  end
end

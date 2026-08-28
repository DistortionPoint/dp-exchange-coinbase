defmodule DpExchange.CoinbaseLiveTest do
  @moduledoc """
  Tier 2 — the live venue's **public** endpoints. No credentials, no money.

  Excluded from every ordinary run and from CI. Run by hand:

      mix test --include tier2

  **Never on a schedule.** A venue that sees a package polling it on a timer will
  rate-limit or block, and a package that does that to its own venue has earned it.

  These exist for the one thing a fake can never tell you: whether the venue still
  behaves the way this package believes it does. Each assertion below corresponds to a
  claim in `capabilities/0` — if one starts failing, the declaration is now a lie.
  """

  use ExUnit.Case, async: false

  alias DpExchange.Coinbase

  @moduletag :tier2

  # The venue supervises its own rate limiter, configured from the ceilings it declares.
  # Starting it here is what a consumer's supervision tree does — and doing it in the
  # test rather than assuming it is how the missing-limiter trap was found.
  setup do
    start_supervised!({DpExchange.Coinbase, []})
    :ok
  end

  describe "the declaration is still true of the running venue" do
    test "every declared granularity is actually served" do
      # The FOUR_HOUR incident in one assertion: a width the venue serves and the
      # package does not declare is a missed capability; a width declared and not
      # served is a caller receiving something else labelled as what it asked for.
      finish = DateTime.utc_now()

      for timeframe <- Coinbase.capabilities().historical_timeframes do
        {:ok, width} = DpExchange.Core.Timeframe.seconds(timeframe)
        start = DateTime.add(finish, -width * 10, :second)

        assert {:ok, [_first | _rest]} =
                 Coinbase.get_historical_prices("BTC-USD", timeframe, start: start, end: finish),
               "#{timeframe} is declared but the venue served nothing"

        Process.sleep(400)
      end
    end

    test "a width the venue does not serve is refused, not substituted" do
      finish = DateTime.utc_now()
      start = DateTime.add(finish, -86_400, :second)

      assert {:error, {:unsupported_timeframe, "12h"}} =
               Coinbase.get_historical_prices("BTC-USD", "12h", start: start, end: finish)
    end

    test "the 350-candle boundary is a refusal, not a truncation" do
      # Measured 2026-08-28: 351 minutes returns zero and INVALID_ARGUMENT, not the
      # first 350. This package refuses up front so the caller gets a reason rather
      # than an empty list it will read as "no data for this period".
      finish = DateTime.utc_now()
      start = DateTime.add(finish, -60 * 400, :second)

      assert {:error, {:range_too_wide, requested: _n, max: 350}} =
               Coinbase.get_historical_prices("BTC-USD", "1m", start: start, end: finish)
    end

    test "the public price endpoint answers without credentials" do
      assert {:ok, quote_struct} = Coinbase.get_price("BTC-USD", [])
      assert Decimal.positive?(quote_struct.price)
      assert %DateTime{} = quote_struct.timestamp
    end

    test "a symbol the venue does not list is REFUSED, not errored" do
      # The distinction a caller acts on: a refusal is permanent, an error is worth
      # retrying. Collapsing them makes a delisting look like a network blip forever.
      assert {:refused, _reason} = Coinbase.get_price("NOTAREAL-PAIR", [])
    end

    test "every declared quote asset appears in the live catalogue" do
      assert {:ok, symbols} = Coinbase.get_symbols([])

      listed =
        symbols
        |> Enum.map(&(&1 |> String.split("-") |> List.last()))
        |> MapSet.new()

      declared = MapSet.new(Coinbase.capabilities().supported_quotes)

      assert MapSet.subset?(declared, listed),
             "declared but not listed: #{inspect(MapSet.difference(declared, listed))}"
    end
  end

  describe "what the venue does NOT publish" do
    test "there are still no rate-limit headers" do
      # The reason `capabilities/0` declares its ceilings from documentation and says so
      # in `measured_against`. If this starts failing, the ceilings have become
      # discoverable and the declaration should be re-derived from the wire.
      {:ok, response} =
        DpExchange.Core.HttpClient.request(
          :get,
          "https://api.coinbase.com/api/v3/brokerage/market/products/BTC-USD/ticker",
          [],
          nil,
          retry_attempts: 1
        )

      assert nil == DpExchange.Core.HttpClient.parse_rate_limit_headers(response.headers)
    end
  end
end

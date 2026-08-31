defmodule DpExchange.Coinbase.RestTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Rest
  alias DpExchange.Core.{Config, Types}

  @moduletag :capture_log

  # A real limiter module answering from configuration, injected through the same
  # process-scoped seam a consumer would use. Not a mock: nothing is stubbed and no call
  # is verified.
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

  defp responding(body, status \\ 200) do
    fn conn -> Req.Test.json(%{conn | status: status}, body) end
  end

  @ticker %{
    "trades" => [
      %{
        "product_id" => "BTC-USD",
        "price" => "79478.7",
        "size" => "0.5",
        "time" => "2026-08-28T14:53:45.649112Z",
        "bid" => "",
        "ask" => ""
      }
    ],
    "best_bid" => "79478.0",
    "best_ask" => "79479.0"
  }

  describe "get_price/2" do
    test "returns a Quote with Decimal numerics and the venue's own timestamp" do
      assert {:ok, %Types.Quote{} = quote_struct} =
               Rest.get_price("BTC-USD", plug: responding(@ticker), retry_attempts: 0)

      assert Decimal.equal?(quote_struct.price, Decimal.new("79478.7"))
      assert quote_struct.timestamp == ~U[2026-08-28 14:53:45.649112Z]
      assert quote_struct.provider == :coinbase
    end

    test "an empty bid is nil, not zero" do
      # Zero is a price. A venue that did not quote a bid has not quoted a bid of nothing.
      # The assertion moved from `Quote` to `TopOfBook` when the book left the quote — same
      # rule, same payload, a type that says which number it is holding.
      body = put_in(@ticker["best_bid"], "")
      body = put_in(body["best_ask"], "")

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert top.bid == nil
      assert top.ask == nil
    end

    test "a response with no venue timestamp FAILS rather than substituting now" do
      # The failure this whole family is built to refuse: `now` is plausible, and it makes
      # a stale quote indistinguishable from a live one.
      trade = @ticker["trades"] |> hd() |> Map.delete("time")
      body = %{@ticker | "trades" => [trade]}

      assert {:error, :missing_venue_timestamp} =
               Rest.get_price("BTC-USD", plug: responding(body), retry_attempts: 0)
    end

    test "an unparseable timestamp also fails" do
      trade = @ticker["trades"] |> hd() |> Map.put("time", "not a time")
      body = %{@ticker | "trades" => [trade]}

      assert {:error, {:unparseable_venue_timestamp, _reason}} =
               Rest.get_price("BTC-USD", plug: responding(body), retry_attempts: 0)
    end

    test "an unexpected shape is an error, not a partially-built quote" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_price("BTC-USD",
                 plug: responding(%{"unexpected" => true}),
                 retry_attempts: 0
               )
    end

    test "a 404 is a REFUSAL, not an error" do
      # Permanent versus transient is the distinction a caller acts on: a refusal is not
      # retried, an error is. Collapsing them makes a delisting a forever-blip.
      assert {:refused, :not_listed} =
               Rest.get_price("NOPE-USD", plug: responding(%{}, 404), retry_attempts: 0)
    end

    test "a 500 stays an error" do
      assert {:error, _reason} =
               Rest.get_price("BTC-USD", plug: responding(%{}, 500), retry_attempts: 0)
    end
  end

  describe "get_historical_prices/4" do
    @candles %{
      "candles" => [
        %{
          "start" => "1787928720",
          "open" => "1",
          "high" => "2",
          "low" => "0.5",
          "close" => "1.5",
          "volume" => "10"
        },
        %{
          "start" => "1787928660",
          "open" => "1",
          "high" => "2",
          "low" => "0.5",
          "close" => "1.4",
          "volume" => "11"
        }
      ]
    }

    test "returns candles sorted oldest first, with the venue's bucket starts" do
      # The bucket start is used as-is — not re-derived, not rounded. Alignment is the
      # one property a fabricated candle cannot fake without also being right.
      assert {:ok, [first, second]} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: responding(@candles),
                 retry_attempts: 0
               )

      assert first.timestamp == DateTime.from_unix!(1_787_928_660)
      assert second.timestamp == DateTime.from_unix!(1_787_928_720)
      assert DpExchange.Core.Timeframe.aligned?(first.timestamp, "1m")
    end

    test "a width Coinbase does not serve is an ERROR, never the nearest one" do
      # `12h` is in the shared vocabulary and not in Coinbase's nine. A caller handed
      # 6h bars labelled 12h has every value real and every label wrong.
      assert {:error, {:unsupported_timeframe, "12h"}} =
               Rest.get_historical_prices("BTC-USD", "12h", [], retry_attempts: 0)
    end

    test "an over-wide range is refused up front, with the numbers" do
      # Measured: the venue answers 351 candles with zero and INVALID_ARGUMENT, not the
      # first 350. Refusing here gives the caller a reason instead of an empty list it
      # will read as "no data for this period".
      finish = ~U[2026-08-28 12:00:00Z]
      start = DateTime.add(finish, -60 * 400, :second)

      assert {:error, {:range_too_wide, requested: 400, max: 350}} =
               Rest.get_historical_prices("BTC-USD", "1m", [start: start, end: finish], [])
    end

    test "a range exactly at the boundary is allowed" do
      finish = ~U[2026-08-28 12:00:00Z]
      start = DateTime.add(finish, -60 * 350, :second)

      assert {:ok, _candles} =
               Rest.get_historical_prices("BTC-USD", "1m", [start: start, end: finish],
                 plug: responding(@candles),
                 retry_attempts: 0
               )
    end
  end

  describe "get_symbols/1" do
    test "canonicalises every product id" do
      body = %{"products" => [%{"product_id" => "BTC-USD"}, %{"product_id" => "eth-usd"}]}

      assert {:ok, ~w(BTC-USD ETH-USD)} =
               Rest.get_symbols(plug: responding(body), retry_attempts: 0)
    end

    test "an unexpected shape is an error" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_symbols(plug: responding(%{"nope" => 1}), retry_attempts: 0)
    end
  end

  describe "the declaration and the code agree" do
    test "granularities/0 matches what capabilities/0 declares" do
      assert Rest.granularities() == DpExchange.Coinbase.capabilities().historical_timeframes
    end

    test "max_candles/0 matches the declaration" do
      assert Rest.max_candles() == DpExchange.Coinbase.capabilities().max_candles_per_request
    end

    test "12h is in the shared vocabulary and NOT in this venue's" do
      assert "12h" in DpExchange.Core.Timeframe.known()
      refute "12h" in Rest.granularities()
    end
  end

  describe "error classification" do
    test "a transport failure stays an error" do
      plug = fn _conn -> raise "transport exploded" end

      assert {:error, _reason} =
               Rest.get_price("BTC-USD", plug: plug, retry_attempts: 1, retry_delay: 1)
    end

    test "a rate-limited response surfaces as an error, not a refusal" do
      # Being throttled is transient. Treating it as a refusal would stop a caller asking
      # again for a symbol the venue very much does carry.
      plug = fn conn -> Req.Test.json(%{conn | status: 429}, %{}) end

      assert {:error, _reason} = Rest.get_price("BTC-USD", plug: plug, retry_attempts: 0)
    end

    test "candles with an unexpected shape are an error" do
      plug = fn conn -> Req.Test.json(conn, %{"nope" => true}) end

      assert {:error, :unexpected_response_shape} =
               Rest.get_historical_prices("BTC-USD", "1h", [], plug: plug, retry_attempts: 0)
    end

    test "a 404 on candles is a refusal" do
      plug = fn conn -> Req.Test.json(%{conn | status: 404}, %{}) end

      assert {:refused, :not_listed} =
               Rest.get_historical_prices("BTC-USD", "1h", [], plug: plug, retry_attempts: 0)
    end

    test "a 404 on symbols is a refusal too" do
      plug = fn conn -> Req.Test.json(%{conn | status: 404}, %{}) end

      assert {:refused, :not_listed} = Rest.get_symbols(plug: plug, retry_attempts: 0)
    end
  end

  describe "the default range" do
    test "a caller giving no range gets a window inside the venue's boundary" do
      # 300 candles rather than 350: the caller did not ask for a specific window, so the
      # package picks one that cannot be refused rather than one that sits on the edge.
      plug = fn conn ->
        assert conn.query_string =~ "granularity=ONE_HOUR"
        Req.Test.json(conn, %{"candles" => []})
      end

      assert {:ok, []} =
               Rest.get_historical_prices("BTC-USD", "1h", [], plug: plug, retry_attempts: 0)
    end
  end
end

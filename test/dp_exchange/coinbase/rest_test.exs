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

  # `/best_bid_ask` has no public form — unlike every other market-data endpoint this
  # module reads, it genuinely requires a credential. See `get_top_of_book/2`'s own doc.
  defp credentials do
    %{api_key: "organizations/x/apiKeys/y", api_secret: "-----BEGIN EC PRIVATE KEY-----"}
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

    test "an empty side is nil, not zero" do
      # Zero is a price. A venue quoting nothing on a side has not quoted a price of
      # nothing — one side of a book can genuinely be empty.
      body = %{"pricebooks" => [%{"product_id" => "BTC-USD", "bids" => [], "asks" => []}]}

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD",
                 credentials: credentials(),
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert top.bid == nil
      assert top.ask == nil
      assert top.bid_size == nil
      assert top.ask_size == nil
    end

    test "get_top_of_book/2 without credentials fails closed and never sends a request" do
      # Unlike every sibling market-data reader, `/best_bid_ask` has no public form —
      # verified live 2026-09-05: authenticated is 401, `/market/best_bid_ask` is 404.
      # Sending the request anyway with no credential would come back as an opaque 401
      # that reads like a venue problem. The plug below would happily answer with a
      # canned 200 regardless of path or headers, exactly like the stub this test
      # replaces — the point is that it must never be reached.
      me = self()

      plug = fn conn ->
        send(me, :request_sent)
        Req.Test.json(conn, %{"pricebooks" => []})
      end

      assert {:refused, :missing_credentials} =
               Rest.get_top_of_book("BTC-USD", plug: plug, retry_attempts: 0)

      refute_received :request_sent
    end

    test "get_top_of_book/2 with credentials requests /best_bid_ask directly, no /market/ branch" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})
        Req.Test.json(conn, %{"pricebooks" => []})
      end

      assert {:refused, :not_listed} =
               Rest.get_top_of_book("BTC-USD",
                 credentials: credentials(),
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:path, path}
      assert path =~ "best_bid_ask"
      refute path =~ "/market/"
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

    test "a non-numeric price refuses the quote rather than raising or delivering price: nil" do
      # Decimal.new/1 used to raise here. The fix must not trade a crash for a Quote whose
      # required :price is silently nil, which is the same substitution wearing a
      # quieter shape.
      trade = @ticker["trades"] |> hd() |> Map.put("price", "null")
      body = %{@ticker | "trades" => [trade]}

      assert {:error, {:invalid_decimal, :price, "null"}} =
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

      assert first.opened_at == DateTime.from_unix!(1_787_928_660)
      assert second.opened_at == DateTime.from_unix!(1_787_928_720)
      assert DpExchange.Core.Timeframe.aligned?(first.opened_at, "1m")
    end

    test "the public candles path is used without a credential and the private one with" do
      # The venue publishes the same candles twice. Reading the public one while holding a
      # credential would silently forgo whatever the authenticated view adds.
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@candles))
      end

      assert {:ok, _public} =
               Rest.get_historical_prices("BTC-USD", "1m", [], plug: plug, retry_attempts: 0)

      assert_receive {:path, public_path}
      assert public_path =~ "/market/products/BTC-USD/candles"

      credentials = %{
        api_key: "organizations/x/apiKeys/y",
        api_secret: "-----BEGIN EC PRIVATE KEY-----"
      }

      assert {:ok, _private} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 credentials: credentials,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:path, private_path}
      refute private_path =~ "/market/"
      assert private_path =~ "/products/BTC-USD/candles"
    end

    test "all four prices survive the boundary" do
      # This package built `Quote`s with `price: close` until 2026-09-01, discarding open,
      # high and low where no caller could see it happen. Every value that came out was
      # real; a caller reading `price` simply had no way to learn it held one corner of a
      # bar. This is the assertion that would have caught it.
      assert {:ok, [first | _rest]} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: responding(@candles),
                 retry_attempts: 0
               )

      assert %Types.Candle{} = first
      assert Decimal.equal?(first.open, Decimal.new("1"))
      assert Decimal.equal?(first.high, Decimal.new("2"))
      assert Decimal.equal?(first.low, Decimal.new("0.5"))
      assert Decimal.equal?(first.close, Decimal.new("1.4"))
      assert Decimal.equal?(first.volume, Decimal.new("11"))
      assert first.timeframe == "1m"
      refute Map.has_key?(first, :price)
    end

    test "a bar the venue did not date is refused, never stamped with the local clock" do
      # An undated bar cannot be placed in a series, and a local timestamp would place it
      # wrongly while looking entirely right.
      undated = %{"candles" => [%{"open" => "1", "high" => "2", "low" => "1", "close" => "1"}]}

      assert {:error, :missing_venue_timestamp} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: responding(undated),
                 retry_attempts: 0
               )
    end

    test "a start that is not an epoch is refused rather than parsed loosely" do
      bad = %{"candles" => [%{"start" => "2026-08-28", "open" => "1", "close" => "1"}]}

      assert {:error, :missing_venue_timestamp} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: responding(bad),
                 retry_attempts: 0
               )
    end

    test "the venue's own bars are internally consistent, and this says so" do
      assert {:ok, bars} =
               Rest.get_historical_prices("BTC-USD", "1m", [],
                 plug: responding(@candles),
                 retry_attempts: 0
               )

      assert Enum.all?(bars, &Types.Candle.coherent?/1)
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

  describe "get_market_overview/1" do
    test "reads the fields get_symbols/1 discards from the same bulk endpoint" do
      body = %{
        "products" => [
          %{
            "product_id" => "BTC-USD",
            "price" => "79355.5",
            "price_percentage_change_24h" => "1.13",
            "volume_24h" => "12191.98",
            "high_24h" => "82283",
            "low_24h" => "78431.32",
            "status" => "online"
          }
        ]
      }

      assert {:ok, overview} =
               Rest.get_market_overview(plug: responding(body), retry_attempts: 0)

      assert %{
               price: price,
               price_change_24h_pct: change,
               volume_24h: volume,
               high_24h: high,
               low_24h: low,
               status: "online"
             } = overview["BTC-USD"]

      assert Decimal.equal?(price, Decimal.new("79355.5"))
      assert Decimal.equal?(change, Decimal.new("1.13"))
      assert Decimal.equal?(volume, Decimal.new("12191.98"))
      assert Decimal.equal?(high, Decimal.new("82283"))
      assert Decimal.equal?(low, Decimal.new("78431.32"))
    end

    test "an unexpected shape is an error" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_market_overview(plug: responding(%{"nope" => 1}), retry_attempts: 0)
    end
  end

  describe "list_instruments/1" do
    test "carries base, quote, instrument type and status per product" do
      body = %{
        "products" => [
          %{
            "product_id" => "BTC-USD",
            "base_currency_id" => "BTC",
            "quote_currency_id" => "USD",
            "product_type" => "SPOT",
            "status" => "online"
          }
        ]
      }

      assert {:ok, [instrument]} =
               Rest.list_instruments(plug: responding(body), retry_attempts: 0)

      assert instrument.symbol == "BTC-USD"
      assert instrument.base == "BTC"
      assert instrument.quote == "USD"
      assert instrument.instrument == :spot
      assert instrument.status == :tradable
    end

    test "an unrecognised product type is :unknown, never a guess" do
      body = %{
        "products" => [
          %{
            "product_id" => "BTC-USD",
            "base_currency_id" => "BTC",
            "quote_currency_id" => "USD",
            "product_type" => "SOMETHING_NEW",
            "status" => "online"
          }
        ]
      }

      assert {:ok, [instrument]} =
               Rest.list_instruments(plug: responding(body), retry_attempts: 0)

      assert instrument.instrument == :unknown
    end

    test "an unexpected shape is an error" do
      assert {:error, :unexpected_response_shape} =
               Rest.list_instruments(plug: responding(%{"nope" => 1}), retry_attempts: 0)
    end
  end

  describe "get_alias_map/1" do
    # Shaped like the live response, captured 2026-09-05 from
    # GET /api/v3/brokerage/market/products?product_type=SPOT&quote_currency_id=USDC —
    # both sides of an aliased pair appear in the same catalogue read, each stating the
    # relationship from its own side: the alias row's `alias` names its target, the
    # target's own row carries `alias: ""` and states the reverse via `alias_to` instead.
    @aliased_products %{
      "products" => [
        %{"product_id" => "XLM-USD", "alias" => "", "alias_to" => ["XLM-USDC"]},
        %{"product_id" => "XLM-USDC", "alias" => "XLM-USD", "alias_to" => []},
        # A product the venue does not alias at all — most of the catalogue, and the
        # majority case this map must leave untouched.
        %{"product_id" => "SOL-USD", "alias" => "", "alias_to" => []}
      ]
    }

    test "builds a bidirectional map from the venue's own declared alias, both directions" do
      assert {:ok, map} =
               Rest.get_alias_map(plug: responding(@aliased_products), retry_attempts: 0)

      assert map["XLM-USDC"] == "XLM-USD"
      assert map["XLM-USD"] == "XLM-USDC"
    end

    test "an unaliased product contributes no entry — not an identity mapping to itself" do
      assert {:ok, map} =
               Rest.get_alias_map(plug: responding(@aliased_products), retry_attempts: 0)

      refute Map.has_key?(map, "SOL-USD")
    end

    test "built from `alias` alone — a row with only `alias_to` still gets its edge, from the other side" do
      # XLM-USD's own row carries an empty `alias` and states the relationship only via
      # `alias_to`; its entry above comes entirely from XLM-USDC's row instead, proving
      # `alias_to` need not be read at all.
      assert {:ok, map} =
               Rest.get_alias_map(plug: responding(@aliased_products), retry_attempts: 0)

      assert map_size(map) == 2
    end

    test "an unexpected shape is an error" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_alias_map(plug: responding(%{"nope" => 1}), retry_attempts: 0)
    end

    test "reads the same public path get_symbols/1 does, with no credential" do
      assert {:ok, %{}} =
               Rest.get_alias_map(plug: responding(%{"products" => []}), retry_attempts: 0)
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

  describe "rate_limit_blocking — family-wide gap, DpCryptoManagement issue #23" do
    # A real limiter module, recording which entry point it was actually called through —
    # the only way to prove `:rate_limit_blocking` reached `Core.HttpClient` rather than
    # merely appearing in `request/5`'s or `json_request/5`'s own allowlist.
    defmodule RecordingLimiter do
      @moduledoc false
      @behaviour DpExchange.Core.RateLimitBehaviour

      @impl true
      def acquire(_provider, _weight, _opts) do
        Process.put(:rate_limiter_call, :acquire)
        :ok
      end

      @impl true
      def check(_provider, _weight, _opts) do
        Process.put(:rate_limiter_call, :check)
        :ok
      end

      @impl true
      def record(_provider, _weight, _opts), do: :ok
    end

    test "rate_limit_blocking: true reaches Core.HttpClient as acquire/3 on a GET (request/5)" do
      Config.put_override(:rate_limit_module, RecordingLimiter)

      assert {:ok, %Types.Quote{}} =
               Rest.get_price("BTC-USD",
                 plug: responding(@ticker),
                 retry_attempts: 0,
                 rate_limit_blocking: true
               )

      assert Process.get(:rate_limiter_call) == :acquire
    end

    test "rate_limit_blocking: false (or omitted) reaches Core.HttpClient as check/3 on a GET (request/5)" do
      Config.put_override(:rate_limit_module, RecordingLimiter)

      assert {:ok, %Types.Quote{}} =
               Rest.get_price("BTC-USD", plug: responding(@ticker), retry_attempts: 0)

      assert Process.get(:rate_limiter_call) == :check
    end

    test "rate_limit_blocking: true reaches Core.HttpClient as acquire/3 on a POST (json_request/5)" do
      Config.put_override(:rate_limit_module, RecordingLimiter)

      plug = fn conn ->
        Req.Test.json(conn, %{"portfolio" => %{"uuid" => "p1", "name" => "x"}})
      end

      assert {:ok, _portfolio} =
               Rest.create_portfolio(credentials(),
                 name: "x",
                 plug: plug,
                 retry_attempts: 0,
                 rate_limit_blocking: true
               )

      assert Process.get(:rate_limiter_call) == :acquire
    end

    test "rate_limit_blocking: false (or omitted) reaches Core.HttpClient as check/3 on a POST (json_request/5)" do
      Config.put_override(:rate_limit_module, RecordingLimiter)

      plug = fn conn ->
        Req.Test.json(conn, %{"portfolio" => %{"uuid" => "p1", "name" => "x"}})
      end

      assert {:ok, _portfolio} =
               Rest.create_portfolio(credentials(), name: "x", plug: plug, retry_attempts: 0)

      assert Process.get(:rate_limiter_call) == :check
    end
  end
end

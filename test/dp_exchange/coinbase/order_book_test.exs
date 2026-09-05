defmodule DpExchange.Coinbase.OrderBookTest do
  @moduledoc """
  Depth, and the top of it.

  **`get_top_of_book/2` used to read the ticker, which publishes no sizes**, so `bid_size`
  and `ask_size` were `nil` on every response. That was honest and avoidable: `/best_bid_ask`
  carries the size at each level, and a price without a size is half a top of book — a
  caller sizing against the best bid needs to know whether there is 0.01 there or 40.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Rest
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

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  # `/best_bid_ask` has no public form — unlike every other market-data endpoint this
  # module reads, `get_top_of_book/2` genuinely requires a credential. See its own doc.
  defp credentials do
    %{api_key: "organizations/x/apiKeys/y", api_secret: "-----BEGIN EC PRIVATE KEY-----"}
  end

  defp pricebook(overrides \\ %{}) do
    Map.merge(
      %{
        "product_id" => "BTC-USD",
        "bids" => [
          %{"price" => "79478.00", "size" => "0.5"},
          %{"price" => "79477.50", "size" => "1.25"}
        ],
        "asks" => [
          %{"price" => "79479.00", "size" => "0.25"},
          %{"price" => "79479.50", "size" => "2.0"}
        ],
        "time" => "2026-08-31T14:53:45.649112Z"
      },
      overrides
    )
  end

  describe "get_top_of_book/2 — the sizes the ticker never had" do
    test "both sides carry a price and a size" do
      body = %{"pricebooks" => [pricebook()]}

      assert {:ok, %Types.TopOfBook{} = top} =
               Rest.get_top_of_book("BTC-USD",
                 credentials: credentials(),
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(top.bid, Decimal.new("79478.00"))
      assert Decimal.equal?(top.ask, Decimal.new("79479.00"))
      assert Decimal.equal?(top.bid_size, Decimal.new("0.5"))
      assert Decimal.equal?(top.ask_size, Decimal.new("0.25"))
      assert top.provider == :coinbase
    end

    test "it reads only the best level, not the whole side" do
      body = %{"pricebooks" => [pricebook()]}

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD",
                 credentials: credentials(),
                 plug: responding(body),
                 retry_attempts: 0
               )

      refute Decimal.equal?(top.bid, Decimal.new("79477.50"))
    end

    test "the venue's own time is carried, and observed_at is ours" do
      body = %{"pricebooks" => [pricebook()]}

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD",
                 credentials: credentials(),
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert top.venue_time == ~U[2026-08-31 14:53:45.649112Z]
      assert top.observed_at
      refute top.venue_time == top.observed_at
    end

    test "an undated pricebook leaves venue_time nil rather than borrowing our clock" do
      body = %{"pricebooks" => [pricebook() |> Map.delete("time")]}

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD",
                 credentials: credentials(),
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert top.venue_time == nil
      # observed_at still says when we looked, which is the honest freshness.
      assert top.observed_at
    end

    test "no pricebook for the product is a refusal, not an empty book" do
      assert {:refused, :not_listed} =
               Rest.get_top_of_book("NOPE-USD",
                 credentials: credentials(),
                 plug: responding(%{"pricebooks" => []}),
                 retry_attempts: 0
               )
    end

    test "a body with no pricebooks key is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_top_of_book("BTC-USD",
                 credentials: credentials(),
                 plug: responding(%{}),
                 retry_attempts: 0
               )
    end

    test "it asks the venue for the one product" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"pricebooks" => [pricebook()]}))
      end

      assert {:ok, _top} =
               Rest.get_top_of_book("BTC-USD",
                 credentials: credentials(),
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, query, path}
      assert path =~ "best_bid_ask"
      assert query =~ "product_ids=BTC-USD"
    end

    test "without credentials it is refused before any request is sent — unlike every sibling reader" do
      # Re-verified live 2026-09-05: authenticated `/best_bid_ask` is 401, and the
      # `/market/best_bid_ask` a caller might expect by analogy with get_price/2,
      # get_order_book/2 and every other reader in this module is 404 — there is no
      # public form to fall back to. This must fail before a request goes out, naming
      # the missing credential, rather than surfacing the venue's 401 as an opaque error.
      me = self()

      plug = fn conn ->
        send(me, :request_sent)
        Req.Test.json(conn, %{"pricebooks" => [pricebook()]})
      end

      assert {:refused, :missing_credentials} =
               Rest.get_top_of_book("BTC-USD", plug: plug, retry_attempts: 0)

      refute_received :request_sent
    end

    test "with credentials it goes straight to /best_bid_ask, never a /market/ path" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})
        Req.Test.json(conn, %{"pricebooks" => [pricebook()]})
      end

      assert {:ok, _top} =
               Rest.get_top_of_book("BTC-USD",
                 credentials: credentials(),
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:path, path}
      assert path =~ "best_bid_ask"
      refute path =~ "/market/"
    end
  end

  describe "get_order_book/2" do
    test "both sides come back as levels of price and size" do
      body = %{"pricebook" => pricebook()}

      assert {:ok, %Types.OrderBook{} = book} =
               Rest.get_order_book("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert book.symbol == "BTC-USD"
      assert length(book.bids) == 2
      assert length(book.asks) == 2

      [{best_bid, best_bid_size} | _rest] = book.bids
      assert Decimal.equal?(best_bid, Decimal.new("79478.00"))
      assert Decimal.equal?(best_bid_size, Decimal.new("0.5"))
    end

    test "the venue's ordering is preserved, not re-sorted here" do
      # A book's order is the venue's statement about its own matching. Re-sorting would
      # hide a venue that sent a crossed or out-of-order book, which is the thing worth
      # seeing.
      body = %{
        "pricebook" =>
          pricebook(%{
            "bids" => [
              %{"price" => "79477.50", "size" => "1"},
              %{"price" => "79478.00", "size" => "1"}
            ]
          })
      }

      assert {:ok, book} =
               Rest.get_order_book("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert [{first, _first_size}, {second, _second_size}] = book.bids
      assert Decimal.equal?(first, Decimal.new("79477.50"))
      assert Decimal.equal?(second, Decimal.new("79478.00"))
    end

    test "a book the venue did not date is REFUSED, not stamped with the local clock" do
      # A depth snapshot carrying the client's clock cannot be told apart from a current
      # one, and a stale book read as current is the most expensive wrong number here.
      body = %{"pricebook" => pricebook() |> Map.delete("time")}

      assert {:error, :missing_venue_timestamp} =
               Rest.get_order_book("BTC-USD", plug: responding(body), retry_attempts: 0)
    end

    test "an unparsable time is refused too" do
      body = %{"pricebook" => pricebook(%{"time" => "just now"})}

      assert {:error, {:unparseable_venue_timestamp, _reason}} =
               Rest.get_order_book("BTC-USD", plug: responding(body), retry_attempts: 0)
    end

    test "the sequence is nil, because this endpoint publishes none" do
      # A caller must not learn to detect stream gaps from a REST book.
      body = %{"pricebook" => pricebook()}

      assert {:ok, book} =
               Rest.get_order_book("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert book.sequence == nil
    end

    test "an empty side is an empty list, not a missing one" do
      body = %{"pricebook" => pricebook(%{"asks" => []})}

      assert {:ok, book} =
               Rest.get_order_book("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert book.asks == []
      assert book.bids != []
    end

    test "the public book is read without a credential and the private one with" do
      # The venue publishes the same book twice. Reading the public one while holding a
      # credential would silently forgo whatever the authenticated view adds.
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"pricebook" => pricebook()}))
      end

      assert {:ok, _public} = Rest.get_order_book("BTC-USD", plug: plug, retry_attempts: 0)
      assert_receive {:path, public_path}
      assert public_path =~ "/market/product_book"

      credentials = %{
        api_key: "organizations/x/apiKeys/y",
        api_secret: "-----BEGIN EC PRIVATE KEY-----"
      }

      assert {:ok, _private} =
               Rest.get_order_book("BTC-USD",
                 credentials: credentials,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:path, private_path}
      refute private_path =~ "/market/"
      assert private_path =~ "/product_book"
    end

    test "limit and aggregation go to the venue" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"pricebook" => pricebook()}))
      end

      assert {:ok, _book} =
               Rest.get_order_book("BTC-USD",
                 limit: 50,
                 aggregation_price_increment: "0.01",
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, query}
      assert query =~ "limit=50"
      assert query =~ "aggregation_price_increment=0.01"
    end

    test "a body with no pricebook key is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_order_book("BTC-USD", plug: responding(%{}), retry_attempts: 0)
    end
  end

  describe "get_trades/2 — the prints get_price/2 discards" do
    test "every print comes back, not just the newest" do
      # get_price/2 reads this same payload and keeps one, because a Quote has room for one
      # price. The rest were discarded at the boundary.
      body = %{
        "trades" => [
          %{
            "trade_id" => "t-1",
            "price" => "79478.70",
            "size" => "0.25",
            "time" => "2026-08-28T14:53:45.649112Z",
            "side" => "BUY"
          },
          %{
            "trade_id" => "t-2",
            "price" => "79477.10",
            "size" => "0.10",
            "time" => "2026-08-28T14:53:40.649112Z",
            "side" => "SELL"
          }
        ]
      }

      assert {:ok, trades} =
               Rest.get_trades("BTC-USD", plug: responding(body), retry_attempts: 0)

      assert length(trades) == 2
      assert Enum.map(trades, & &1.id) == ["t-1", "t-2"]
      assert [%Types.Trade{} | _rest] = trades
    end

    test "the sides map, and an unknown one is nil" do
      body = %{
        "trades" => [
          %{
            "trade_id" => "t-1",
            "price" => "1",
            "size" => "1",
            "time" => "2026-08-28T14:53:45.649112Z",
            "side" => "SIDEWAYS"
          }
        ]
      }

      assert {:ok, [t]} = Rest.get_trades("BTC-USD", plug: responding(body), retry_attempts: 0)
      assert t.side == nil
    end

    test "an undated print is refused" do
      body = %{"trades" => [%{"trade_id" => "t-1", "price" => "1", "size" => "1"}]}

      assert {:error, :missing_venue_timestamp} =
               Rest.get_trades("BTC-USD", plug: responding(body), retry_attempts: 0)
    end

    test "broken is false — this venue publishes no bust flag here" do
      body = %{
        "trades" => [
          %{
            "trade_id" => "t-1",
            "price" => "1",
            "size" => "1",
            "time" => "2026-08-28T14:53:45.649112Z",
            "side" => "BUY"
          }
        ]
      }

      assert {:ok, [t]} = Rest.get_trades("BTC-USD", plug: responding(body), retry_attempts: 0)
      refute t.broken
    end

    test "the public path is used without a credential" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"trades" => []}))
      end

      assert {:ok, []} = Rest.get_trades("BTC-USD", plug: plug, retry_attempts: 0)
      assert_receive {:path, path}
      assert path =~ "/market/products/BTC-USD/ticker"
    end

    test "a body with no trades key is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_trades("BTC-USD", plug: responding(%{}), retry_attempts: 0)
    end
  end

  describe "quantization — four increments, and they are not interchangeable" do
    @product %{
      "product_id" => "BTC-USD",
      "base_increment" => "0.00000001",
      "quote_increment" => "0.01",
      "base_min_size" => "0.000016",
      "quote_min_size" => "1",
      "base_max_size" => "3500",
      "quote_max_size" => "150000000",
      "status" => "online"
    }

    test "the PRICE increment is quote_increment, not base_increment" do
      # A caller rounding a price to the base increment produces an order the venue rejects
      # on a field it did not name.
      assert {:ok, q} =
               Rest.quantization("BTC-USD", plug: responding(@product), retry_attempts: 0)

      assert Decimal.equal?(q.price_increment, Decimal.new("0.01"))
      assert Decimal.equal?(q.quantity_increment, Decimal.new("0.00000001"))
      refute Decimal.equal?(q.price_increment, q.quantity_increment)
    end

    test "both minima are carried, because they bound different things" do
      # base_min_size is units of the base asset; quote_min_size is cash. A market order
      # sized in cash is bounded by the second and a limit order in units by the first.
      assert {:ok, q} =
               Rest.quantization("BTC-USD", plug: responding(@product), retry_attempts: 0)

      assert Decimal.equal?(q.min_quantity, Decimal.new("0.000016"))
      assert Decimal.equal?(q.min_quote_size, Decimal.new("1"))
    end

    test "the status is the venue's own word, not a boolean" do
      # A boolean loses the difference between a product that is paused and one that is gone.
      assert {:ok, q} =
               Rest.quantization("BTC-USD",
                 plug: responding(%{@product | "status" => "delisted"}),
                 retry_attempts: 0
               )

      assert q.status == "delisted"
    end

    test "the public path is used without a credential and the private one with" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@product))
      end

      assert {:ok, _q} = Rest.quantization("BTC-USD", plug: plug, retry_attempts: 0)
      assert_receive {:path, public}
      assert public =~ "/market/products/BTC-USD"

      credentials = %{
        api_key: "organizations/x/apiKeys/y",
        api_secret: "-----BEGIN EC PRIVATE KEY-----"
      }

      assert {:ok, _q2} =
               Rest.quantization("BTC-USD",
                 credentials: credentials,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:path, private}
      refute private =~ "/market/"
    end

    test "get_product/2 returns the whole record, which quantization does not" do
      # A caller choosing a market wants the status and the display names; a caller rounding
      # an order does not.
      assert {:ok, product} =
               Rest.get_product("BTC-USD", plug: responding(@product), retry_attempts: 0)

      assert product["product_id"] == "BTC-USD"
      assert product["base_max_size"] == "3500"
    end

    test "a body that is not a product is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.quantization("BTC-USD", plug: responding(%{}), retry_attempts: 0)
    end
  end
end

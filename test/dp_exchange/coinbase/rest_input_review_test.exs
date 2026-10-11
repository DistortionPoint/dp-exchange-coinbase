defmodule DpExchange.Coinbase.RestInputReviewTest do
  @moduledoc """
  Inputs and replies `Rest` used to pass through unchecked: a catalogue page that promised
  more and gave no cursor, an empty portfolio id, an amount that is not a positive Decimal,
  a margin setting or stop direction outside the spec's enum, an inverted candle window.
  Each is refused locally (or as an error) before a request or instead of a short answer.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Rest
  alias DpExchange.Core.Config

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

  defp exploding(test_pid) do
    fn conn ->
      send(test_pid, {:request_sent, conn.request_path})
      Plug.Conn.resp(conn, 500, "must not be reached")
    end
  end

  defp opts(extra \\ []),
    do: Keyword.merge([plug: exploding(self()), retry_attempts: 0], extra)

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  test "a catalogue page with has_next and no cursor is an error, not a short catalogue" do
    page = %{
      "products" => [%{"product_id" => "BTC-USD"}],
      "pagination" => %{"has_next" => true}
    }

    assert {:error, :pagination_cursor_missing} =
             Rest.get_symbols(plug: responding(page), retry_attempts: 0)

    done = %{page | "pagination" => %{"has_next" => false}}

    assert {:ok, ["BTC-USD"]} = Rest.get_symbols(plug: responding(done), retry_attempts: 0)
  end

  test "an empty portfolio uuid is refused before any request" do
    expected = {:error, {:invalid_id, :portfolio_uuid, ""}}

    assert expected == Rest.get_portfolio_breakdown(@credentials, "", opts())
    assert expected == Rest.rename_portfolio(@credentials, "", "name", opts())
    assert expected == Rest.delete_portfolio(@credentials, "", opts())
    refute_received {:request_sent, _path}
  end

  test "money amounts must be finite positive Decimals" do
    for bad <- [1.5, "1", 0, Decimal.new("0"), Decimal.new("-1"), Decimal.new("NaN")] do
      assert {:error, {:invalid_amount, _bad}} =
               Rest.quote_conversion(@credentials, "USD", "USDC", bad, opts())

      assert {:error, {:invalid_amount, _bad}} =
               Rest.transfer_internal(@credentials, "USD", bad, opts(from: "a", to: "b"))
    end

    refute_received {:request_sent, _path}
  end

  test "a margin setting outside the spec's enum is refused" do
    assert {:error, {:invalid_margin_setting, "INTRADAY"}} =
             Rest.set_intraday_margin_setting(@credentials, "INTRADAY", opts())

    refute_received {:request_sent, _path}
  end

  test "an empty or inverted candle window is refused, not sent" do
    at = ~U[2026-08-28 12:00:00Z]

    assert {:error, {:invalid_range, _window}} =
             Rest.get_historical_prices("BTC-USD", "1m", [start: at, end: at], opts())

    assert {:error, {:invalid_range, _window}} =
             Rest.get_historical_prices(
               "BTC-USD",
               "1m",
               [start: DateTime.add(at, 600, :second), end: at],
               opts()
             )

    refute_received {:request_sent, _path}
  end

  test "get_trades wants a positive integer limit" do
    for bad <- [0, -1, "5", 1.5] do
      assert {:error, {:invalid_limit, ^bad}} = Rest.get_trades("BTC-USD", opts(limit: bad))
    end

    refute_received {:request_sent, _path}
  end

  describe "get_top_of_book/2 picks the pricebook for the product asked for" do
    defp book(product, price) do
      %{
        "product_id" => product,
        "bids" => [%{"price" => price, "size" => "1"}],
        "asks" => [%{"price" => price, "size" => "1"}],
        "time" => "2026-08-31T14:53:45Z"
      }
    end

    test "not the first one" do
      body = %{"pricebooks" => [book("ETH-USD", "3000"), book("BTC-USD", "80000")]}

      assert {:ok, top} =
               Rest.get_top_of_book("BTC-USD",
                 credentials: @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert Decimal.equal?(top.bid, Decimal.new("80000"))
    end

    test "none naming it is a refusal, not another product's prices" do
      body = %{"pricebooks" => [book("ETH-USD", "3000")]}

      assert {:error, {:product_not_in_response, "BTC-USD"}} =
               Rest.get_top_of_book("BTC-USD",
                 credentials: @credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end
  end

  test "an order status filter outside the spec's enum is refused" do
    assert {:error, {:invalid_status, "bogus"}} =
             Rest.get_orders(@credentials, opts(status: "bogus"))

    assert {:error, {:invalid_status, :nope}} =
             Rest.get_orders(@credentials, opts(status: [:open, :nope]))

    refute_received {:request_sent, _path}
  end

  describe "place_order leaf fields" do
    defp stop_limit(extra) do
      Map.merge(
        %{
          symbol: "BTC-USD",
          side: :buy,
          order_type: :stop_limit,
          time_in_force: :gtc,
          quantity: "1",
          price: "100",
          stop_price: "101"
        },
        extra
      )
    end

    test "a stop direction outside the spec's enum is refused" do
      assert {:error, {:invalid_stop_direction, "SIDEWAYS"}} =
               Rest.place_order(@credentials, stop_limit(%{stop_direction: "SIDEWAYS"}), opts())

      refute_received {:request_sent, _path}
    end

    test "post_only must be a boolean" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        order_type: :limit,
        time_in_force: :gtc,
        quantity: "1",
        price: "100",
        post_only: "yes"
      }

      assert {:error, {:invalid_post_only, "yes"}} =
               Rest.place_order(@credentials, request, opts())

      refute_received {:request_sent, _path}
    end
  end
end

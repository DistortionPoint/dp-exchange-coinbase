defmodule DpExchange.Coinbase.FillsTest do
  @moduledoc """
  Past fills.

  The assertion worth the most here is about `trade_type`. Regular fills carry `FILL`; the
  venue also emits `REVERSAL`, `CORRECTION` and `SYNTHETIC` for adjusted ones. **A reversal
  is not a trade that happened**, and `Core.Types.Fill` has no field to say so — summing a
  list that mixes them produces a position and a cost basis that are both wrong and both
  entirely plausible.
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

  @credentials %{
    api_key: "organizations/x/apiKeys/y",
    api_secret: "-----BEGIN EC PRIVATE KEY-----"
  }

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp fill(overrides \\ %{}) do
    Map.merge(
      %{
        "entry_id" => "22222-2222222-22222222",
        "trade_id" => "1111-11111-111111",
        "order_id" => "0000-000000-000000",
        "trade_time" => "2026-08-31T09:59:59Z",
        "trade_type" => "FILL",
        "price" => "40100.50",
        "size" => "0.25",
        "commission" => "1.20",
        "product_id" => "BTC-USD",
        "liquidity_indicator" => "TAKER",
        "side" => "BUY"
      },
      overrides
    )
  end

  describe "the venue's own fill" do
    test "comes back as a Fill with the venue's numbers" do
      body = %{"fills" => [fill()], "cursor" => ""}

      assert {:ok, [f]} =
               Rest.get_trade_history(@credentials, plug: responding(body), retry_attempts: 0)

      assert %Types.Fill{} = f
      assert f.order_id == "0000-000000-000000"
      assert f.trade_id == "1111-11111-111111"
      assert f.symbol == "BTC-USD"
      assert f.side == :buy
      assert Decimal.equal?(f.quantity, Decimal.new("0.25"))
      assert Decimal.equal?(f.price, Decimal.new("40100.50"))
      assert Decimal.equal?(f.fee, Decimal.new("1.20"))
      assert f.liquidity == :taker
      assert f.timestamp == ~U[2026-08-31 09:59:59Z]
      assert f.provider == :coinbase
    end

    test "the fee currency is nil, not the pair's quote guessed from the symbol" do
      # A fee can be charged in a third asset and often is. Naming USD because the pair ends
      # in USD would be a claim the venue never made.
      body = %{"fills" => [fill()], "cursor" => ""}

      assert {:ok, [f]} =
               Rest.get_trade_history(@credentials, plug: responding(body), retry_attempts: 0)

      assert f.fee_currency == nil
    end

    test "an unknown liquidity indicator is nil, including the venue's own UNKNOWN" do
      # `UNKNOWN_LIQUIDITY_INDICATOR` is the venue saying it does not know. Neither :maker
      # nor :taker is an honest answer to that.
      body = %{
        "fills" => [fill(%{"liquidity_indicator" => "UNKNOWN_LIQUIDITY_INDICATOR"})],
        "cursor" => ""
      }

      assert {:ok, [f]} =
               Rest.get_trade_history(@credentials, plug: responding(body), retry_attempts: 0)

      assert f.liquidity == nil
    end

    test "a fill the venue did not date is refused, never stamped with the local clock" do
      # A fill is an event that happened at a moment. A client timestamp places it wrongly
      # in a trade history while looking entirely reasonable.
      body = %{"fills" => [fill(%{"trade_time" => nil})], "cursor" => ""}

      assert {:error, :missing_venue_timestamp} =
               Rest.get_trade_history(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "an unparsable time is refused too" do
      body = %{"fills" => [fill(%{"trade_time" => "yesterday"})], "cursor" => ""}

      assert {:error, {:unparseable_venue_timestamp, _reason}} =
               Rest.get_trade_history(@credentials, plug: responding(body), retry_attempts: 0)
    end
  end

  describe "trade_type — a reversal is not a trade that happened" do
    test "adjusted fills are excluded by default" do
      body = %{
        "fills" => [fill(), fill(%{"trade_id" => "t-2", "trade_type" => "REVERSAL"})],
        "cursor" => ""
      }

      assert {:ok, [only]} =
               Rest.get_trade_history(@credentials, plug: responding(body), retry_attempts: 0)

      assert only.trade_id == "1111-11111-111111"
    end

    test "asking for them widens the answer, and they are not hidden entirely" do
      # Refusing to return corrections at all would hide adjustments the venue made.
      body = %{
        "fills" => [fill(), fill(%{"trade_id" => "t-2", "trade_type" => "REVERSAL"})],
        "cursor" => ""
      }

      assert {:ok, both} =
               Rest.get_trade_history(@credentials,
                 trade_types: ["FILL", "REVERSAL"],
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert length(both) == 2
    end

    test "a CORRECTION is excluded by default like a REVERSAL is" do
      body = %{"fills" => [fill(%{"trade_type" => "CORRECTION"})], "cursor" => ""}

      assert {:ok, []} =
               Rest.get_trade_history(@credentials, plug: responding(body), retry_attempts: 0)
    end
  end

  describe "filters and paging" do
    test "filters go to the venue, not to the page it returned" do
      # A client-side filter over one page silently drops matching fills that were on the
      # next one.
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"fills" => [], "cursor" => ""}))
      end

      assert {:ok, []} =
               Rest.get_trade_history(@credentials,
                 order_id: "abc",
                 symbol: "BTC-USD",
                 start: ~U[2026-08-01 00:00:00Z],
                 limit: 100,
                 plug: plug,
                 retry_attempts: 0
               )

      assert_receive {:query, query}
      assert query =~ "order_ids=abc"
      assert query =~ "product_ids=BTC-USD"
      assert query =~ "start_sequence_timestamp"
      assert query =~ "limit=100"
    end

    test "it follows the cursor to the end" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        body =
          if conn.query_string =~ "cursor=page2" do
            %{"fills" => [fill(%{"trade_id" => "t-2"})], "cursor" => ""}
          else
            %{"fills" => [fill()], "cursor" => "page2"}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, fills} =
               Rest.get_trade_history(@credentials, plug: plug, retry_attempts: 0)

      assert Enum.map(fills, & &1.trade_id) == ["1111-11111-111111", "t-2"]
    end

    test "an empty page stops the walk rather than asking again" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"fills" => [], "cursor" => "always"}))
      end

      assert {:ok, []} = Rest.get_trade_history(@credentials, plug: plug, retry_attempts: 0)
    end

    test "a server that always sends a cursor and rows is bounded" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"fills" => [fill()], "cursor" => "always"}))
      end

      assert {:error, :too_many_fill_pages} =
               Rest.get_trade_history(@credentials, plug: plug, retry_attempts: 0)
    end

    test "a body with no fills key is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_trade_history(@credentials, plug: responding(%{}), retry_attempts: 0)
    end
  end
end

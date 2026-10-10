defmodule DpExchange.Coinbase.ReviewHardeningTest do
  @moduledoc """
  Failures found 2026-10-10 by reading `Rest` against the vendor schema, each pinned by the
  shape that used to get through: an anonymous request to a private endpoint, `%{}` read as
  a credential, a fill whose size may be quote currency, a cancel row that raised, an
  applied edit reported as failed, and an alias map that lost every source but one.
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

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp exploding(test_pid) do
    fn conn ->
      send(test_pid, {:request_sent, conn.request_path})
      Plug.Conn.resp(conn, 500, "must not be reached")
    end
  end

  describe "explicit nil credentials on a private endpoint" do
    test "get_balances/2 refuses locally instead of sending an anonymous request" do
      assert {:error, {:missing_credentials, :coinbase}} =
               Rest.get_balances(nil, plug: exploding(self()), retry_attempts: 0)

      refute_received {:request_sent, _path}
    end

    test "get_trade_history/2 refuses locally, the same as the %{} default" do
      assert {:error, {:missing_credentials, :coinbase}} =
               Rest.get_trade_history(nil, plug: exploding(self()), retry_attempts: 0)

      assert {:error, {:missing_credentials, :coinbase}} =
               Rest.get_trade_history(%{}, plug: exploding(self()), retry_attempts: 0)

      refute_received {:request_sent, _path}
    end
  end

  describe "an empty credentials map is no credential" do
    test "a public market-data call carrying %{} takes the unsigned /market path" do
      me = self()

      plug = fn conn ->
        send(me, {:seen, conn.request_path, Plug.Conn.get_req_header(conn, "authorization")})

        body = %{
          "trades" => [
            %{
              "product_id" => "BTC-USD",
              "price" => "1",
              "size" => "1",
              "time" => "2026-08-28T14:53:45.649112Z",
              "bid" => "",
              "ask" => ""
            }
          ],
          "best_bid" => "1",
          "best_ask" => "1"
        }

        responding(body).(conn)
      end

      assert {:ok, _quote} =
               Rest.get_price("BTC-USD", credentials: %{}, plug: plug, retry_attempts: 0)

      assert_received {:seen, path, []}
      assert path =~ "/market/"
    end
  end

  describe "get_trade_history/2 and a quote-sized fill" do
    defp fill_row(overrides) do
      Map.merge(
        %{
          "trade_id" => "t-1",
          "order_id" => "o-1",
          "trade_time" => "2026-08-31T09:59:59Z",
          "trade_type" => "FILL",
          "price" => "10000",
          "size" => "100",
          "commission" => "0.1",
          "product_id" => "BTC-USD",
          "side" => "BUY",
          "size_in_quote" => false
        },
        overrides
      )
    end

    test "a base-sized fill is returned" do
      assert {:ok, [fill]} =
               Rest.get_trade_history(@credentials,
                 plug: responding(%{"fills" => [fill_row(%{})]}),
                 retry_attempts: 0
               )

      assert Decimal.equal?(fill.quantity, Decimal.new("100"))
    end

    test "size_in_quote: true is refused rather than reported as a base quantity" do
      body = %{"fills" => [fill_row(%{}), fill_row(%{"size_in_quote" => true})]}

      assert {:error, {:unsupported_fill_size_unit, :quote}} =
               Rest.get_trade_history(@credentials, plug: responding(body), retry_attempts: 0)
    end
  end

  describe "cancel_order/3 with a row that is neither success nor a stated failure" do
    test "success false with no failure_reason is an unreadable answer, not a crash" do
      body = %{"results" => [%{"order_id" => "abc", "success" => false}]}

      assert {:error, :unexpected_response_shape} =
               Rest.cancel_order(@credentials, "abc", plug: responding(body), retry_attempts: 0)
    end

    test "a non-boolean success is an unreadable answer, not a crash" do
      body = %{"results" => [%{"order_id" => "abc", "success" => "yes"}]}

      assert {:error, :unexpected_response_shape} =
               Rest.cancel_order(@credentials, "abc", plug: responding(body), retry_attempts: 0)
    end
  end

  describe "replace_order/4 when the edit applied but the read-back failed" do
    test "the error names the order and says the edit was accepted" do
      plug = fn conn ->
        if conn.request_path =~ "edit" do
          responding(%{"success" => true}).(conn)
        else
          Plug.Conn.resp(conn, 500, "boom")
        end
      end

      assert {:error, {:edit_accepted_refetch_failed, "abc-123", _reason}} =
               Rest.replace_order(
                 @credentials,
                 "abc-123",
                 %{price: Decimal.new("41000"), quantity: Decimal.new("0.5")},
                 plug: plug,
                 retry_attempts: 0
               )
    end
  end

  describe "get_alias_map/1 is many-to-one" do
    test "a target aliased by several sources lists every one of them" do
      body = %{
        "products" => [
          %{"product_id" => "XLM-USDC", "alias" => "XLM-USD"},
          %{"product_id" => "XLM-EURC", "alias" => "XLM-USD"},
          %{"product_id" => "XLM-USD", "alias" => ""}
        ]
      }

      assert {:ok, map} = Rest.get_alias_map(plug: responding(body), retry_attempts: 0)

      assert map["XLM-USD"] == ["XLM-EURC", "XLM-USDC"]
      assert map["XLM-USDC"] == ["XLM-USD"]
      assert map["XLM-EURC"] == ["XLM-USD"]
    end
  end
end

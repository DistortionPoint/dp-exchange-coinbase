defmodule DpExchange.Coinbase.JwtBindingTest do
  @moduledoc """
  The REST JWT binds one request: its `uri` claim is `METHOD host/path`, it is valid for two
  minutes, and the venue answers a stale or mismatched one with a 401.

  These tests read the `Authorization` header the venue would see, for every HTTP verb this
  package sends, and pin three things: the claim names the verb and path of THAT request (no
  query string), each attempt of a retried read carries a token minted for it, and a 401
  reaches a documented refusal after exactly one attempt rather than a retry loop.

  A preview whose answer carries none of the fields the spec requires is also pinned here:
  it is `{:error, :unexpected_response_shape}`, not a preview of nothing.
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

  @host_path "api.coinbase.com/api/v3/brokerage"

  defp recording(me, status, body) do
    fn conn ->
      [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      send(me, {:request, conn.method, authorization})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp uri_claim("Bearer " <> token) do
    [_header, claims, _signature] = String.split(token, ".")
    {:ok, decoded} = Base.url_decode64(claims, padding: false)
    decoded |> Jason.decode!() |> Map.fetch!("uri")
  end

  defp limit_request do
    %{
      symbol: "BTC-USD",
      side: :buy,
      quantity: Decimal.new("0.5"),
      price: Decimal.new("40000"),
      order_type: :limit,
      time_in_force: :gtc
    }
  end

  describe "the uri claim of each verb" do
    test "a GET names GET and the path, never the query string" do
      me = self()

      assert {:ok, []} =
               Rest.get_balances(@credentials,
                 plug: recording(me, 200, %{"accounts" => []}),
                 retry_attempts: 0,
                 limit: 5
               )

      assert_receive {:request, "GET", authorization}, 5_000
      assert uri_claim(authorization) == "GET #{@host_path}/accounts"
    end

    test "a POST names POST and its path" do
      me = self()
      body = %{"results" => [%{"order_id" => "ord-1", "success" => true}]}

      assert {:ok, :cancelled} =
               Rest.cancel_order(@credentials, "ord-1", plug: recording(me, 200, body))

      assert_receive {:request, "POST", authorization}, 5_000
      assert uri_claim(authorization) == "POST #{@host_path}/orders/batch_cancel"
    end

    test "a PUT names PUT and its path" do
      me = self()
      body = %{"portfolio" => %{"uuid" => "p-1", "name" => "n"}}

      assert {:ok, _portfolio} =
               Rest.rename_portfolio(@credentials, "p-1", "n",
                 plug: recording(me, 200, body),
                 retry_attempts: 0
               )

      assert_receive {:request, "PUT", authorization}, 5_000
      assert uri_claim(authorization) == "PUT #{@host_path}/portfolios/p-1"
    end

    test "a DELETE names DELETE and its path" do
      me = self()

      assert {:ok, %{}} =
               Rest.delete_portfolio(@credentials, "p-1", plug: recording(me, 200, %{}))

      assert_receive {:request, "DELETE", authorization}, 5_000
      assert uri_claim(authorization) == "DELETE #{@host_path}/portfolios/p-1"
    end

    test "an id with reserved characters is signed as it is sent, percent-encoded" do
      me = self()
      body = %{"order" => %{"order_id" => "x"}}

      assert {:ok, _order} =
               Rest.get_order(@credentials, "a b/c",
                 plug: recording(me, 200, body),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", authorization}, 5_000
      assert uri_claim(authorization) == "GET #{@host_path}/orders/historical/a%20b%2Fc"
    end
  end

  describe "a retried read" do
    test "signs every attempt anew, each for the same method and path" do
      me = self()

      assert {:error, {:exchange_error, :coinbase, _message}} =
               Rest.get_orders(@credentials,
                 plug: recording(me, 503, %{"message" => "unavailable"}),
                 retry_attempts: 3,
                 retry_delay: 1
               )

      tokens =
        for _attempt <- 1..3 do
          assert_receive {:request, "GET", authorization}, 5_000
          authorization
        end

      assert length(Enum.uniq(tokens)) == 3

      for authorization <- tokens do
        assert uri_claim(authorization) == "GET #{@host_path}/orders/historical/batch"
      end
    end
  end

  describe "a 401 from an expired or mismatched token" do
    test "is a refusal after one attempt, not a retry loop" do
      me = self()

      assert {:refused, {:venue_error, 401, "token expired"}} =
               Rest.get_orders(@credentials,
                 plug: recording(me, 401, %{"message" => "token expired"}),
                 retry_attempts: 3,
                 retry_delay: 1
               )

      assert_receive {:request, "GET", _authorization}, 5_000
      refute_receive {:request, _method, _authorization}, 500
    end
  end

  describe "a preview whose answer is not a preview" do
    test "an order preview without the required errs is unreadable, not empty" do
      for body <- [%{}, %{"order_total" => "1"}, %{"errs" => nil}] do
        assert {:error, :unexpected_response_shape} =
                 Rest.preview_order(@credentials, limit_request(),
                   plug: recording(self(), 200, body),
                   retry_attempts: 0
                 )
      end
    end

    test "an edit preview without the required errors is unreadable, not empty" do
      changes = %{price: Decimal.new("40000"), quantity: Decimal.new("1")}

      for body <- [%{}, %{"order_total" => "1"}, %{"errors" => nil}] do
        assert {:error, :unexpected_response_shape} =
                 Rest.preview_replace(@credentials, "abc-123", changes,
                   plug: recording(self(), 200, body),
                   retry_attempts: 0
                 )
      end
    end

    test "an empty errs list is still a preview" do
      assert {:ok, %{order_total: total}} =
               Rest.preview_order(@credentials, limit_request(),
                 plug: recording(self(), 200, %{"errs" => [], "order_total" => "1"}),
                 retry_attempts: 0
               )

      assert Decimal.equal?(total, 1)
    end
  end
end

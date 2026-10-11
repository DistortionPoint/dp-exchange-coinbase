defmodule DpExchange.Coinbase.PathSegmentTest do
  @moduledoc """
  A caller-supplied id that becomes a URL path segment is escaped, and an empty one is
  refused: `get_payment_method(_, "")` used to ask `/payment_methods/`, the list endpoint,
  and `"../x"`-style ids reached a different resource under a JWT minted for that path.
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

  defp capturing(test_pid, body) do
    fn conn ->
      send(test_pid, {:path, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp opts(extra \\ []),
    do: Keyword.merge([plug: capturing(self(), %{}), retry_attempts: 0], extra)

  test "an empty id is refused before any request" do
    assert {:error, {:invalid_id, :payment_method_id, ""}} =
             Rest.get_payment_method(@credentials, "", opts())

    assert {:error, {:invalid_id, :product_id, ""}} =
             Rest.get_futures_position(@credentials, "", opts())

    conversion = opts(from: "a", to: "b")

    assert {:error, {:invalid_id, :trade_id, ""}} =
             Rest.get_conversion(@credentials, "", conversion)

    assert {:error, {:invalid_id, :trade_id, ""}} =
             Rest.commit_conversion(@credentials, "", conversion)

    refute_received {:path, _path}
  end

  test "a payment method id is one escaped segment" do
    body = %{"payment_method" => %{"id" => "x"}}
    plug = capturing(self(), body)

    assert {:ok, _method} =
             Rest.get_payment_method(@credentials, "a/b?c", plug: plug, retry_attempts: 0)

    assert_receive {:path, path}, 5_000
    assert path == "/api/v3/brokerage/payment_methods/a%2Fb%3Fc"
  end

  test "dot segments are escaped rather than navigated" do
    body = %{"position" => %{}}
    plug = capturing(self(), body)

    assert {:ok, _position} =
             Rest.get_futures_position(@credentials, "..", plug: plug, retry_attempts: 0)

    assert_receive {:path, path}, 5_000
    assert path == "/api/v3/brokerage/cfm/positions/%2E%2E"
  end
end

defmodule DpExchange.Coinbase.WriteOnceTest do
  @moduledoc """
  A write the venue cannot tell from its own repeat is sent once.

  `Core.HttpClient` retries a 5xx or a transport error, and neither says whether the venue
  acted before it answered. For `move_funds` and a futures sweep a retry moves the money
  again. For a conversion commit or an order edit that already took effect it comes back
  refused, telling the caller a success failed. For a portfolio create it leaves a
  duplicate. See `Rest`'s `post_once/4`.
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

  # Every request is answered 502 and counted. `retry_delay: 1` keeps a retrying build fast
  # enough to fail this suite rather than stall it.
  defp failing(test_pid) do
    fn conn ->
      send(test_pid, {:request, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(502, Jason.encode!(%{"error" => "bad gateway"}))
    end
  end

  defp opts(extra), do: [plug: failing(self()), retry_delay: 1] ++ extra

  defp requests(acc \\ []) do
    receive do
      {:request, path} -> requests([path | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  test "move_funds is sent once" do
    Rest.transfer_internal(@credentials, "USD", Decimal.new("1"), opts(from: "a", to: "b"))
    assert [_one] = requests()
  end

  test "a futures sweep is sent once" do
    Rest.schedule_futures_sweep(@credentials, opts(usd_amount: Decimal.new("5")))
    assert [_one] = requests()
  end

  test "a conversion commit is sent once" do
    Rest.commit_conversion(@credentials, "trade-1", opts(from: "a", to: "b"))
    assert [_one] = requests()
  end

  test "a portfolio create is sent once" do
    Rest.create_portfolio(@credentials, opts(name: "p"))
    assert [_one] = requests()
  end

  test "an order edit is sent once" do
    Rest.replace_order(@credentials, "order-1", %{price: Decimal.new("10")}, opts([]))
    assert [_one] = requests()
  end

  test "a caller can still ask for retries explicitly" do
    Rest.transfer_internal(
      @credentials,
      "USD",
      Decimal.new("1"),
      opts(from: "a", to: "b", retry_attempts: 2)
    )

    assert [_first, _second] = requests()
  end
end

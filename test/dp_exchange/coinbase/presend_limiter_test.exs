defmodule DpExchange.Coinbase.PresendLimiterTest do
  @moduledoc """
  A write refused by this package's own rate limiter was decided before anything left the
  process, so it is a plain error and not an "unconfirmed" one (family convention W1): a
  caller told the write may have happened would go looking for an order that cannot exist.

  Two ways the limiter says no that the other write tests do not use. A limiter that is
  BLOCKING gives up waiting (`:rate_limit_timeout`), and one that cannot answer at all fails
  closed ("Rate limiter unavailable"). Both are asserted for the order path and the Prime
  staking path, which count signed attempts separately and read the same two answers.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Prime, Rest}
  alias DpExchange.Core.Config

  @moduletag :capture_log

  # Gives up waiting, as a blocking `acquire/3` does when its bound runs out.
  defmodule TimingOutLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :rate_limit_timeout}
    @impl true
    def check(_provider, _weight, _opts), do: {:rate_limited, 2_000}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  # Cannot answer at all, as a limiter whose process is not running cannot.
  defmodule DownLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :limiter_down}
    @impl true
    def check(_provider, _weight, _opts), do: {:error, :limiter_down}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  @credentials %{
    api_key: "organizations/x/apiKeys/y",
    api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
  }
  @prime_credentials %{
    access_key: "prime-key",
    passphrase: "prime-passphrase",
    signing_key: "prime-signing-key"
  }

  @order %{
    symbol: "BTC-USD",
    side: :buy,
    order_type: :limit,
    time_in_force: :gtc,
    quantity: Decimal.new("0.5"),
    price: Decimal.new("40000")
  }

  # A venue that must never be reached: reaching it is the failure these tests rule out.
  defp unreachable_venue(test_pid) do
    fn conn ->
      send(test_pid, :reached_the_venue)
      Plug.Conn.resp(conn, 200, "{}")
    end
  end

  defp request_opts(extra), do: [plug: unreachable_venue(self()), retry_attempts: 0] ++ extra

  describe "placing an order" do
    test "a blocking limiter that times out is a plain error: nothing was sent" do
      Config.put_override(:rate_limit_module, TimingOutLimiter)
      opts = request_opts(rate_limit_blocking: true)

      assert {:error, {:exchange_error, :coinbase, :rate_limit_timeout}} =
               Rest.place_order(@credentials, @order, opts)

      refute_received :reached_the_venue
    end

    test "a limiter that cannot answer fails closed, and is a plain error too" do
      Config.put_override(:rate_limit_module, DownLimiter)
      opts = request_opts([])

      assert {:error, {:exchange_error, :coinbase, "Rate limiter unavailable"}} =
               Rest.place_order(@credentials, @order, opts)

      refute_received :reached_the_venue
    end
  end

  describe "a Prime staking write" do
    test "a blocking limiter that times out is a plain error: nothing was sent" do
      Config.put_override(:rate_limit_module, TimingOutLimiter)
      opts = request_opts(rate_limit_blocking: true)
      amount = Decimal.new("1")

      assert {:error, {:exchange_error, :coinbase, :rate_limit_timeout}} =
               Prime.stake_portfolio(@prime_credentials, "pf-1", "ETH", amount, opts)

      refute_received :reached_the_venue
    end

    test "a limiter that cannot answer fails closed, and is a plain error too" do
      Config.put_override(:rate_limit_module, DownLimiter)
      opts = request_opts([])
      amount = Decimal.new("1")

      assert {:error, {:exchange_error, :coinbase, "Rate limiter unavailable"}} =
               Prime.stake_portfolio(@prime_credentials, "pf-1", "ETH", amount, opts)

      refute_received :reached_the_venue
    end
  end
end

defmodule DpExchange.Coinbase.SupervisorTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Supervisor, as: VenueSupervisor
  alias DpExchange.Core.DefaultRateLimiter

  @moduletag :capture_log

  # Every test starts its own named instance. A test that reaches for a globally-named
  # process depends on the order the suite happens to run in — which is the exact
  # async-hostile shape this package's own isolation seam exists to prevent, so a test
  # here should not be committing it.
  defp start_venue do
    id = System.unique_integer([:positive])
    opts = [name: :"venue_#{id}", limiter: :"limiter_#{id}", feed: :"feed_#{id}"]

    start_supervised!(%{id: opts[:name], start: {DpExchange.Coinbase, :start_link, [opts]}})
    opts
  end

  describe "the venue starts its own rate limiter" do
    test "configured from the ceilings capabilities/0 declares" do
      # The declaration is not decoration sitting beside the mechanism — it IS the
      # mechanism's configuration, so the two cannot drift apart.
      opts = start_venue()
      limiter = VenueSupervisor.limiter_name(opts)

      assert is_pid(GenServer.whereis(limiter))
      assert DpExchange.Coinbase.capabilities().public_ceiling == %{limit: 3, per_ms: 1_000}

      # Three per second declared, so three immediate acquires and no fourth.
      for _i <- 1..3 do
        assert :ok = DefaultRateLimiter.acquire(:coinbase, 1, limiter: limiter, timeout: 0)
      end

      assert {:error, :rate_limit_timeout} =
               DefaultRateLimiter.acquire(:coinbase, 1, limiter: limiter, timeout: 0)
    end

    test "without one, every request fails closed — which is why the venue starts it" do
      # Core's HttpClient refuses when no limiter is reachable, and that is correct: an
      # unmetered package is how a venue answers 429 while a budget panel reads
      # comfortable. But a venue package expecting someone else to start a limiter
      # answers "Rate limiter unavailable" to everything, with nothing saying what is
      # missing. Found by this package's tier-2 tests, not by its tier-1 ones.
      assert {:error, :not_started} =
               DefaultRateLimiter.check(:coinbase, 1, limiter: :a_limiter_nobody_started)
    end
  end

  describe "the tree" do
    test "starts the feed alongside the limiter" do
      opts = start_venue()
      assert is_pid(GenServer.whereis(VenueSupervisor.feed_name(opts)))
    end

    test "two instances run side by side without colliding" do
      # Two credentials, two scopes. Hardcoding either child's name means the second
      # instance fails to start — which is a failure at boot rather than in production,
      # but still one a consumer should not have to discover.
      a = start_venue()
      b = start_venue()

      refute VenueSupervisor.feed_name(a) == VenueSupervisor.feed_name(b)
      assert is_pid(GenServer.whereis(VenueSupervisor.feed_name(a)))
      assert is_pid(GenServer.whereis(VenueSupervisor.feed_name(b)))
    end

    test "each instance meters against its own bucket" do
      a = start_venue()
      b = start_venue()

      # Spend a's budget entirely.
      for _i <- 1..3,
          do: DefaultRateLimiter.acquire(:coinbase, 1, limiter: a[:limiter], timeout: 0)

      assert {:error, :rate_limit_timeout} =
               DefaultRateLimiter.acquire(:coinbase, 1, limiter: a[:limiter], timeout: 0)

      # b is untouched. A shared bucket would have made one consumer's traffic throttle
      # another's.
      assert :ok = DefaultRateLimiter.acquire(:coinbase, 1, limiter: b[:limiter], timeout: 0)
    end
  end
end

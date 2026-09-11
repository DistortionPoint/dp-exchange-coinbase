defmodule DpExchange.Coinbase.SupervisorTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Supervisor, as: VenueSupervisor
  alias DpExchange.Core.DefaultRateLimiter

  @moduletag :capture_log

  # Every test starts its own named instance. A test that reaches for a globally-named
  # process depends on the order the suite happens to run in — which is the exact
  # async-hostile shape this package's own isolation seam exists to prevent, so a test
  # here should not be committing it.
  defp start_venue(extra_opts \\ []) do
    id = System.unique_integer([:positive])

    opts =
      Keyword.merge(
        [name: :"venue_#{id}", limiter: :"limiter_#{id}", feed: :"feed_#{id}"],
        extra_opts
      )

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

      # Three per second declared, so the bucket drains in one weight-3 reservation.
      assert_ceiling(limiter, 3)
    end

    test "with credentials, the limiter is configured from the AUTHENTICATED ceiling" do
      # `capabilities/0`'s own moduledoc claim — "Pass credentials and this package uses
      # the authenticated path, which has the higher ceiling" — is a promise about the
      # mechanism, not just the declaration. Before this fix `limits/1` read only
      # `public_ceiling` regardless of `opts[:credentials]`, which throttled a
      # credentialed consumer's authenticated traffic to a third of what the venue
      # actually allows it, silently.
      opts =
        start_venue(
          credentials: %{api_key: "k", api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="}
        )

      limiter = VenueSupervisor.limiter_name(opts)

      caps = DpExchange.Coinbase.capabilities()
      assert caps.authenticated_ceiling == %{limit: 10, per_ms: 1_000}

      assert_ceiling(limiter, 10)
    end

    test "an empty credentials map does not buy the higher ceiling" do
      # `%{}` is truthy but names no actual credential — `Rest`'s own request paths treat
      # it the same as absent (`if credentials, do: authenticated_path, else: public_path`
      # would be wrong for `%{}` too, which is why this is worth pinning down here rather
      # than assuming `Keyword.get/2` truthiness is enough).
      opts = start_venue(credentials: %{})
      limiter = VenueSupervisor.limiter_name(opts)

      assert_ceiling(limiter, 3)
    end

    # Pins the ceiling at exactly `ceiling`, without depending on elapsed time anywhere.
    #
    # Both earlier versions of this were races, and the second one is the instructive one.
    # It started as a loop of `ceiling` single-token acquires followed by one that had to
    # fail — but this is a token bucket that refills CONTINUOUSLY, so at `limit: 10,
    # per_ms: 1_000` a token returns every 100 ms, and a loop that spans more than that on a
    # loaded, instrumented suite leaves a refilled token for the last assertion. It flaked
    # about one run in seven under `--cover`.
    #
    # Collapsing the loop into one atomic weight-N reservation made the window smaller and
    # did not close it: the refill happens between the drain returning and the next call
    # arriving, so ANY assertion of the form "the bucket is empty now" races the clock. It
    # still flaked, just more rarely — which is worse, because rarer looks like fixed.
    #
    # What is time-independent is the SHAPE of the bucket rather than its level. A weight
    # above the ceiling can never be satisfied however long you wait, because the bucket
    # cannot hold that many; a weight at the ceiling succeeds from a fresh one. Together
    # they pin the ceiling exactly, which is what these tests meant to assert all along —
    # that the limiter was configured from the authenticated ceiling rather than the public
    # one — instead of how fast the machine happens to be.
    defp assert_ceiling(limiter, ceiling) do
      assert {:error, :rate_limit_timeout} =
               DefaultRateLimiter.acquire(:coinbase, ceiling + 1, limiter: limiter, timeout: 0)

      assert :ok = DefaultRateLimiter.acquire(:coinbase, ceiling, limiter: limiter, timeout: 0)
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

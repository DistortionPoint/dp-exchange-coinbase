defmodule DpExchange.Coinbase.AliasAttributionTest do
  @moduledoc """
  The alias catalogue: fetching it, failing to, and what a consumer is told either way.

  Every describe here is about the same seam — the venue rewrites an aliased product id on
  delivery, so a feed that cannot read the catalogue is reporting symbols under names its
  caller did not ask for. The family's signature defect is a plausible value with the wrong
  meaning, and a silently-unaliased symbol is exactly that, which is why these cost a retry
  ladder each rather than asserting on one attempt. Split out for wall clock — see
  `DpExchange.Coinbase.FeedCase`.
  """

  use DpExchange.Coinbase.FeedCase, async: true

  import ExUnit.CaptureLog

  alias DpExchange.Coinbase.Feed
  alias DpExchange.Core.{DefaultRateLimiter, Notice, Types}

  describe "the alias-catalogue fetch cannot wedge itself" do
    # `state.alias_map_fetch` is what `start_alias_map_fetch/2` checks to refuse a second
    # concurrent fetch. If it is ever left set by a fetch that will never answer, every later
    # `:fetch_alias_map` tick is dropped and no retry happens again for the life of the feed
    # — with `alias_map_status` reading `:pending`, not `:failed`, so nothing reports it
    # either. Both ways that could happen are covered here; both were verified to wedge
    # before the fix.

    test "a task killed from outside is retried, not left pinned forever" do
      # `safely_fetch_alias_map/1` converts a raise or an `exit` inside the task into an
      # ordinary error result, and says in its own comment that this keeps the fetch from
      # being "pinned forever". It does — for those two. A kill is untrappable, so no
      # `rescue` or `catch` runs, and that was the hole.
      test_pid = self()

      source = fn ->
        send(test_pid, {:fetching, self()})
        Process.sleep(:infinity)
      end

      feed = start_wedge_feed(alias_map_source: source, alias_map_retry_delay_ms: 5)
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      assert_receive {:fetching, task_pid}, 2_000
      Process.exit(task_pid, :kill)

      # The retry ladder picks it straight back up rather than dropping the tick.
      assert_receive {:fetching, second_pid}, 2_000
      assert second_pid != task_pid
      assert Process.alive?(feed)
    end

    test "a task that simply never answers is timed out and retried" do
      # The other half, and the one no `:DOWN` can catch: the task is perfectly alive, it
      # just never returns. Only a timer can tell that apart from one about to succeed.
      test_pid = self()

      source = fn ->
        send(test_pid, {:fetching, self()})
        Process.sleep(:infinity)
      end

      feed =
        start_wedge_feed(
          alias_map_source: source,
          alias_map_fetch_timeout_ms: 50,
          alias_map_retry_delay_ms: 5
        )

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      assert_receive {:fetching, first_pid}, 2_000
      assert_receive {:fetching, second_pid}, 2_000
      assert second_pid != first_pid

      # And the timed-out task is actually gone, not left running behind the feed's back.
      wait_until(fn -> not Process.alive?(first_pid) end)
      assert Process.alive?(feed)
    end

    test "a hang that never resolves still gives up loudly rather than retrying forever" do
      # Transient does not mean infinite. A persistent hang exhausts the ladder and lands on
      # the same `:unavailable` status a permanent failure gets, which is what a consumer can
      # actually see — unlike `:pending`, which is what the wedge used to leave behind.
      source = fn -> Process.sleep(:infinity) end

      feed =
        start_wedge_feed(
          alias_map_source: source,
          alias_map_fetch_timeout_ms: 20,
          alias_map_retry_delay_ms: 5
        )

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      wait_until(fn -> :sys.get_state(feed).alias_map_status == :unavailable end)

      state = :sys.get_state(feed)
      assert state.alias_map_fetch == nil
      assert Process.alive?(feed)
    end

    test "a timer left over from a fetch that already answered is ignored" do
      # The timeout is armed per attempt and matched on the tracked ref, so one arriving for
      # a fetch that has since succeeded must not tear down whatever is running now.
      feed = start_wedge_feed(alias_map_source: fn -> {:ok, %{"A-USD" => "B-USD"}} end)
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: self())

      wait_until(fn -> :sys.get_state(feed).alias_map_status == :ok end)

      send(feed, {:alias_map_fetch_timeout, make_ref()})
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      assert state.alias_map_status == :ok
      assert state.alias_map == %{"A-USD" => "B-USD"}
      assert Process.alive?(feed)
    end

    # `start_feed/1` puts its own `alias_map_source` FIRST in the keyword list, and
    # `Keyword.get/2` takes the first occurrence — so an `alias_map_source:` passed through it
    # is silently ignored and the default stub runs instead. That cost this file's first draft
    # of these tests a confusing round of "the fetch never starts"; building the opts directly
    # is what makes the injection actually take.
    defp start_wedge_feed(opts) do
      name = :"feed_#{System.unique_integer([:positive])}"
      start_supervised!({Feed, [name: name] ++ opts}, id: name)
    end
  end

  describe "attribution — the venue rewrites an aliased product id on delivery" do
    # Measured live 2026-09-05 against wss://advanced-trade-ws.coinbase.com: subscribing
    # `ticker` to `["XLM-USDC", "AVAX-USDC"]` — the alias form, and only that — delivers
    # every frame tagged `XLM-USD`/`AVAX-USD`, the canonical form, and the venue's own
    # subscription ack echoes the rewritten names back rather than what was sent. These
    # tests drive that exact mechanism without reaching the venue: `alias_map_source`
    # stands in for `Rest.get_alias_map/1`, answering with the venue's own declared
    # relationship the way the real fetch would.
    @alias_map %{"XLM-USDC" => "XLM-USD", "XLM-USD" => "XLM-USDC"}

    defp start_aliased_feed(alias_map_source) do
      start_supervised!(
        {Feed,
         name: :"feed_#{System.unique_integer([:positive])}",
         url: "ws://127.0.0.1:1/nowhere",
         alias_map_source: alias_map_source}
      )
    end

    test "a subscribe to the alias form receiving frames tagged with the canonical form delivers under the alias form" do
      feed = start_aliased_feed(fn -> {:ok, @alias_map} end)

      # The socket cannot connect (unreachable url), but `wanted` records the caller's
      # own requested name regardless — exactly as the pre-existing "subscribe with a
      # socket that will not connect" tests already establish.
      Feed.subscribe(feed, ~w(XLM-USDC), to: self())

      # `subscribe/3` returning does NOT mean the alias map has arrived: it only
      # SCHEDULES the fetch (`Process.send_after(self(), :fetch_alias_map, 0)`), a
      # genuinely separate async message from the timer wheel rather than something
      # `subscribe/3`'s own call return orders against. Waiting for it directly, rather
      # than assuming a fixed delay is enough, is what makes the delivery below
      # deterministic instead of a race between the fetch and the send just after it.
      wait_until(fn -> :sys.get_state(feed).alias_map_status == :ok end)

      # Simulates `Socket` delivering a frame the venue tagged with the canonical id —
      # the live-measured behaviour above — without opening a real connection.
      send(feed, {:dp_exchange, :coinbase, quote_for("XLM-USD")})

      # See "notice subscribers do not receive market data" above for why a negative
      # mailbox assertion needs this sync barrier rather than a sleep.
      :sys.get_state(feed)
      assert_received {:dp_exchange, :coinbase, %Types.Quote{symbol: "XLM-USDC"}}
      refute_received {:dp_exchange, :coinbase, %Types.Quote{symbol: "XLM-USD"}}
    end

    test "coverage/1 lists what the caller requested, never what the venue delivered under" do
      feed = start_aliased_feed(fn -> {:ok, @alias_map} end)

      Feed.subscribe(feed, ~w(XLM-USDC), to: self())
      # See the previous test for why this cannot be assumed complete just because
      # `subscribe/3` has returned.
      wait_until(fn -> :sys.get_state(feed).alias_map_status == :ok end)
      send(feed, {:dp_exchange, :coinbase, quote_for("XLM-USD")})

      assert Feed.coverage(feed) == %{"XLM-USDC" => :stream}
    end

    test "subscribing to both the alias and the canonical name delivers both, from one frame" do
      # The venue treats the two as one market. A caller that asked for both is entitled
      # to both, from whichever single id the venue actually tags the frame with.
      feed = start_aliased_feed(fn -> {:ok, @alias_map} end)

      Feed.subscribe(feed, ~w(XLM-USDC XLM-USD), to: self())
      wait_until(fn -> :sys.get_state(feed).alias_map_status == :ok end)
      send(feed, {:dp_exchange, :coinbase, quote_for("XLM-USD")})
      :sys.get_state(feed)

      assert_received {:dp_exchange, :coinbase, %Types.Quote{symbol: "XLM-USDC"}}
      assert_received {:dp_exchange, :coinbase, %Types.Quote{symbol: "XLM-USD"}}

      coverage = Feed.coverage(feed)
      assert coverage["XLM-USDC"] == :stream
      assert coverage["XLM-USD"] == :stream
    end

    test "unsubscribe still works by the name the caller used" do
      feed = start_aliased_feed(fn -> {:ok, @alias_map} end)

      Feed.subscribe(feed, ~w(XLM-USDC), to: self())
      wait_until(fn -> :sys.get_state(feed).alias_map_status == :ok end)
      send(feed, {:dp_exchange, :coinbase, quote_for("XLM-USD")})
      assert Feed.coverage(feed) == %{"XLM-USDC" => :stream}

      assert :ok = Feed.unsubscribe(feed, ~w(XLM-USDC))
      assert Feed.coverage(feed) == %{}
    end

    test "a catalogue fetch failure delivers under the venue's own id and reports degraded attribution, never a guessed mapping" do
      feed = start_aliased_feed(fn -> {:error, :simulated_catalog_failure} end)

      Feed.subscribe_notices(feed, to: self())
      Feed.subscribe(feed, ~w(XLM-USDC), to: self())

      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :data_quality, details: %{reason: reason}} = notice},
                     500

      assert reason =~ "simulated_catalog_failure"
      assert notice.message =~ "alias catalogue unavailable"

      send(feed, {:dp_exchange, :coinbase, quote_for("XLM-USD")})
      :sys.get_state(feed)

      # Delivered under the venue's own id — never the caller's requested XLM-USDC —
      # because there is no honest way to know they name the same market without the
      # catalogue that says so. Guessing from the shared "-USD"/"-USDC" suffix is exactly
      # the nearby substitute this family forbids.
      assert_received {:dp_exchange, :coinbase, %Types.Quote{symbol: "XLM-USD"}}
      refute_received {:dp_exchange, :coinbase, %Types.Quote{symbol: "XLM-USDC"}}

      coverage = Feed.coverage(feed)
      assert coverage["XLM-USD"] == :stream
      refute Map.has_key?(coverage, "XLM-USDC")
    end

    test "the catalogue is fetched once, never per subscribe and never per delivered frame" do
      counter = :counters.new(1, [])

      feed =
        start_aliased_feed(fn ->
          :counters.add(counter, 1, 1)
          {:ok, @alias_map}
        end)

      Feed.subscribe(feed, ~w(XLM-USDC), to: self())
      Feed.subscribe(feed, ~w(AVAX-USDC), to: self())
      Feed.update_symbols(feed, ~w(XLM-USDC AVAX-USDC))

      # The three calls above are themselves synchronous, but the fetch they schedule is
      # NOT — `maybe_schedule_alias_map_fetch/1` only sends itself `:fetch_alias_map`,
      # it does not run it inline. Waiting for the counter directly, rather than a fixed
      # sleep, is what actually proves the fetch completed exactly once.
      wait_until(fn -> :counters.get(counter, 1) == 1 end)

      # None of the raw `send/2` deliveries below go through `subscribe/3` or
      # `update_symbols/2`, so nothing here can schedule a second fetch — no further
      # synchronisation is needed before the final assertion.
      for _i <- 1..5, do: send(feed, {:dp_exchange, :coinbase, quote_for("XLM-USD")})

      assert :counters.get(counter, 1) == 1
    end
  end

  describe "the alias-map fetch has to wait, not fail — DpCryptoManagement issue #26" do
    # Every other describe block in this file injects `alias_map_source` — a fast,
    # hermetic stand-in for the real fetch. That is exactly how this defect went
    # unnoticed: nothing in this suite exercised the real fetch pipeline's own options.
    # These tests start `Feed` with NO `alias_map_source` override, so
    # `default_alias_map_source/2` builds the real closure, and drive it through a real,
    # named `DefaultRateLimiter` (standing in for "the caller's own limiter is contended
    # at boot") plus a fake `:plug` response — both forwarded into `Rest.get_alias_map/1`
    # by `default_alias_map_source/2` reading this module's own `opts`, per the
    # moduledoc.

    # A single-token bucket with its one token already spent: the next `acquire/3` or
    # `check/3` against it needs to wait out `per_ms` before proceeding. Mirrors
    # `dp_exchange_robinhood`'s own `exhausted_limiter/0` (issue #16), which established
    # this exact technique for proving `rate_limit_blocking` reaches `Core.HttpClient`
    # without reaching into a different process's `Config` override — a separately
    # supervised `Feed` would never see one anyway.
    defp exhausted_limiter do
      name = :"limiter_#{System.unique_integer([:positive])}"

      {:ok, _pid} =
        DefaultRateLimiter.start_link(
          name: name,
          limits: %{default: %{limit: 1, per_ms: 200, burst: 0}}
        )

      :ok = DefaultRateLimiter.record(:coinbase, 1, limiter: name)
      name
    end

    defp responding(body) do
      fn conn -> Req.Test.json(conn, body) end
    end

    test "the fetch waits out the caller's own exhausted rate limiter instead of giving up permanently" do
      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           url: "ws://127.0.0.1:1/nowhere",
           limiter: exhausted_limiter(),
           plug: responding(%{"products" => []})}
        )

      Feed.subscribe(feed, ~w(BTC-USD), to: self())

      # Without `rate_limit_blocking: true` this venue's own limiter refuses the fetch
      # immediately (fail-fast `check/3`), `transient_alias_map_failure?/1` does not
      # treat that refusal as transient (it is not — nothing about the request changes by
      # retrying it instantly), and the fetch gives up for good within milliseconds. With
      # `rate_limit_blocking: true` reaching `Core.HttpClient`, `acquire/3` waits out the
      # ~200ms the exhausted bucket needs to refill and the identical fetch then
      # succeeds — proving the option actually reached the request, not merely that it
      # survived being typed into an allowlist.
      wait_until(fn -> :sys.get_state(feed).alias_map_status != :pending end)

      assert :sys.get_state(feed).alias_map_status == :ok
    end
  end

  describe "the alias-map fetch is classified and retried — DpCryptoManagement issue #26" do
    # `alias_map_source` fails `fail_times` times with `reason`, then succeeds forever —
    # mirrors `flaky_socket/2` above for the channel-subscribe retry chain. `counter`
    # records every attempt actually made, which is how a test proves a retry happened
    # rather than inferring it from timing.
    defp flaky_alias_map_source(fail_times, counter, reason) do
      fn ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) <= fail_times do
          {:error, reason}
        else
          {:ok, %{}}
        end
      end
    end

    # Never recovers — mirrors `always_fails_socket/1` above. `counter` is how the
    # exhaustion test proves the retry chain is bounded: the count stops rising once the
    # code gives up.
    defp always_fails_alias_map_source(counter, reason) do
      fn ->
        :counters.add(counter, 1, 1)
        {:error, reason}
      end
    end

    test "a transient failure (the rate limiter's own bounded wait timing out) is retried and succeeds on a later attempt" do
      counter = :counters.new(1, [])

      source =
        flaky_alias_map_source(1, counter, {:exchange_error, :coinbase, :rate_limit_timeout})

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           alias_map_source: source,
           alias_map_retry_delay_ms: 5}
        )

      log =
        capture_log(fn ->
          Feed.subscribe(feed, ~w(BTC-USD), to: self())

          # Wait for the retry to actually land rather than sleeping a guessed duration —
          # see `wait_until/1`.
          wait_until(fn -> :counters.get(counter, 1) == 2 end)
        end)

      # Two calls reached the source: the failed first attempt and the retry that
      # succeeded. Never exhausted, never gave up.
      assert :counters.get(counter, 1) == 2
      assert :sys.get_state(feed).alias_map_status == :ok
      # Every one of these matches the ALIAS CATALOGUE line specifically, not the bare
      # phrase. `capture_log/1` captures the whole VM, not this process, and this package
      # logs "giving up", "retrying in" and "not retrying" on the shard-subscribe path too —
      # which since these tests moved into their own file runs CONCURRENTLY with them. A
      # bare `refute log =~ "giving up"` then fails on somebody else's ticker shard, and a
      # bare `assert log =~ "giving up"` passes on it, which is worse. Matched as a whole
      # line so neither can happen.
      assert log =~ ~r/alias catalogue fetch failed \(.*\), attempt 1\/3 — retrying in 5ms/
      refute log =~ ~r/alias catalogue fetch failed after/
    end

    test "a permanent failure is not retried and fails loudly" do
      counter = :counters.new(1, [])
      source = always_fails_alias_map_source(counter, :boom)

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           alias_map_source: source,
           alias_map_retry_delay_ms: 5}
        )

      Feed.subscribe_notices(feed, to: self())

      log =
        capture_log(fn ->
          Feed.subscribe(feed, ~w(BTC-USD), to: self())

          # The notice is the completion signal — waiting on it, rather than on a clock,
          # guarantees the permanent-failure branch has actually run before it is
          # asserted against.
          assert_receive {:dp_exchange, :coinbase,
                          %Notice{kind: :data_quality, details: %{reason: reason}}},
                         2_000

          assert reason =~ "boom"
        end)

      # Every one of these matches the ALIAS CATALOGUE line specifically, not the bare
      # phrase. `capture_log/1` captures the whole VM, not this process, and this package
      # logs "giving up", "retrying in" and "not retrying" on the shard-subscribe path too —
      # which since these tests moved into their own file runs CONCURRENTLY with them. A
      # bare `refute log =~ "giving up"` then fails on somebody else's ticker shard, and a
      # bare `assert log =~ "giving up"` passes on it, which is worse. Matched as a whole
      # line so neither can happen.
      assert log =~
               ~r/alias catalogue fetch failed permanently \(.*\) — not retrying; delivering under the venue's own product id/

      refute log =~ ~r/alias catalogue fetch failed \(.*\), attempt/

      # Exactly one call, ever — the notice above only fires after the decision is made,
      # so nothing further could have been scheduled by the time it arrives.
      assert :counters.get(counter, 1) == 1
      assert :sys.get_state(feed).alias_map_status == :unavailable
    end

    test "retries are bounded, and exhausting them still reports degraded attribution" do
      counter = :counters.new(1, [])
      reason = {:exchange_error, :coinbase, :rate_limit_timeout}
      source = always_fails_alias_map_source(counter, reason)

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           alias_map_source: source,
           alias_map_retry_delay_ms: 5}
        )

      Feed.subscribe_notices(feed, to: self())

      log =
        capture_log(fn ->
          Feed.subscribe(feed, ~w(BTC-USD), to: self())
          assert_receive {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}, 2_000
        end)

      # Every one of these matches the ALIAS CATALOGUE line specifically, not the bare
      # phrase. `capture_log/1` captures the whole VM, not this process, and this package
      # logs "giving up", "retrying in" and "not retrying" on the shard-subscribe path too —
      # which since these tests moved into their own file runs CONCURRENTLY with them. A
      # bare `refute log =~ "giving up"` then fails on somebody else's ticker shard, and a
      # bare `assert log =~ "giving up"` passes on it, which is worse. Matched as a whole
      # line so neither can happen.
      assert log =~
               ~r/alias catalogue fetch failed after \d+ attempt\(s\) \(.*\) — giving up; delivering under the venue's own product/

      # One initial attempt plus @max_alias_map_retries (2) retries — three calls, and
      # never a fourth, proving the chain is bounded rather than open-ended.
      assert :counters.get(counter, 1) == 3
      assert :sys.get_state(feed).alias_map_status == :unavailable
    end
  end

  describe "a late notice subscriber still learns attribution is degraded — DpCryptoManagement issue #26" do
    test "subscribe_notices/1 called after subscribe/2 still receives the degraded-attribution notice" do
      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           alias_map_source: fn -> {:error, :simulated_catalog_failure} end}
        )

      # The ordinary sequence a real consumer follows: subscribe first — which is what
      # schedules the alias-map fetch, see the moduledoc — notices second. Waiting for
      # the fetch to have actually failed before registering proves the notice genuinely
      # fired with zero notice_subscribers before this test ever calls
      # `subscribe_notices/1`; this is not merely "moved the emission a few lines
      # earlier".
      Feed.subscribe(feed, ~w(BTC-USD), to: self())
      wait_until(fn -> :sys.get_state(feed).alias_map_status == :unavailable end)

      assert :ok = Feed.subscribe_notices(feed, to: self())

      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :data_quality, details: %{reason: reason}} = notice},
                     500

      assert reason =~ "simulated_catalog_failure"
      assert notice.message =~ "alias catalogue unavailable"
    end

    test "nothing is replayed once attribution is healthy" do
      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           alias_map_source: fn -> {:ok, %{}} end}
        )

      Feed.subscribe(feed, ~w(BTC-USD), to: self())
      wait_until(fn -> :sys.get_state(feed).alias_map_status == :ok end)

      assert :ok = Feed.subscribe_notices(feed, to: self())
      refute_receive {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}, 200
    end

    test "an already-registered subscriber is not replayed the notice a second time" do
      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           alias_map_source: fn -> {:error, :simulated_catalog_failure} end}
        )

      Feed.subscribe_notices(feed, to: self())
      Feed.subscribe(feed, ~w(BTC-USD), to: self())

      assert_receive {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}, 500

      # Registering again must not re-fire it — the replay is keyed to a NEW
      # registration, not to every call this consumer happens to make.
      assert :ok = Feed.subscribe_notices(feed, to: self())
      refute_receive {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}, 200
    end
  end

  describe "a read cannot be blocked by the alias-catalogue fetch (core #28's class)" do
    # NOT `start_feed/1`: that helper PREPENDS its own `alias_map_source` default, and
    # `Keyword.get/3` takes the first match — so a source passed through it is silently
    # shadowed and never called. These tests need their own slow source, so they build the
    # child spec directly.
    defp start_feed_with_source(source) do
      name = :"feed_#{System.unique_integer([:positive])}"
      start_supervised!({Feed, name: name, alias_map_source: source}, id: name)
    end

    test "coverage/1 answers while the alias map is still being fetched" do
      # The fetch reads the venue's whole `/market/products` catalogue over HTTP and used
      # to run INLINE in `handle_info(:fetch_alias_map, ...)`. With `Core.HttpClient`'s
      # documented defaults (30_000 ms per attempt, 3 attempts) that blocked this
      # GenServer for up to about ninety seconds, and `coverage/1`/`coverage_by_kind/1`
      # are plain `GenServer.call/2`s on the FIVE-second default — so a health check
      # landing during the fetch did not wait, it exited, taking a consumer that reads it
      # from its own `handle_call/3` with it.
      #
      # dp-exchange-core issue #28's failure, on a third venue. Found by sweeping this
      # family for the class the #30 reporter named — "work done in the process that owes
      # a reply" — not by it recurring in production.
      test_pid = self()

      feed =
        start_feed_with_source(fn ->
          send(test_pid, :fetch_started)
          Process.sleep(2_000)
          {:ok, %{}}
        end)

      send(feed, :fetch_alias_map)
      assert_receive :fetch_started, 1_000

      reader = Task.async(fn -> Feed.coverage(feed) end)
      result = Task.yield(reader, 500) || Task.shutdown(reader, :brutal_kill)

      assert match?({:ok, _}, result),
             "coverage/1 did not answer within 500ms while the alias catalogue was being " <>
               "fetched — the Feed is blocked inside handle_info. got: #{inspect(result)}"

      assert Process.alive?(feed)
    end

    test "a second tick during an in-flight fetch does not start a second catalogue read" do
      # Two catalogue reads racing to write `state.alias_map` would let the loser silently
      # overwrite the winner, and would double a request this venue's rate limiter is
      # sized for one of.
      test_pid = self()

      feed =
        start_feed_with_source(fn ->
          send(test_pid, :fetch_started)
          Process.sleep(300)
          {:ok, %{}}
        end)

      send(feed, :fetch_alias_map)
      assert_receive :fetch_started, 1_000

      send(feed, :fetch_alias_map)
      refute_receive :fetch_started, 200

      assert Process.alive?(feed)
    end
  end
end

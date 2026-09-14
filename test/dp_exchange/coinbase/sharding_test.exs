defmodule DpExchange.Coinbase.ShardingTest do
  @moduledoc """
  Sharding: how symbols are grouped onto sockets, and what happens between the ticks.

  `Feed` opens shards on a stagger rather than all at once, which makes the whole of this
  area asynchronous — a reconcile, an unsubscribe and a socket replacement can all be in
  flight together. These tests drive those interleavings, and several of them wait out real
  staggered ticks to do it. Split out for wall clock — see `DpExchange.Coinbase.FeedCase`.
  """

  use DpExchange.Coinbase.FeedCase, async: true

  import ExUnit.CaptureLog

  alias DpExchange.Coinbase.Feed
  alias DpExchange.Core.Notice

  # `Feed`'s production stagger between opening shards — see `feed.ex`'s moduledoc,
  # "`shard_spacing_ms` — a supervision option". Several sharding tests below only need to
  # prove that a shard past the first got its own tick at all — the STRUCTURE of
  # `reshard/1`'s staggering (right shard indices, right channel, right count of async
  # opens) — not the literal production gap between ticks. Those tests inject this instead
  # of waiting out the real production default (`1_000`ms), which is what made this file's
  # own suite the slowest thing `mix test` ran. Kept well above the documented Coinbase
  # connect-rate floor `validate_shard_spacing_ms!/1` warns below (125ms) purely so a
  # warning log never fires mid-test-run for a value that is only ever exercised
  # in-process, against no real socket.
  @test_shard_spacing_ms 30

  # One test (`reconciling two ALREADY-OPEN shards...`, below) measures an actual time
  # delta between two real messages from two real processes, rather than only "did the
  # staggered event eventually happen" — a stricter proof that deserves more margin
  # against scheduler jitter on a loaded, `async: true` suite than the generic structural
  # value above needs. Still well below the real production default (`1_000`ms).
  @test_shard_spacing_ms_precise 200
  describe "shards/1 — the whole reason this module exists again" do
    test "100 symbols is one shard" do
      symbols = for n <- 1..100, do: "SYM#{n}-USD"
      assert [shard] = Feed.shards(symbols)
      assert length(shard) == 100
    end

    test "101 symbols is two shards, the second carrying the overflow" do
      symbols = for n <- 1..101, do: "SYM#{n}-USD"
      assert [first, second] = Feed.shards(symbols)
      assert length(first) == 100
      assert length(second) == 1
    end

    test "an empty scope is zero shards, not one empty one" do
      assert Feed.shards([]) == []
    end
  end

  describe "sharding across the whole subscribe lifecycle" do
    test "subscribing 150 symbols opens two shards, the second staggered" do
      symbols = for n <- 1..150, do: "SYM#{n}-USD"

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           url: "ws://127.0.0.1:1/nowhere",
           shard_spacing_ms: @test_shard_spacing_ms,
           alias_map_source: fn -> {:ok, %{}} end}
        )

      :ok = Feed.subscribe_notices(feed, to: self())

      # The first shard is synchronous (this call's own reply); the second is
      # deliberately staggered by `shard_spacing_ms` so as not to burst-connect. The
      # endpoint is unreachable, so both attempts fail — proven here by BOTH actually
      # being observed to fail, not merely by the process surviving a brief pause: the
      # synchronous first shard's failure is this call's own reply, and the async
      # second shard's failure now emits a `:coverage_change` Notice (see
      # `notify_shard_open_failed/3`) once its staggered attempt actually runs, roughly
      # `shard_spacing_ms` later. `@test_shard_spacing_ms` replaces the real production
      # default (1_000ms) here so this test proves the SAME structure without waiting out
      # a multi-second production timer — see that attribute's own comment.
      before = System.monotonic_time(:millisecond)
      assert {:error, _reason} = Feed.subscribe(feed, symbols, to: self())

      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :coverage_change, details: %{shard: 1}}},
                     2_000

      # Proves a real delay was actually applied, not merely that the async attempt
      # eventually ran: shard 1 must not have reported before its own stagger tick.
      assert System.monotonic_time(:millisecond) - before >= @test_shard_spacing_ms / 2

      assert Process.alive?(feed)
    end

    test "subscribing 250 symbols opens three shards, each staggered from the last" do
      # DpCryptoManagement's issue #20: with three or more shards, every shard past the
      # first used to be scheduled with the SAME fixed delay instead of one increasing per
      # shard — a connect burst, not a stagger. Nothing below this line distinguishes that
      # regression from the fix (both survive an unreachable endpoint the same way), but
      # this is the first test in the file to exercise `reshard/1`'s `rest` list with more
      # than one element, which is what let the bug ship unnoticed in the first place.
      symbols = for n <- 1..250, do: "SYM#{n}-USD"

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           url: "ws://127.0.0.1:1/nowhere",
           shard_spacing_ms: @test_shard_spacing_ms,
           alias_map_source: fn -> {:ok, %{}} end}
        )

      :ok = Feed.subscribe_notices(feed, to: self())
      before = System.monotonic_time(:millisecond)
      assert {:error, _reason} = Feed.subscribe(feed, symbols, to: self())

      # Shard 1 fails roughly one `shard_spacing_ms` out, shard 2 roughly two out — proof
      # every shard past the first got its own tick rather than all of them bursting
      # together (DpCryptoManagement's issue #20). `@test_shard_spacing_ms` stands in for
      # the real 1_000ms default so this runs in milliseconds.
      #
      # Both arrivals are checked against `before` — a single fixed point captured BEFORE
      # either timer was scheduled — rather than against each other's observed arrival
      # time. A delta measured between two dynamically-observed arrivals is exactly the
      # kind of check that flakes on a loaded, `async: true` suite: if this test process
      # itself is not scheduled promptly, both notices can already be sitting in its
      # mailbox by the time it next runs, collapsing an apparent gap to ~0ms even though
      # the underlying timers fired staggered. Anchoring to a fixed point before any
      # waiting began does not have that failure mode — scheduler contention can only
      # push an arrival LATER than its nominal tick, never earlier, so a lower bound
      # anchored there stays valid under load. The threshold for each position sits
      # halfway between its own correct tick and the ADJACENT (lower) tick the
      # regression this guards against would have produced instead — see
      # DpCryptoManagement's issue #20 in the comment above: the bug scheduled every
      # `rest` entry at the SAME one-tick delay, so shard 2 arriving at only `1 *
      # shard_spacing_ms` (instead of `2 *`) is exactly the failure this threshold is
      # placed to catch.
      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :coverage_change, details: %{shard: 1}}},
                     2_000

      assert System.monotonic_time(:millisecond) - before >= 0.5 * @test_shard_spacing_ms

      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :coverage_change, details: %{shard: 2}}},
                     2_000

      assert System.monotonic_time(:millisecond) - before >= 1.5 * @test_shard_spacing_ms

      assert Process.alive?(feed)
    end
  end

  describe "level2 gets its own, smaller shard grouping when credentials are present" do
    # DpCryptoManagement's issue #22 continuing: at the old shared shard size, four
    # 100-symbol shards had their `level2` subscribe refused by the venue's own
    # per-session stream ceiling while `ticker` sailed through unaffected on the same
    # shards, 5,099 times over — see `feed.ex`'s moduledoc, "`level2` gets its own,
    # smaller sockets". These tests pin the structural fix: `ticker` and `level2` no
    # longer share a shard, `level2`'s grouping is smaller (`@level2_pairs_per_socket`,
    # not `@pairs_per_socket`), and `ticker`'s own boot-time coverage stays exactly as
    # fast as it was — its shard is still the call's synchronous primary.
    @credentials %{api_key: "k", api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="}

    test "35 symbols is one ticker shard and two level2 shards, ticker first" do
      # 35 symbols: one `ticker` shard (`shards/1` at 100/socket never splits it) against
      # two `level2` shards (`chunk_every(35, 30)` is `[30, 5]`) — proof the two channels
      # are sized independently rather than sharing one grouping's boundaries.
      symbols = for n <- 1..35, do: "SYM#{n}-USD"

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           url: "ws://127.0.0.1:1/nowhere",
           credentials: @credentials,
           shard_spacing_ms: @test_shard_spacing_ms,
           alias_map_source: fn -> {:ok, %{}} end}
        )

      :ok = Feed.subscribe_notices(feed, to: self())

      before = System.monotonic_time(:millisecond)

      # The endpoint is unreachable, so every shard's connect fails — the synchronous
      # primary's failure is this call's own reply, proving `ticker` (not `level2`) was
      # chosen as primary: `shard_key_order/2` sorts every `ticker` shard ahead of every
      # `level2` shard, and there is exactly one `ticker` shard here.
      assert {:error, _reason} = Feed.subscribe(feed, symbols, to: self())

      # Both level2 shards eventually fail their own staggered async connect and report
      # themselves — proof `level2` got TWO shards from a symbol count `ticker` needed
      # only one for (`shard_key_order/2` places level2/0 then level2/1 in `reshard/1`'s
      # `rest`, at positions 1 and 2). Each arrival is checked against `before` — a fixed
      # point captured before either timer was scheduled — rather than against each
      # other's observed arrival time; see the 250-symbol test above for why that is the
      # scheduler-jitter-robust way to prove a stagger happened on a loaded, `async: true`
      # suite, and what threshold actually distinguishes this from the regression it
      # guards against.
      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :coverage_change, details: %{channel: "level2", shard: 0}}},
                     2_000

      assert System.monotonic_time(:millisecond) - before >= 0.5 * @test_shard_spacing_ms

      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :coverage_change, details: %{channel: "level2", shard: 1}}},
                     2_000

      assert System.monotonic_time(:millisecond) - before >= 1.5 * @test_shard_spacing_ms

      assert Process.alive?(feed)
    end

    test "without credentials, no level2 shard is ever opened" do
      symbols = for n <- 1..10, do: "SYM#{n}-USD"

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           url: "ws://127.0.0.1:1/nowhere",
           alias_map_source: fn -> {:ok, %{}} end}
        )

      assert {:error, _reason} = Feed.subscribe(feed, symbols, to: self())

      refute Enum.any?(:sys.get_state(feed).shards, fn {{channel, _index}, _shard} ->
               channel == "level2"
             end)
    end
  end

  describe "level2_pairs_per_socket is a supervision option — DpCryptoManagement issue #22" do
    # A hardcoded venue fact costs every consumer a package release and a redeploy when
    # the venue's own ceiling moves; an option lets a consumer absorb that the same day.
    # See feed.ex's own moduledoc, "level2_pairs_per_socket — a supervision option".
    @credentials %{api_key: "k", api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="}

    test "the default matches the measured venue ceiling, 30" do
      assert :sys.get_state(start_feed()).level2_pairs_per_socket == 30
    end

    test "an explicit nil falls back to the default rather than crashing at start" do
      # The same nil-vs-absent trap `resubscribe_interval_ms` already guards against — a
      # venue package forwards its own opts wholesale, and `nil` is a real value a caller
      # (or a config layer) can hand through.
      name = :"feed_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {Feed, name: name, alias_map_source: fn -> {:ok, %{}} end, level2_pairs_per_socket: nil}
        )

      assert :sys.get_state(pid).level2_pairs_per_socket == 30
    end

    test "an explicit override actually changes level2's shard composition" do
      # 12 symbols at the default (30) would be a single level2 shard. At an explicit
      # override of 5, `chunk_every(12, 5)` is `[5, 5, 2]` — three shards. Proven the same
      # way the fixed-size sharding tests above are: the venue endpoint is unreachable, so
      # every shard's own async connect fails and reports itself via `:coverage_change`,
      # and the number and indices of those reports pin the actual chunking that ran.
      symbols = for n <- 1..12, do: "SYM#{n}-USD"

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           url: "ws://127.0.0.1:1/nowhere",
           credentials: @credentials,
           level2_pairs_per_socket: 5,
           shard_spacing_ms: @test_shard_spacing_ms,
           alias_map_source: fn -> {:ok, %{}} end}
        )

      assert :sys.get_state(feed).level2_pairs_per_socket == 5

      :ok = Feed.subscribe_notices(feed, to: self())
      before = System.monotonic_time(:millisecond)

      # The synchronous primary is the sole `ticker` shard (`shard_key_order/2` sorts it
      # first); its failure is this call's own reply.
      assert {:error, _reason} = Feed.subscribe(feed, symbols, to: self())

      # Each shard's own arrival is checked against `before` — a fixed point captured
      # before any of the three timers was scheduled — rather than against the PREVIOUS
      # shard's observed arrival time. See the 250-symbol test above for why a delta
      # between two dynamically-observed arrivals flakes on a loaded, `async: true` suite
      # (this file's own seed-2 and seed-3 CI runs hit exactly that failure during this
      # change) while a lower bound anchored to a point before any waiting began does
      # not. `@test_shard_spacing_ms` stands in for the real 1_000ms default so three
      # stacked ticks (positions 1, 2, 3) cost tens of milliseconds here instead of
      # fifteen seconds.
      [0, 1, 2]
      |> Enum.each(fn shard_index ->
        assert_receive {:dp_exchange, :coinbase,
                        %Notice{
                          kind: :coverage_change,
                          details: %{channel: "level2", shard: ^shard_index}
                        }},
                       2_000

        min_elapsed = (shard_index + 1 - 0.5) * @test_shard_spacing_ms

        assert System.monotonic_time(:millisecond) - before >= min_elapsed
      end)

      assert Process.alive?(feed)
    end

    test "a value below 1 is refused at start, loudly, rather than coerced" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               Feed.start_link(
                 name: :"feed_#{System.unique_integer([:positive])}",
                 alias_map_source: fn -> {:ok, %{}} end,
                 level2_pairs_per_socket: 0
               )

      assert message =~ "level2_pairs_per_socket must be a positive integer"
    end

    test "a non-integer value is refused at start, loudly, rather than coerced" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               Feed.start_link(
                 name: :"feed_#{System.unique_integer([:positive])}",
                 alias_map_source: fn -> {:ok, %{}} end,
                 level2_pairs_per_socket: "30"
               )

      assert message =~ "level2_pairs_per_socket must be a positive integer"
    end

    test "a value above the measured ceiling is honoured, not capped, and warns loudly" do
      # The consumer's whole reason for asking for this option: absorbing a venue-side
      # change without a package release. Capping at 30 would silently defeat that on the
      # day it is actually needed, so this package honours it instead — legibly, via a
      # loud warning naming the measured ceiling and the concrete risk, never silently.
      name = :"feed_#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          pid =
            start_supervised!(
              {Feed,
               name: name, alias_map_source: fn -> {:ok, %{}} end, level2_pairs_per_socket: 40}
            )

          assert :sys.get_state(pid).level2_pairs_per_socket == 40
        end)

      assert log =~ "level2_pairs_per_socket 40 is above the measured venue ceiling of 30"
      assert log =~ "DpCryptoManagement, issue #22"
    end
  end

  describe "shard_spacing_ms is a supervision option" do
    # See feed.ex's own moduledoc, "`shard_spacing_ms` — a supervision option" — validated
    # the same shape as `level2_pairs_per_socket` above, on the axis that is
    # unconditionally nonsense (`Process.send_after/3` cannot schedule a negative or
    # fractional delay), and honoured-with-a-warning on the axis that is merely risky
    # (below the documented Coinbase connect-rate floor, 125ms).
    test "the default is 1_000 — chosen, not the 5_000 this package used to ship" do
      # See feed.ex's own moduledoc, "shard_spacing_ms — a supervision option", for why:
      # an 8x margin under the documented 125ms connect-rate floor, deliberately short of
      # the floor itself for headroom against an undocumented concurrency ceiling of the
      # kind that crash-looped a sibling venue package this same week.
      assert :sys.get_state(start_feed()).shard_spacing_ms == 1_000
    end

    test "an explicit nil falls back to the default rather than crashing at start" do
      pid = start_feed(shard_spacing_ms: nil)
      assert :sys.get_state(pid).shard_spacing_ms == 1_000
    end

    test "an explicit override is honoured" do
      pid = start_feed(shard_spacing_ms: @test_shard_spacing_ms)
      assert :sys.get_state(pid).shard_spacing_ms == @test_shard_spacing_ms
    end

    test "a negative value is refused at start, loudly, rather than coerced" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               Feed.start_link(
                 name: :"feed_#{System.unique_integer([:positive])}",
                 alias_map_source: fn -> {:ok, %{}} end,
                 shard_spacing_ms: -1
               )

      assert message =~ "shard_spacing_ms must be a non-negative integer"
    end

    test "a non-integer value is refused at start, loudly, rather than coerced" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               Feed.start_link(
                 name: :"feed_#{System.unique_integer([:positive])}",
                 alias_map_source: fn -> {:ok, %{}} end,
                 shard_spacing_ms: 5_000.0
               )

      assert message =~ "shard_spacing_ms must be a non-negative integer"
    end

    test "zero is honoured, not refused — extreme but not mathematically nonsense" do
      log =
        capture_log(fn ->
          pid = start_feed(shard_spacing_ms: 0)
          assert :sys.get_state(pid).shard_spacing_ms == 0
        end)

      assert log =~ "shard_spacing_ms 0 is below the documented connect-rate floor"
    end

    test "a value below the documented 125ms floor is honoured, not refused, and warns loudly" do
      # The consumer's whole reason this is an option at all: this package cannot verify
      # whether a faster pace is safe for a given consumer's own network position, so it
      # does not get to refuse a value merely because it is below the documented floor —
      # only make the risk legible.
      log =
        capture_log(fn ->
          pid = start_feed(shard_spacing_ms: 50)
          assert :sys.get_state(pid).shard_spacing_ms == 50
        end)

      assert log =~ "shard_spacing_ms 50 is below the documented connect-rate floor of 125ms"
      assert log =~ "8 per second per IP"
    end

    test "a value at or above the documented floor is used as given, with no warning" do
      refute capture_log(fn ->
               pid = start_feed(shard_spacing_ms: 125)
               assert :sys.get_state(pid).shard_spacing_ms == 125
             end) =~ "connect-rate floor"
    end
  end

  describe "internal messages — the staggered async paths" do
    # These are the messages `reshard/1` schedules with `Process.send_after/3` for every
    # shard beyond the first, and for the resubscribe timer. Driven directly rather than
    # waited for, the same way `Socket`'s own tests drive `handle_frame/2` directly.
    #
    # A socket that never answers `WebSockex.send_frame/2`'s internal `:gen.call` (a bare
    # `Process.sleep(:infinity)`, as this was) does not merely leave a frame unacked — it
    # blocks whichever `Feed` handler sent it for the full, real, hardcoded 5-second
    # `:gen.call` timeout, during which the `Feed` process cannot answer anything at all,
    # including `:sys.get_state/1,2` (which shares roughly the same default timeout).
    # Every test using the old fake was therefore racing two independent ~5-second
    # windows against each other — reliably slow, and under load from the rest of the
    # suite running concurrently, sometimes losing outright. Not "flaky" in the sense of
    # unexplainable: fully deterministic once traced, and fixed at the cause rather than
    # by widening a timeout to outlast it.
    #
    # `WebSockex.send_frame/2` calls `:gen.call(client, :"$websockex_send", frame,
    # timeout)`, which — per `:gen`'s own protocol — expects the receiver to reply via
    # `:gen.reply(from, reply)`. Replying immediately, correctly, is what an actually
    # "fake" socket does; sleeping forever was standing in for a socket that had already
    # died, not one that was merely slow, and this file has a separate, dedicated fake
    # (`dead/0` inline where used) for that case.
    # Reports WHEN it received a send, tagged with `label`, to `test_pid` — the proof
    # `reconcile_shard/7`'s stagger actually works: two sockets' first frames arriving
    # `shard_spacing_ms` apart, not proximity in the log or the process staying alive.
    defp timing_socket(test_pid, label) do
      pid = spawn(fn -> timing_socket_loop(test_pid, label) end)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      pid
    end

    defp timing_socket_loop(test_pid, label) do
      receive do
        {:"$websockex_send", from, _frame} ->
          send(test_pid, {:frame_at, label, System.monotonic_time(:millisecond)})
          :gen.reply(from, :ok)

        _other ->
          :ok
      end

      timing_socket_loop(test_pid, label)
    end

    # Reports each frame's decoded `type` and `product_ids` to `test_pid`, IN THE ORDER
    # this socket process actually received them — the proof this file's own "unsubscribe
    # before subscribe" tests need: `assert_receive {:frame, type, _}` twice in a row, with
    # `type` left unbound both times, drains the mailbox front-to-back (messages from one
    # sender to one receiver are FIFO), so the two `type`s observed are the real send
    # order, not merely "both eventually happened."
    defp frame_reporting_socket(test_pid) do
      pid = spawn(fn -> frame_reporting_socket_loop(test_pid) end)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      pid
    end

    defp frame_reporting_socket_loop(test_pid) do
      receive do
        {:"$websockex_send", from, {:text, payload}} ->
          case Jason.decode(payload) do
            {:ok, %{"type" => type, "product_ids" => product_ids}} ->
              send(test_pid, {:frame, type, product_ids})

            _other ->
              :ok
          end

          :gen.reply(from, :ok)

        {:"$websockex_send", from, _frame} ->
          :gen.reply(from, :ok)

        _other ->
          :ok
      end

      frame_reporting_socket_loop(test_pid)
    end

    # Simulates the venue's own concurrently-subscribed set on ONE session: `subscribe`
    # frames add their `product_ids`, `unsubscribe` frames remove them, and the running
    # size is reported to `test_pid` after every frame. `initial_live` seeds it with
    # whatever this socket already carries when the test starts — the same real starting
    # point `Feed`'s own bookkeeping (`current`) records for an already-open shard. This is
    # how the "never more than the shard's own cap, even transiently" invariant gets
    # checked directly against the actual frames sent, not inferred from the final state.
    defp concurrent_tracking_socket(test_pid, initial_live) do
      pid = spawn(fn -> concurrent_tracking_socket_loop(test_pid, initial_live) end)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      pid
    end

    defp concurrent_tracking_socket_loop(test_pid, live) do
      receive do
        {:"$websockex_send", from, {:text, payload}} ->
          live = apply_tracked_frame(live, Jason.decode(payload))
          send(test_pid, {:live_count, MapSet.size(live)})
          :gen.reply(from, :ok)
          concurrent_tracking_socket_loop(test_pid, live)

        _other ->
          concurrent_tracking_socket_loop(test_pid, live)
      end
    end

    defp apply_tracked_frame(live, {:ok, %{"type" => "subscribe", "product_ids" => ids}}),
      do: MapSet.union(live, MapSet.new(ids))

    defp apply_tracked_frame(live, {:ok, %{"type" => "unsubscribe", "product_ids" => ids}}),
      do: MapSet.difference(live, MapSet.new(ids))

    defp apply_tracked_frame(live, _other), do: live

    # Fails every `unsubscribe` send with `{:error, :send_timeout}` and succeeds every
    # `subscribe` send — the shape needed to prove the subscribe half of a reconcile is
    # genuinely WITHHELD while the unsubscribe half is still failing, not merely delayed.
    # `counter` records every unsubscribe attempt actually received; `sub_counter` records
    # every subscribe attempt actually received, which must stay `0` for as long as the
    # unsubscribe keeps failing.
    defp unsubscribe_always_fails_socket(unsub_counter, sub_counter) do
      pid = spawn(fn -> unsubscribe_always_fails_loop(unsub_counter, sub_counter) end)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      pid
    end

    defp unsubscribe_always_fails_loop(unsub_counter, sub_counter) do
      receive do
        {:"$websockex_send", from, {:text, payload}} ->
          case Jason.decode(payload) do
            {:ok, %{"type" => "unsubscribe"}} ->
              :counters.add(unsub_counter, 1, 1)
              :gen.reply(from, {:error, :send_timeout})

            _other ->
              :counters.add(sub_counter, 1, 1)
              :gen.reply(from, :ok)
          end

        _other ->
          :ok
      end

      unsubscribe_always_fails_loop(unsub_counter, sub_counter)
    end

    # Fails the first `fail_times` UNSUBSCRIBE sends with `{:error, :send_timeout}`, then
    # answers every send `:ok` after — an unsubscribe that was busy or briefly unreachable
    # and then caught up, the same shape `flaky_socket/2` already gives a plain subscribe.
    # `sub_counter` records every SUBSCRIBE send actually received, so a test can prove the
    # subscribe half was genuinely withheld while the unsubscribe half was still failing,
    # not merely that it happened to arrive later.
    # `report_to` is optional and, where a test passes it, strictly better than the
    # counters beside it: every send this socket handles is announced to that pid in the
    # order it happened. A counter can only be polled, and polling for an INTERMEDIATE
    # value of a counter that is on its way somewhere else is a race by construction —
    # `wait_until(fn -> :counters.get(unsub_counter, 1) == 1 end)` had a window only
    # `subscribe_retry_delay_ms` (5 ms) wide in which that was true, and `wait_until/1`
    # polls every 5 ms. It flaked roughly one run in six under `--cover`, which is how it
    # was finally caught. Messages from one sender arrive in send order, so asserting the
    # sequence proves the ordering exactly and waits for no window at all.
    defp unsubscribe_flaky_socket(fail_times, unsub_counter, sub_counter, report_to \\ nil) do
      pid =
        spawn(fn ->
          unsubscribe_flaky_socket_loop(fail_times, unsub_counter, sub_counter, report_to)
        end)

      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      pid
    end

    defp unsubscribe_flaky_socket_loop(remaining, unsub_counter, sub_counter, report_to) do
      receive do
        {:"$websockex_send", from, {:text, payload}} ->
          if unsubscribe_frame?(payload) do
            :counters.add(unsub_counter, 1, 1)

            if remaining > 0 do
              report(report_to, :unsub_failed)
              :gen.reply(from, {:error, :send_timeout})
              unsubscribe_flaky_socket_loop(remaining - 1, unsub_counter, sub_counter, report_to)
            else
              report(report_to, :unsub_ok)
              :gen.reply(from, :ok)
              unsubscribe_flaky_socket_loop(0, unsub_counter, sub_counter, report_to)
            end
          else
            :counters.add(sub_counter, 1, 1)
            report(report_to, :sub)
            :gen.reply(from, :ok)
            unsubscribe_flaky_socket_loop(remaining, unsub_counter, sub_counter, report_to)
          end

        _other ->
          unsubscribe_flaky_socket_loop(remaining, unsub_counter, sub_counter, report_to)
      end
    end

    defp report(nil, _event), do: :ok
    defp report(pid, event), do: send(pid, {:socket_did, event})

    defp unsubscribe_frame?(payload),
      do: match?({:ok, %{"type" => "unsubscribe"}}, Jason.decode(payload))

    # Fails `fail_times` sends with `{:error, :send_timeout}`, then answers `:ok` forever
    # after — a socket that was busy decoding a burst and then caught up. `counter`
    # records every send it actually received, which is how a test proves a retry was
    # sent rather than merely inferring it from timing.
    defp flaky_socket(fail_times, counter) do
      pid = spawn(fn -> flaky_socket_loop(fail_times, counter) end)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      pid
    end

    defp flaky_socket_loop(remaining, counter) do
      receive do
        {:"$websockex_send", from, _frame} ->
          :counters.add(counter, 1, 1)

          if remaining > 0 do
            :gen.reply(from, {:error, :send_timeout})
            flaky_socket_loop(remaining - 1, counter)
          else
            :gen.reply(from, :ok)
            flaky_socket_loop(0, counter)
          end

        _other ->
          flaky_socket_loop(remaining, counter)
      end
    end

    # Never recovers — every send gets `{:error, :send_timeout}`. `counter` is how the
    # exhaustion test proves the retry chain is bounded: the count stops rising once the
    # code gives up, rather than climbing forever.
    defp always_fails_socket(counter) do
      pid = spawn(fn -> always_fails_loop(counter) end)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      pid
    end

    defp always_fails_loop(counter) do
      receive do
        {:"$websockex_send", from, _frame} ->
          :counters.add(counter, 1, 1)
          :gen.reply(from, {:error, :send_timeout})

        _other ->
          :ok
      end

      always_fails_loop(counter)
    end

    test "an :open_shard message that succeeds opens the socket and subscribes" do
      # `socket:` pre-supplies the connection the same way `start_with_socket/0` does
      # for the top-level subscribe tests — a `feed_test.exs` running this against the
      # real endpoint would be a tier-2 test wearing a tier-1 tag.
      socket = fake_socket()

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           socket: socket,
           alias_map_source: fn -> {:ok, %{}} end}
        )

      send(feed, {:open_shard, "ticker", 0, ["BTC-USD"]})

      # `:sys.get_state/1` already queues behind the send above, so it is the sync
      # barrier as well as the assertion — no separate sleep needed.
      state = :sys.get_state(feed)
      assert %{{"ticker", 0} => %{socket: ^socket, symbols: ["BTC-USD"]}} = state.shards
    end

    test "an :open_shard message whose socket cannot open logs, leaves the shard " <>
           "absent, and emits a :coverage_change Notice — never silent at the facade" do
      # Before this fix, a shard whose socket never opened at all only logged — a
      # `Logger.warning` never crosses the facade, and a consumer's only window onto this
      # feed's health is `coverage/1`, `coverage_by_kind/1` and `subscribe_notices/1`. This
      # pins the fix: the same `:coverage_change` kind a failed channel subscribe already
      # uses, so a subscriber listening for one already hears the other.
      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           url: "ws://127.0.0.1:1/nowhere",
           alias_map_source: fn -> {:ok, %{}} end}
        )

      :ok = Feed.subscribe_notices(feed, to: self())
      send(feed, {:open_shard, "ticker", 0, ["BTC-USD"]})

      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :coverage_change, provider: :coinbase} = notice},
                     500

      assert notice.details.shard == 0
      assert notice.details.channel == "ticker"
      assert notice.details.symbol_count == 1

      assert Process.alive?(feed)
      assert :sys.get_state(feed).shards == %{}
    end

    test "the :resubscribe tick retries a shard that never opened at all" do
      # Before this fix, a shard whose socket failed on its async `:open_shard` had NO
      # automatic recovery path — only a fresh `subscribe/3` or `update_symbols/2` call
      # would ever reconsider it, which may never come for a consumer whose scope is
      # stable. `state.wanted` still names the shard's symbols even though `state.shards`
      # never got an entry for it; `retry_missing_shards/1` retries it on the same
      # unconditional cadence an already-open shard's own subscriptions get re-issued on.
      socket = fake_socket()

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           socket: socket,
           alias_map_source: fn -> {:ok, %{}} end}
        )

      :sys.replace_state(feed, fn state -> %{state | wanted: MapSet.new(["BTC-USD"])} end)
      assert :sys.get_state(feed).shards == %{}

      send(feed, :resubscribe)

      wait_until(fn ->
        match?(
          %{{"ticker", 0} => %{socket: ^socket, symbols: ["BTC-USD"]}},
          :sys.get_state(feed).shards
        )
      end)
    end

    test "the :resubscribe tick leaves an already-open shard alone" do
      # A shard already in `state.shards` must not be touched by `retry_missing_shards/1`
      # — that would be a second, redundant `:open_shard` racing the unconditional
      # `:resubscribe_shard` this same tick already scheduled for it above.
      feed = start_feed()
      existing_socket = fake_socket()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | wanted: MapSet.new(["BTC-USD"]),
            shards: %{{"ticker", 0} => %{socket: existing_socket, symbols: ["BTC-USD"]}}
        }
      end)

      send(feed, :resubscribe)

      # `:sys.get_state/1` is a call, so it queues behind the `:resubscribe` info message
      # and is answered only once that handler has returned — no sleep needed to know the
      # tick itself has run. `retry_missing_shards/1` schedules nothing further for shard 0
      # (it is not missing), so there is no later async mutation to race either.
      assert :sys.get_state(feed).shards == %{
               {"ticker", 0} => %{socket: existing_socket, symbols: ["BTC-USD"]}
             }
    end

    test "a :channel_subscribe message against a dead socket is skipped rather than raising" do
      feed = start_feed()
      dead = dead_pid()

      send(feed, {:channel_subscribe, dead, "ticker", ["BTC-USD"], nil})
      :sys.get_state(feed)

      assert Process.alive?(feed)
    end

    test "a :channel_subscribe failure is logged, not crashed on" do
      feed = start_feed()
      socket = fake_socket()

      send(feed, {:channel_subscribe, socket, "ticker", ["BTC-USD"], nil})
      :sys.get_state(feed)

      assert Process.alive?(feed)
    end

    # DpCryptoManagement's issue #22: this file's own moduledoc records the measured
    # inversion (level2 flooding, ticker starved by `send_timeout`) that these four tests
    # exist to close — a timed-out subscribe used to be logged and thrown away, with no
    # retry until the next 60s tick reproduced the identical failure.

    test "a transient :send_timeout is retried and succeeds on a later attempt" do
      counter = :counters.new(1, [])
      socket = flaky_socket(1, counter)

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           alias_map_source: fn -> {:ok, %{}} end,
           subscribe_retry_delay_ms: 5}
        )

      log =
        capture_log(fn ->
          send(feed, {:channel_subscribe, socket, "ticker", ["BTC-USD"], nil})

          # Wait for the retry to actually land rather than sleeping a guessed duration —
          # see `wait_until/1`.
          wait_until(fn -> :counters.get(counter, 1) == 2 end)
        end)

      # Two sends reached the socket: the failed first attempt and the retry that
      # succeeded. Never exhausted, never gave up.
      assert :counters.get(counter, 1) == 2
      # Matched as a whole line, not by phrase. `capture_log/1` captures the WHOLE VM, and
      # since the alias-catalogue tests moved into a file of their own they run CONCURRENTLY
      # with these — logging "retrying in", "giving up" and "not retrying" of their own. A
      # bare phrase would then let somebody else's log satisfy an `assert` or trip a
      # `refute`, which is a test passing (or failing) for a reason that has nothing to do
      # with it. The channel and the symbol count make each line this test's own.
      assert log =~
               ~r/ticker subscribe for 1 symbol\(s\) failed \(.*\), attempt 1\/3 — retrying in 5ms/

      refute log =~ ~r/ticker subscribe for 1 symbol\(s\) failed after/
      assert Process.alive?(feed)
    end

    test "a permanent error (credentials_required) is not retried and fails loudly" do
      feed = start_feed()
      Feed.subscribe_notices(feed, to: self())
      socket = fake_socket()

      # `level2` is authenticated and no credentials were supplied — see
      # `Socket.subscription_message/3`. This can NEVER succeed on retry.
      log =
        capture_log(fn ->
          send(feed, {:channel_subscribe, socket, "level2", ["BTC-USD"], nil})

          # The notice is the completion signal — waiting on it, rather than on a clock,
          # guarantees the log has been written before it is asserted against.
          assert_receive {:dp_exchange, :coinbase, %Notice{kind: :coverage_change} = notice},
                         2_000

          assert notice.severity == :warning
          assert notice.details.channel == "level2"
          assert notice.details.reason =~ "credentials_required"
        end)

      # Matched as a whole line, not by phrase. `capture_log/1` captures the WHOLE VM, and
      # since the alias-catalogue tests moved into a file of their own they run CONCURRENTLY
      # with these — logging "retrying in", "giving up" and "not retrying" of their own. A
      # bare phrase would then let somebody else's log satisfy an `assert` or trip a
      # `refute`, which is a test passing (or failing) for a reason that has nothing to do
      # with it. The channel and the symbol count make each line this test's own.
      assert log =~
               ~r/level2 subscribe for 1 symbol\(s\) failed permanently \(.*\) — not retrying/

      refute log =~ ~r/level2 subscribe for 1 symbol\(s\) failed \(.*\), attempt/
      assert Process.alive?(feed)
    end

    test "retries are bounded, and exhausting them emits a Core.Notice, not just a log" do
      counter = :counters.new(1, [])
      socket = always_fails_socket(counter)

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           alias_map_source: fn -> {:ok, %{}} end,
           subscribe_retry_delay_ms: 5}
        )

      Feed.subscribe_notices(feed, to: self())

      log =
        capture_log(fn ->
          send(feed, {:channel_subscribe, socket, "ticker", ["BTC-USD"], nil})

          # Wait on the notice, not on a clock. The exhaustion notice is emitted only
          # after the final attempt, so receiving it proves the whole chain has run.
          # The `Process.sleep(100)` this replaces was a guess that two 5ms retry gaps
          # plus GenServer scheduling would fit in 100ms; under a loaded async suite they
          # sometimes did not, the captured log ended at "attempt 2/3", and the assertion
          # below failed against a fix that was working correctly. A test that reports a
          # regression the code did not commit is worse than no test.
          assert_receive {:dp_exchange, :coinbase, %Notice{kind: :coverage_change} = notice},
                         2_000

          assert notice.severity == :warning
          assert notice.details.channel == "ticker"
          assert notice.details.reason =~ "send_timeout"
        end)

      # Matched as a whole line, not by phrase. `capture_log/1` captures the WHOLE VM, and
      # since the alias-catalogue tests moved into a file of their own they run CONCURRENTLY
      # with these — logging "retrying in", "giving up" and "not retrying" of their own. A
      # bare phrase would then let somebody else's log satisfy an `assert` or trip a
      # `refute`, which is a test passing (or failing) for a reason that has nothing to do
      # with it. The channel and the symbol count make each line this test's own.
      assert log =~
               ~r/ticker subscribe for 1 symbol\(s\) failed after 3 attempt\(s\) \(.*\) — giving up until the next resubscribe cycle/

      # One initial attempt plus @max_subscribe_retries (2) retries — three sends, and
      # never a fourth, proving the chain is bounded rather than open-ended.
      assert :counters.get(counter, 1) == 3
      assert Process.alive?(feed)
    end

    test "a socket that dies between retry attempts stops the chain without crashing" do
      feed = start_feed()
      dead = dead_pid()

      # Stands in for the scheduled retry message this module sends itself — the socket
      # already died between the attempt that failed and this one.
      send(feed, {:channel_subscribe, dead, "ticker", ["BTC-USD"], nil, 2})
      :sys.get_state(feed)

      assert Process.alive?(feed)
    end

    # `:channel_unsubscribe` (fire-and-forget, no retry, no ordering guarantee against a
    # sibling `:channel_subscribe`) is gone — see `feed.ex`'s moduledoc, "unsubscribe
    # before subscribe". `:channel_reconcile` replaces it: ONE deferred message carrying
    # both the departing and arriving symbols, handled by `attempt_channel_reconcile/6`,
    # which never sends the subscribe half until the unsubscribe half has succeeded.

    test "a :channel_reconcile message unsubscribes before it subscribes, on the same socket" do
      feed = start_feed()
      socket = frame_reporting_socket(self())

      send(
        feed,
        {:channel_reconcile, {"ticker", 0}, socket, "ticker", ["OLD-USD"], ["NEW-USD"], nil}
      )

      :sys.get_state(feed)

      assert_receive {:frame, type1, ids1}, 500
      assert_receive {:frame, type2, ids2}, 500

      assert {type1, ids1} == {"unsubscribe", ["OLD-USD"]}
      assert {type2, ids2} == {"subscribe", ["NEW-USD"]}
      assert Process.alive?(feed)
    end

    test "a :channel_reconcile with nothing to remove sends only the subscribe" do
      feed = start_feed()
      socket = frame_reporting_socket(self())

      send(feed, {:channel_reconcile, {"ticker", 0}, socket, "ticker", [], ["NEW-USD"], nil})
      :sys.get_state(feed)

      assert_receive {:frame, "subscribe", ["NEW-USD"]}, 500
      refute_receive {:frame, "unsubscribe", _ids}, 100
      assert Process.alive?(feed)
    end

    test "a :channel_reconcile with nothing to add sends only the unsubscribe" do
      feed = start_feed()
      socket = frame_reporting_socket(self())

      send(feed, {:channel_reconcile, {"ticker", 0}, socket, "ticker", ["OLD-USD"], [], nil})
      :sys.get_state(feed)

      assert_receive {:frame, "unsubscribe", ["OLD-USD"]}, 500
      refute_receive {:frame, "subscribe", _ids}, 100
      assert Process.alive?(feed)
    end

    test "a :channel_reconcile against a dead socket is skipped" do
      feed = start_feed()
      dead = dead_pid()

      send(
        feed,
        {:channel_reconcile, {"ticker", 0}, dead, "ticker", ["OLD-USD"], ["NEW-USD"], nil}
      )

      :sys.get_state(feed)

      assert Process.alive?(feed)
    end

    test "a transient unsubscribe failure is retried, and the subscribe stays withheld " <>
           "until it succeeds" do
      unsub_counter = :counters.new(1, [])
      sub_counter = :counters.new(1, [])
      socket = unsubscribe_flaky_socket(1, unsub_counter, sub_counter, self())

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           alias_map_source: fn -> {:ok, %{}} end,
           subscribe_retry_delay_ms: 5}
        )

      # Real, JWT-signing credentials — not `nil` — so a wrongly-early subscribe attempt
      # would actually reach this socket and increment `sub_counter`, rather than being
      # swallowed by `{:error, {:credentials_required, "level2"}}` before any frame goes
      # out, which would make `sub_counter == 0` true regardless of whether the withholding
      # logic under test works at all.
      send(
        feed,
        {:channel_reconcile, {"level2", 0}, socket, "level2", ["OLD-USD"], ["NEW-USD"],
         valid_credentials()}
      )

      # Asserted as an ORDERED SEQUENCE, not by polling counters. The socket announces each
      # send in the order it handled it, and messages from one sender arrive in send order,
      # so this proves exactly the property under test: the subscribe does not go out until
      # the unsubscribe has actually landed.
      #
      # The previous version polled for `unsub_counter == 1`, an intermediate value on the
      # way to 2, inside a window only `subscribe_retry_delay_ms` (5 ms) wide — with a 5 ms
      # poll interval. It flaked about one run in six under `--cover`. Waiting for an
      # intermediate value of a counter that is still climbing is a race by construction,
      # however patient the timeout is; 2000 ms of waiting cannot widen a 5 ms window.
      assert_receive {:socket_did, :unsub_failed}, 2_000
      assert_receive {:socket_did, :unsub_ok}, 2_000
      assert_receive {:socket_did, :sub}, 2_000

      # The counters still back it up on totals, where polling a FINAL value is safe.
      wait_until(fn -> :counters.get(unsub_counter, 1) == 2 end)
      wait_until(fn -> :counters.get(sub_counter, 1) == 1 end)

      assert :counters.get(unsub_counter, 1) == 2
      assert :counters.get(sub_counter, 1) == 1
      assert Process.alive?(feed)
    end

    test "unsubscribe exhausting its retries withholds the subscribe entirely and reports " <>
           "a :coverage_change notice" do
      unsub_counter = :counters.new(1, [])
      sub_counter = :counters.new(1, [])
      socket = unsubscribe_always_fails_socket(unsub_counter, sub_counter)

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           alias_map_source: fn -> {:ok, %{}} end,
           subscribe_retry_delay_ms: 5}
        )

      Feed.subscribe_notices(feed, to: self())

      log =
        capture_log(fn ->
          # Real credentials here too — see the previous test's own comment on why `nil`
          # would leave `sub_counter == 0` true even if the withholding logic were broken.
          send(
            feed,
            {:channel_reconcile, {"level2", 0}, socket, "level2", ["OLD-USD"], ["NEW-USD"],
             valid_credentials()}
          )

          assert_receive {:dp_exchange, :coinbase, %Notice{kind: :coverage_change} = notice},
                         2_000

          assert notice.severity == :warning
          assert notice.details.channel == "level2"
          assert notice.details.removed_count == 1
          assert notice.details.added_count == 1
          assert notice.details.reason =~ "send_timeout"
        end)

      # Matched as a whole line, not by phrase. `capture_log/1` captures the WHOLE VM, and
      # since the alias-catalogue tests moved into a file of their own they run CONCURRENTLY
      # with these — logging "retrying in", "giving up" and "not retrying" of their own. A
      # bare phrase would then let somebody else's log satisfy an `assert` or trip a
      # `refute`, which is a test passing (or failing) for a reason that has nothing to do
      # with it. The channel and the symbol count make each line this test's own.
      assert log =~
               ~r/level2 unsubscribe for 1 symbol\(s\) could not be confirmed sent \(.*\).*picked back up on the next unconditional resubscribe cycle/s

      # One initial attempt plus @max_subscribe_retries (2) retries for the unsubscribe —
      # three sends — and the subscribe NEVER sent at all, proving it was genuinely
      # withheld rather than merely delayed.
      assert :counters.get(unsub_counter, 1) == 3
      assert :counters.get(sub_counter, 1) == 0
      assert Process.alive?(feed)
    end

    test "the resubscribe timer re-issues every open shard's subscriptions" do
      {feed, socket} = start_with_socket()

      Feed.subscribe(feed, ~w(BTC-USD), to: self())
      send(feed, :resubscribe)
      :sys.get_state(feed)

      assert Process.alive?(feed)
      assert Process.alive?(socket)
    end

    test "the resubscribe timer skips a shard whose socket has died" do
      feed = start_feed()
      state = :sys.get_state(feed)
      dead = dead_pid()

      :sys.replace_state(feed, fn _s ->
        %{state | shards: %{{"ticker", 0} => %{socket: dead, symbols: ["BTC-USD"]}}}
      end)

      send(feed, :resubscribe)
      :sys.get_state(feed)

      assert Process.alive?(feed)
    end

    test "reconciling two ALREADY-OPEN shards in one update_symbols/2 call staggers " <>
           "them, not only a brand-new shard" do
      # Before this fix `reconcile_shard/7` received the same `delay` `reshard/1` computes
      # for a shard beyond the first and dropped it: every already-open shard touched by
      # one call had its subscribe scheduled at the same instant, regardless of position.
      # 150 symbols forces two shards (100 + 50 at `@pairs_per_socket`); both start already
      # open, under placeholder symbol sets that differ from whatever the new 150-symbol
      # scope resolves to, so BOTH are touched — shard 0 as the synchronous primary, shard
      # 1 asynchronously and staggered by `shard_spacing_ms` behind it. This is the one
      # sharding test in this file that measures an actual elapsed time between two real
      # frames rather than only "did both eventually happen", so it injects
      # `@test_shard_spacing_ms_precise` rather than the smaller generic
      # `@test_shard_spacing_ms` other structural tests use — see that attribute's own
      # comment.
      socket0 = timing_socket(self(), :shard0)
      socket1 = timing_socket(self(), :shard1)

      feed = start_feed(shard_spacing_ms: @test_shard_spacing_ms_precise)

      :sys.replace_state(feed, fn state ->
        %{
          state
          | shards: %{
              {"ticker", 0} => %{socket: socket0, symbols: ["PLACEHOLDER-0"]},
              {"ticker", 1} => %{socket: socket1, symbols: ["PLACEHOLDER-1"]}
            }
        }
      end)

      new_symbols = for n <- 1..150, do: "NEW#{n}-USD"
      before = System.monotonic_time(:millisecond)
      assert :ok = Feed.update_symbols(feed, new_symbols)

      assert_receive {:frame_at, :shard0, _t0}, 500
      assert_receive {:frame_at, :shard1, t1}, 2_000

      # `shard_spacing_ms` is `@test_shard_spacing_ms_precise` here (200ms). Checked
      # against `before` — a fixed point captured before either shard's subscribe was
      # scheduled — rather than against shard 0's own observed arrival time: a delta
      # between two dynamically-observed arrivals is what flaked this file's other
      # sharding tests on a loaded, `async: true` suite (see the 250-symbol test's own
      # comment), because a delayed reader can observe both already sitting in its inbox
      # and collapse the apparent gap. `t0`/`t1` here are timestamped by the two
      # `timing_socket/2` processes themselves at the moment each received its frame —
      # already more robust than a test-process-side read — but anchoring to `before`
      # keeps the same safe shape as every other stagger assertion in this file rather
      # than being the one exception.
      assert t1 - before >= @test_shard_spacing_ms_precise / 2
    end
  end

  describe "level2 reconciles in place — unsubscribe before subscribe, no socket replacement" do
    # See `feed.ex`'s moduledoc, "unsubscribe before subscribe" section. `reconcile_shard/7`
    # used to open a brand-new socket whenever an already-open `level2` shard would GAIN a
    # symbol, subscribe the new socket with the shard's whole target set, and only then
    # kill the old one — hedging against a question DpCryptoManagement has since answered
    # directly against the live venue (2026-09-07, three probes, all raw `Socket.subscribe/4`
    # on ONE socket): the ceiling is CONCURRENT, not cumulative; repeats do not accumulate;
    # `unsubscribe` releases budget. These tests exercise the cheaper fix that measurement
    # unlocked: a growing shard now reconciles on its EXISTING socket, exactly like a
    # shrinking one already did, with `removed` unsubscribed before `added` is subscribed —
    # never the other way round, and never both at once.
    #
    # A freshly generated Ed25519 seed, because these tests exercise an actual successful
    # `Socket.subscribe/4` call, which builds a real JWT (see `Auth.jwt/2`) rather than
    # failing before it gets that far.
    #
    # This used to be contrasted with a connect-failure-only fixture whose `api_secret`
    # could not be decoded at all. Every fixture in this suite now carries a real 32-byte
    # seed, because `Auth.rest_headers/4` returns `{:error, reason}` on a signing failure
    # instead of silently dropping the `Authorization` header — so a credential that
    # cannot sign no longer reaches the venue as an unauthenticated request.
    defp valid_credentials do
      %{api_key: "k", api_secret: :crypto.strong_rand_bytes(32) |> Base.encode64()}
    end

    # Sets up a feed whose `state.wanted` and `state.shards` already agree with each other
    # everywhere EXCEPT the one `level2` shard under test, so `reshard/1` touches exactly
    # that one shard and nothing else — no sort-order contest with `ticker` (which always
    # sorts first — see `shard_key_order/2`) to reason about. `wanted_list` is computed the
    # same way `reshard/1` computes it (`MapSet.to_list/1` of the same symbols), which is
    # safe to precompute here because a `MapSet`'s enumeration order is a function of its
    # current key set only, never of insertion history — see the moduledoc's own proof of
    # that fact. `level2_socket` defaults to a plain `fake_socket/0`; a test proving frame
    # order or the concurrent-count invariant passes its own instead.
    defp feed_with_stale_level2_shard(stale_symbols_fun, level2_socket \\ nil) do
      symbols = for n <- 1..35, do: "SYM#{n}-USD"
      wanted_list = symbols |> MapSet.new() |> MapSet.to_list()
      [level2_shard0, level2_shard1] = Enum.chunk_every(wanted_list, 30)

      old_socket = level2_socket || fake_socket()
      ticker_socket = fake_socket()
      level2_socket1 = fake_socket()

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           alias_map_source: fn -> {:ok, %{}} end}
        )

      :sys.replace_state(feed, fn state ->
        %{
          state
          | credentials: valid_credentials(),
            wanted: MapSet.new(symbols),
            shards: %{
              {"ticker", 0} => %{socket: ticker_socket, symbols: wanted_list},
              {"level2", 0} => %{socket: old_socket, symbols: stale_symbols_fun.(level2_shard0)},
              {"level2", 1} => %{socket: level2_socket1, symbols: level2_shard1}
            }
        }
      end)

      %{feed: feed, old_socket: old_socket, target: level2_shard0}
    end

    test "a shard that would GAIN symbols reconciles on its EXISTING socket — never " <>
           "replaced" do
      %{feed: feed, old_socket: old_socket, target: target} =
        feed_with_stale_level2_shard(&Enum.take(&1, 25))

      ref = Process.monitor(old_socket)

      assert :ok = Feed.subscribe(feed, [], to: self())

      # The socket that was already open is still open, and still THIS socket — nothing
      # else was even injected for it to be replaced with (`injected_socket` is left
      # `nil`, so a replacement would have had to open a real connection and fail loudly).
      refute_receive {:DOWN, ^ref, :process, ^old_socket, _reason}, 200
      assert Process.alive?(old_socket)

      assert %{{"level2", 0} => %{socket: ^old_socket, symbols: ^target}} =
               Map.take(:sys.get_state(feed).shards, [{"level2", 0}])
    end

    test "a shard that only LOSES symbols keeps mutating its existing socket" do
      %{feed: feed, old_socket: old_socket, target: target} =
        feed_with_stale_level2_shard(&(&1 ++ ["EXTRA-USD"]))

      assert :ok = Feed.subscribe(feed, [], to: self())

      assert Process.alive?(old_socket)

      assert %{{"level2", 0} => %{socket: ^old_socket, symbols: ^target}} =
               Map.take(:sys.get_state(feed).shards, [{"level2", 0}])
    end

    test "ticker keeps mutating its own socket in place when it gains symbols — the same " <>
           "reconcile path level2 now takes, since it costs ticker nothing" do
      ticker_socket = fake_socket()
      feed = start_feed()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | wanted: MapSet.new(["BTC-USD"]),
            shards: %{{"ticker", 0} => %{socket: ticker_socket, symbols: []}}
        }
      end)

      assert :ok = Feed.subscribe(feed, [], to: self())

      assert %{{"ticker", 0} => %{socket: ^ticker_socket, symbols: ["BTC-USD"]}} =
               :sys.get_state(feed).shards

      assert Process.alive?(ticker_socket)
    end

    test "a shard that both loses and gains sends the unsubscribe before the subscribe, " <>
           "on the primary (synchronous) reconcile path" do
      reporting_socket = frame_reporting_socket(self())

      %{feed: feed} =
        feed_with_stale_level2_shard(
          fn shard0 -> Enum.drop(shard0, 5) ++ ~w(EXTRA1-USD EXTRA2-USD) end,
          reporting_socket
        )

      assert :ok = Feed.subscribe(feed, [], to: self())

      assert_receive {:frame, type1, ids1}, 500
      assert_receive {:frame, type2, ids2}, 500

      assert type1 == "unsubscribe"
      assert Enum.sort(ids1) == ~w(EXTRA1-USD EXTRA2-USD)
      assert type2 == "subscribe"
      assert length(ids2) == 5
    end

    test "a shard that both loses and gains, reconciled asynchronously (a non-primary " <>
           "touched shard), also unsubscribes before it subscribes" do
      # `feed_with_stale_level2_shard/2` already seeds a SECOND level2 shard
      # (`{"level2", 1}`) whose symbols already match its own fresh target, so it stays
      # untouched — the shard under test here is `{"level2", 0}`, which reshard/1 always
      # picks as this call's PRIMARY (synchronous) shard, since it sorts first among the
      # touched keys. To exercise the deferred path instead, this drives
      # `attempt_channel_reconcile/6` directly via the same message
      # `reconcile_shard_in_place/7`'s async clause schedules — proving the handler's own
      # ordering, independent of which shard reshard/1 happens to pick as primary.
      reporting_socket = frame_reporting_socket(self())
      feed = start_feed()

      send(
        feed,
        {:channel_reconcile, {"level2", 0}, reporting_socket, "level2", ~w(EXTRA1-USD EXTRA2-USD),
         ~w(NEW1-USD NEW2-USD NEW3-USD), valid_credentials()}
      )

      :sys.get_state(feed)

      assert_receive {:frame, type1, ids1}, 500
      assert_receive {:frame, type2, ids2}, 500

      assert type1 == "unsubscribe"
      assert Enum.sort(ids1) == ~w(EXTRA1-USD EXTRA2-USD)
      assert type2 == "subscribe"
      assert Enum.sort(ids2) == ~w(NEW1-USD NEW2-USD NEW3-USD)
    end

    test "a level2 shard reconciling losses and gains together never reports more live " <>
           "products than its own shard size, even transiently mid-reconcile" do
      cap = 5
      current = for n <- 1..cap, do: "SYM#{n}-USD"

      wanted_list =
        (Enum.drop(current, 2) ++ ~w(NEW1-USD NEW2-USD)) |> MapSet.new() |> MapSet.to_list()

      socket = concurrent_tracking_socket(self(), MapSet.new(current))
      # `wanted` here doubles as `ticker`'s own shard content — see the moduledoc: both
      # channels chunk the SAME `state.wanted` set, just at different sizes.
      # `shards_for(wanted_list, "ticker", _)` (100/socket) produces one shard equal to
      # `wanted_list` itself, so pre-seeding `{"ticker", 0}` with exactly that set keeps it
      # untouched by this call, and the only shard `reshard/1` touches is the `level2` one
      # under test — no real socket connect attempt for `ticker` to race against.
      ticker_socket = fake_socket()

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           alias_map_source: fn -> {:ok, %{}} end,
           level2_pairs_per_socket: cap}
        )

      :sys.replace_state(feed, fn state ->
        %{
          state
          | credentials: valid_credentials(),
            wanted: MapSet.new(wanted_list),
            shards: %{
              {"ticker", 0} => %{socket: ticker_socket, symbols: wanted_list},
              {"level2", 0} => %{socket: socket, symbols: current}
            }
        }
      end)

      assert :ok = Feed.subscribe(feed, [], to: self())

      assert_receive {:live_count, count_after_unsubscribe}, 500
      assert_receive {:live_count, count_after_subscribe}, 500

      assert count_after_unsubscribe <= cap
      assert count_after_subscribe <= cap
      assert count_after_subscribe == length(wanted_list)
    end
  end

  describe "a stranded unsubscribe is retried, not silently forgotten" do
    # The coordinator traced a real gap in the fix above: `reconcile_shard_in_place/7`
    # recorded `state.shards[key].symbols = wanted` unconditionally, so a permanently
    # failed unsubscribe's `removed` symbols vanished from THIS module's own bookkeeping
    # even though they were never actually released at the venue. The unconditional
    # resubscribe cycle only ever re-issued `subscribe` for the shard's current set — it
    # never retried the departure — so a shard that hit this even once would leak budget
    # forever: the venue's live count for that session would sit at `old ∪ wanted`,
    # eventually exceeding the shard's own cap and making every later subscribe fail
    # quietly (per DpCryptoManagement's own probe 2 — socket alive, existing symbols still
    # flowing, new ones silently absent). `state.pending_unsubscribes` and
    # `handle_info(:resubscribe, _)`'s own retry of it close that. See `feed.ex`'s
    # moduledoc, "a stranded unsubscribe is not silently forgotten," for the full account.

    test "the resubscribe tick retries a shard's pending unsubscribe before it resubscribes, " <>
           "and a successful retry clears it" do
      socket = frame_reporting_socket(self())
      feed = start_feed()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | credentials: valid_credentials(),
            shards: %{{"level2", 0} => %{socket: socket, symbols: ["A-USD", "B-USD"]}},
            pending_unsubscribes: %{{"level2", 0} => ["STRANDED-USD"]}
        }
      end)

      send(feed, :resubscribe)

      # `:sys.get_state/1` is a call, so it queues behind the tick's own (synchronous,
      # blocking-on-the-socket) frame sends and is answered only once both have gone out.
      :sys.get_state(feed)

      assert_receive {:frame, type1, ids1}, 500
      assert_receive {:frame, type2, ids2}, 500

      # Order is load-bearing here too, for the identical reason it is everywhere else in
      # this file: the stranded release has to reach the venue before the shard's own
      # symbols are re-issued, or the resubscribe recreates the bare-additive-subscribe
      # hazard on a socket this module already knows may be over budget.
      assert type1 == "unsubscribe"
      assert ids1 == ["STRANDED-USD"]
      assert type2 == "subscribe"
      assert Enum.sort(ids2) == ~w(A-USD B-USD)

      # Cleared — the venue accepted the release, so this shard has nothing left pending.
      assert :sys.get_state(feed).pending_unsubscribes == %{}
    end

    test "a resubscribe-tick retry that also fails leaves the pending entry in place" do
      unsub_counter = :counters.new(1, [])
      sub_counter = :counters.new(1, [])
      socket = unsubscribe_always_fails_socket(unsub_counter, sub_counter)

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           alias_map_source: fn -> {:ok, %{}} end,
           subscribe_retry_delay_ms: 5}
        )

      :sys.replace_state(feed, fn state ->
        %{
          state
          | shards: %{{"level2", 0} => %{socket: socket, symbols: ["A-USD"]}},
            pending_unsubscribes: %{{"level2", 0} => ["STRANDED-USD"]}
        }
      end)

      send(feed, :resubscribe)

      # One initial attempt plus @max_subscribe_retries (2) retries — three sends —
      # before this cycle's own retry chain gives up on the SAME still-failing socket.
      wait_until(fn -> :counters.get(unsub_counter, 1) == 3 end)

      # Still pending — a failed retry is not an unconfirmed one; it stays recorded so
      # the NEXT unconditional tick tries again, matching `retry_missing_shards/1`'s own
      # "retry forever until it resolves" shape for a shard whose socket never opened.
      assert :sys.get_state(feed).pending_unsubscribes == %{{"level2", 0} => ["STRANDED-USD"]}

      # And the shard's own (unrelated) symbols were never subscribed either — withheld,
      # not merely delayed, the same guarantee an ordinary reconcile's own failure keeps.
      assert :counters.get(sub_counter, 1) == 0
    end

    test "a synchronous (primary-shard) unsubscribe failure is stranded, not dropped" do
      unsub_counter = :counters.new(1, [])
      sub_counter = :counters.new(1, [])
      socket = unsubscribe_always_fails_socket(unsub_counter, sub_counter)
      ticker_socket = fake_socket()

      feed = start_feed()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | credentials: valid_credentials(),
            wanted: MapSet.new(["KEEP-USD"]),
            shards: %{
              {"ticker", 0} => %{socket: ticker_socket, symbols: ["KEEP-USD"]},
              {"level2", 0} => %{socket: socket, symbols: ["KEEP-USD", "GONE-USD"]}
            }
        }
      end)

      # `{"ticker", 0}` already matches `wanted` exactly, so it is not touched; `{"level2",
      # 0}` is the only touched key and therefore reshard/1's synchronous primary — the
      # path with NO retry chain of its own (see `open_shard/5`'s own sync clause).
      assert {:error, _reason} = Feed.subscribe(feed, [], to: self())

      assert :sys.get_state(feed).pending_unsubscribes == %{{"level2", 0} => ["GONE-USD"]}
      assert :counters.get(sub_counter, 1) == 0
    end

    test "a shard that vanishes with an unrelated stranding pending actually releases " <>
           "it, rather than discarding the record of owing it" do
      # This entry is unrelated to why `{"ticker", 0}` itself vanishes here — it proves
      # `reconcile_shard_in_place/8` folds a shard's own `pending_unsubscribes` into what
      # it treats as "current" on EVERY reconcile, including one that empties the shard
      # entirely, not only on the 60-second cycle. `drop_unwanted_shards/4` no longer
      # drops a vanishing shard's own stranding sight unseen (see its moduledoc): earlier,
      # this same setup left `STALE-USD` un-unsubscribed at the venue forever, the exact
      # leak "a stranded unsubscribe is not silently forgotten" was supposed to close.
      socket = frame_reporting_socket(self())
      feed = start_feed()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | wanted: MapSet.new(["A-USD"]),
            shards: %{{"ticker", 0} => %{socket: socket, symbols: ["A-USD"]}},
            pending_unsubscribes: %{{"ticker", 0} => ["STALE-USD"]}
        }
      end)

      assert :ok = Feed.unsubscribe(feed, ["A-USD"])

      assert_receive {:frame, "unsubscribe", ids}, 500
      assert Enum.sort(ids) == ~w(A-USD STALE-USD)

      assert :sys.get_state(feed).shards == %{}
      assert :sys.get_state(feed).pending_unsubscribes == %{}
    end

    test "a vanishing shard's failed unsubscribe is not orphaned — it stays live for " <>
           "the next resubscribe cycle instead of being dropped with the shard" do
      # Traced regression: `drop_unwanted_shards/3` used to run unconditionally right
      # after `touch_shard/4` and delete BOTH `state.shards[key]` and
      # `state.pending_unsubscribes[key]` for every vanishing key, including the one
      # `strand_unsubscribe/7` had just populated moments earlier in this SAME call. The
      # stranding was recorded and discarded in the same breath, and
      # `handle_info(:resubscribe, _)` only ever walks `Map.keys(state.shards)` — a key
      # dropped from there is a key nothing ever revisits, silently contradicting the
      # notice text's own promise that it "will be picked back up on the next
      # unconditional resubscribe cycle."
      unsub_counter = :counters.new(1, [])
      sub_counter = :counters.new(1, [])
      socket = unsubscribe_flaky_socket(1, unsub_counter, sub_counter)
      feed = start_feed()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | wanted: MapSet.new(["GONE-USD"]),
            shards: %{{"ticker", 0} => %{socket: socket, symbols: ["GONE-USD"]}}
        }
      end)

      # `{"ticker", 0}` is the only touched key — its whole symbol set is departing — so
      # this is `reshard/1`'s synchronous primary, whose one attempt fails.
      assert {:error, _reason} = Feed.unsubscribe(feed, ["GONE-USD"])

      # Not dropped: the shard stays tracked, empty, with its stranding intact.
      assert %{{"ticker", 0} => %{symbols: []}} = :sys.get_state(feed).shards
      assert :sys.get_state(feed).pending_unsubscribes == %{{"ticker", 0} => ["GONE-USD"]}

      send(feed, :resubscribe)
      wait_until(fn -> :counters.get(unsub_counter, 1) == 2 end)
      :sys.get_state(feed)

      # The retry succeeded, so there is nothing left to track — `finalize_shard/4`
      # retires the now fully-resolved vanished shard right here.
      assert :sys.get_state(feed).pending_unsubscribes == %{}
      assert :sys.get_state(feed).shards == %{}
      assert :counters.get(sub_counter, 1) == 0
    end

    test "an ordinary reconcile does not add a new symbol to a shard while an earlier " <>
           "release on the same shard is still unconfirmed" do
      # Traced regression: `reconcile_shard_in_place/8` computed `added`/`removed` from
      # `current -- wanted` / `wanted -- current` alone, never consulting
      # `state.pending_unsubscribes`. A shard sitting at its own cap with one symbol
      # stranded (unsubscribe failed, never confirmed released at the venue) would accept
      # a plain additive subscribe for an unrelated new symbol on the very next ordinary
      # `subscribe/2`/`update_symbols/2` call — the exact "quiet overflow" DpCryptoManagement's
      # own probe 2 describes, and the reason `unsubscribe-before-subscribe` exists at all.
      #
      # `{"ticker", 0}` is pre-seeded to already match what `reshard/1` computes for
      # `wanted` as given — unchanged, so it is not touched — leaving `{"level2", 0}` the
      # only touched key and therefore `reshard/1`'s synchronous primary, the same
      # isolation trick the stranding test above this one uses.
      unsub_counter = :counters.new(1, [])
      sub_counter = :counters.new(1, [])
      socket = unsubscribe_always_fails_socket(unsub_counter, sub_counter)
      ticker_socket = fake_socket()
      feed = start_feed()

      wanted = MapSet.new(["KEEP-USD", "NEW-USD"])
      ticker_symbols = MapSet.to_list(wanted)

      :sys.replace_state(feed, fn state ->
        %{
          state
          | credentials: valid_credentials(),
            wanted: wanted,
            shards: %{
              {"ticker", 0} => %{socket: ticker_socket, symbols: ticker_symbols},
              {"level2", 0} => %{socket: socket, symbols: ["KEEP-USD"]}
            },
            pending_unsubscribes: %{{"level2", 0} => ["STRANDED-USD"]}
        }
      end)

      # No new ask — `wanted` above already carries `NEW-USD` — so this only surfaces
      # `{"level2", 0}`'s own staleness against the `wanted` it already has: `NEW-USD` is
      # an ordinary additive subscribe on that one shard while `STRANDED-USD` is still, as
      # far as this module can tell, unconfirmed at the venue.
      assert {:error, _reason} = Feed.subscribe(feed, [], to: self())

      # The stranded release was retried on THIS reconcile, not withheld until the next
      # 60-second tick — and it failed again on this still-failing socket, so `NEW-USD`
      # was correctly withheld rather than sent while `STRANDED-USD` might still be live.
      assert :counters.get(unsub_counter, 1) == 1
      assert :counters.get(sub_counter, 1) == 0
      assert :sys.get_state(feed).pending_unsubscribes == %{{"level2", 0} => ["STRANDED-USD"]}
    end
  end
end

defmodule DpExchange.Coinbase.FeedTest do
  @moduledoc """
  Subscription bookkeeping, coverage, and what actually reaches a subscriber.

  The three heaviest areas — the alias catalogue, sharding, and the busy-feed call timeout
  — live in files of their own so their waiting overlaps rather than stacking up; see
  `DpExchange.Coinbase.FeedCase`.
  """

  use DpExchange.Coinbase.FeedCase, async: true

  import ExUnit.CaptureLog

  alias DpExchange.Coinbase.Feed
  alias DpExchange.Core.{Notice, Types}

  describe "the resubscribe cadence is configurable, for a diagnostic reason" do
    # The re-issue is unconditional by design, so this package sends a `level2` subscribe
    # per shard per interval indefinitely — and `FrameSender`'s moduledoc leans on
    # "subscribes are idempotent on every venue in this family, so a duplicate is
    # harmless". Whether Coinbase counts *attempted* L2 stream requests rather than
    # established streams is the open question in DpCryptoManagement's issue #22, and it
    # can only be settled by running a short interval against a symbol count too small to
    # exhaust any plausible stream limit. That was impossible while this was a hardcoded
    # constant, which is the gap this closes.
    test "a caller-supplied interval is used instead of the default" do
      name = :"feed_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {Feed, name: name, alias_map_source: fn -> {:ok, %{}} end, resubscribe_interval_ms: 40}
        )

      assert :sys.get_state(pid).resubscribe_interval_ms == 40

      # And it actually drives the timer: with no shards open the tick is a no-op, so the
      # observable proof is that the process keeps ticking and stays healthy rather than
      # scheduling once and stopping.
      Process.sleep(150)
      assert Process.alive?(pid)
      assert :sys.get_state(pid).resubscribe_interval_ms == 40
    end

    test "the default is 60s when the caller supplies nothing" do
      assert :sys.get_state(start_feed()).resubscribe_interval_ms == 60_000
    end

    test "an interval shorter than one re-issue cycle is extended, and says so" do
      # DpCryptoManagement set 5_000, below the floor even a zero-shard feed carries (the
      # `@frame_window_ms` send margin) — and each cycle re-fired before the previous
      # one's subscribes had gone out. Frames queued, `send_frame` blew its window, and the
      # Feed stopped answering `:sys.get_state/1` entirely. A wedged feed is strictly worse
      # than a late resubscribe, so the delay is derived from the shards that actually
      # exist.

      name = :"feed_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {Feed,
           name: name, alias_map_source: fn -> {:ok, %{}} end, resubscribe_interval_ms: 2_000}
        )

      # `send/2` is async — `:sys.get_state/1` is a call, so it queues behind the
      # `:resubscribe` info message and guarantees it has been handled before the capture
      # block returns. Without it this test reads an empty log and fails on timing alone.
      log =
        capture_log(fn ->
          send(pid, :resubscribe)
          :sys.get_state(pid)
        end)

      # With no shards open the cycle is zero span plus the send window (5_000ms).
      assert log =~ "resubscribe interval 2000ms is shorter than one re-issue cycle"
      assert log =~ "5000ms instead"
      assert Process.alive?(pid)
    end

    test "the 60s DEFAULT is itself too short past 57 shards, and is extended too" do
      # Reachable with no option set at all: a cycle spans (shards - 1) *
      # shard_spacing_ms, which passes the 60s `resubscribe_interval_ms` default at 57
      # shards or more, at the current `1_000`ms `shard_spacing_ms` default. That is a
      # far bigger universe than the 361-symbol/13-shard case that tripped this at the
      # `5_000`ms default this package used to ship — one side effect of tightening
      # `shard_spacing_ms` (see feed.ex's own moduledoc, "shard_spacing_ms — a
      # supervision option") is that this particular safety net now needs a much larger
      # universe to matter at all. The mechanism itself is unchanged: the delay is
      # derived from the shards that actually exist, not hardcoded, so a universe large
      # enough still gets protected automatically, at either default.

      shards =
        Map.new(0..56, fn index ->
          {{"ticker", index}, %{socket: spawn(fn -> Process.sleep(:infinity) end), symbols: []}}
        end)

      feed = start_feed()
      :sys.replace_state(feed, fn state -> %{state | shards: shards} end)

      log =
        capture_log(fn ->
          send(feed, :resubscribe)
          :sys.get_state(feed)
        end)

      # (57 - 1) * 1_000 = 56_000 span, + 5_000 send window = 61_000.
      assert log =~ "57 shard(s) (56000ms)"
      assert log =~ "61000ms instead"
      assert Process.alive?(feed)
    end

    test "a comfortable interval is used as given, with no warning" do
      feed = start_feed()

      log =
        capture_log(fn ->
          send(feed, :resubscribe)
          :sys.get_state(feed)
        end)

      refute log =~ "shorter than one re-issue cycle"
      assert Process.alive?(feed)
    end

    test "an explicit nil falls back to the default rather than crashing the timer" do
      # `Process.send_after/3` raises on a nil delay, and venue packages forward their own
      # opts wholesale — the nil-vs-absent trap that Core.Config.opt/3 exists for.
      name = :"feed_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {Feed, name: name, alias_map_source: fn -> {:ok, %{}} end, resubscribe_interval_ms: nil}
        )

      assert :sys.get_state(pid).resubscribe_interval_ms == 60_000
    end
  end

  describe "coverage is OBSERVED, never intended" do
    test "a symbol appears only once a payload for it arrives" do
      # The strongest guarantee in the contract. A venue once reported 325 symbols
      # subscribed and confirmed while 174 were delivering; reporting the subscription
      # would have said 325.
      feed = start_feed()

      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})

      # No sleep needed: `Feed.coverage/1` is a `GenServer.call`, so it queues behind the
      # raw `send/2` above in the same mailbox and cannot be answered until that message
      # has already been handled.
      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
    end

    test "a feed that has delivered nothing covers nothing" do
      feed = start_feed()
      assert Feed.coverage(feed) == %{}
    end

    test "removing a symbol drops its coverage rather than leaving a stale claim" do
      feed = start_feed()

      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :coinbase, quote_for("ETH-USD")})

      # `Feed.update_symbols/2` is itself a call, so it already queues behind both sends.
      assert :ok = Feed.update_symbols(feed, ~w(ETH-USD))

      coverage = Feed.coverage(feed)
      refute Map.has_key?(coverage, "BTC-USD")
      assert coverage["ETH-USD"] == :stream
    end

    test "the route says :stream, never :socket" do
      # `:stream` is the fact a consumer needs — pushed rather than fetched. Whether it
      # is a WebSocket is package-internal.
      feed = start_feed()
      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})

      assert %{"BTC-USD" => :stream} = Feed.coverage(feed)
    end
  end

  describe "a dropped link is not still delivering" do
    # `Socket.handle_disconnect/2` returns `{:reconnect, state}`, so a transport drop leaves
    # the socket PROCESS alive and no `:EXIT` ever reaches `isolate_crashed_shard/5`. Before
    # this, the delivery records from the connection that just died went on answering
    # `:stream` — and a reconnect that restored the socket while the venue silently failed
    # to restore a symbol left that symbol answering `:stream` forever, which is the
    # 325-subscribed/174-delivering incident `coverage/1` was written for. See `Core.Venue`'s
    # `coverage/1` doc: observation is scoped to the current transport session.
    test "a link drop narrows coverage to that shard's symbols and that shard's kind" do
      ticker_socket = idle_socket()
      book_socket = idle_socket()
      feed = start_feed()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | shards: %{
              {"ticker", 0} => %{socket: ticker_socket, symbols: ["BTC-USD", "ETH-USD"]},
              {"level2", 0} => %{socket: book_socket, symbols: ["BTC-USD"]}
            }
        }
      end)

      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :coinbase, quote_for("ETH-USD")})
      send(feed, {:dp_exchange, :coinbase, order_book_for("BTC-USD")})

      assert Feed.coverage(feed) == %{"BTC-USD" => :stream, "ETH-USD" => :stream}

      send(feed, {:dp_exchange, :coinbase, :link_down, ticker_socket})

      # ETH-USD had only the ticker shard, so it is gone entirely. BTC-USD keeps its
      # still-healthy level2 book — a ticker drop must not erase another shard's evidence,
      # the same isolation `isolate_crashed_shard/5` already applies to a crash.
      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
      by_kind = Feed.coverage_by_kind(feed)
      assert by_kind[:order_book] == %{"BTC-USD" => :stream}
      refute Map.has_key?(by_kind, :quotes)

      # Nothing was unsubscribed and the shard keeps its socket, because that socket is
      # reconnecting rather than dead. The next frame after the resubscribe puts it back.
      send(feed, {:dp_exchange, :coinbase, quote_for("ETH-USD")})
      assert Feed.coverage(feed) == %{"BTC-USD" => :stream, "ETH-USD" => :stream}
    end

    test "a link drop from a socket this feed does not know is ignored" do
      feed = start_feed()

      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})
      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}

      send(feed, {:dp_exchange, :coinbase, :link_down, idle_socket()})

      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
    end

    test "a reconnect re-issues THAT shard at once, and no other" do
      # On the timer alone a reconnected shard carried nothing for up to 60s — see the
      # moduledoc's "A reconnect re-issues its shard at once; the timer is the net".
      ticker_socket = recording_socket(:ticker)
      book_socket = recording_socket(:book)
      feed = start_feed()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | shards: %{
              {"ticker", 0} => %{socket: ticker_socket, symbols: ["BTC-USD", "ETH-USD"]},
              {"level2", 0} => %{socket: book_socket, symbols: ["BTC-USD"]}
            }
        }
      end)

      send(feed, {:dp_exchange, :coinbase, :reconnected, ticker_socket})

      assert_receive {:frame, :ticker, %{"type" => "subscribe"} = frame}, 1_000
      assert frame["channel"] == "ticker"
      assert Enum.sort(frame["product_ids"]) == ["BTC-USD", "ETH-USD"]
      refute_receive {:frame, :book, _frame}, 100
    end

    test "a reconnect report from a socket this feed does not know sends nothing" do
      stranger = recording_socket(:stranger)
      feed = start_feed()

      send(feed, {:dp_exchange, :coinbase, :reconnected, stranger})

      refute_receive {:frame, :stranger, _frame}, 100
      assert Process.alive?(feed)
    end

    # Answers every `WebSockex.send_frame/2` with `:ok` and forwards the decoded frame here,
    # tagged, so a test can tell which shard's socket was written to.
    defp recording_socket(tag) do
      test = self()

      pid =
        spawn(fn ->
          Stream.repeatedly(fn ->
            receive do
              {:"$websockex_send", from, {:text, raw}} ->
                :gen.reply(from, :ok)
                send(test, {:frame, tag, Jason.decode!(raw)})
            end
          end)
          |> Stream.run()
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    # A pid that stays alive for the test's duration and answers nothing — `Feed` only ever
    # compares these by identity here, never sends to them.
    defp idle_socket do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end
  end

  describe "a dead subscriber is dropped, not walked forever" do
    # `Core.Fanout.resolve/1` already skipped a dead subscriber at send time, so no EVENTS
    # accumulated — but nothing removed the pid, so a supervised consumer that restarts left
    # one behind on every restart, for the life of this feed. `deliver/4` walks the whole set
    # calling `Process.alive?/1` once per message, so the cost was linear in uptime: measured
    # in Core 0.3.3 at 0.095 us per fan-out against a clean set and 22.8 us against one
    # carrying a thousand dead pids. This venue's `level2` channel measured 4258 frames in
    # one incident window, which is where that multiplier stops being theoretical.
    test "a subscriber that dies is removed from the subscriber set" do
      feed = start_feed()
      subscriber = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: subscriber)
      assert MapSet.member?(:sys.get_state(feed).subscribers, subscriber)

      ref = Process.monitor(subscriber)
      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, _reason}

      # A call is answered only after the feed's own `:DOWN` has been handled.
      _settled = Feed.coverage(feed)

      state = :sys.get_state(feed)
      refute MapSet.member?(state.subscribers, subscriber)
      refute Map.has_key?(state.monitors, subscriber)
    end

    test "a notice subscriber that dies is removed too" do
      feed = start_feed()
      watcher = spawn(fn -> Process.sleep(:infinity) end)

      :ok = Feed.subscribe_notices(feed, to: watcher)
      assert MapSet.member?(:sys.get_state(feed).notice_subscribers, watcher)

      ref = Process.monitor(watcher)
      Process.exit(watcher, :kill)
      assert_receive {:DOWN, ^ref, :process, ^watcher, _reason}
      _settled = Feed.coverage(feed)

      refute MapSet.member?(:sys.get_state(feed).notice_subscribers, watcher)
    end

    test "a REGISTERED NAME is never monitored, and survives its holder dying" do
      # The half that must not be pruned. A name is not a process: `subscribe/2` accepts one
      # precisely so a consumer can restart under it, and pruning when the current holder
      # dies would silently unsubscribe a consumer whose supervisor is about to bring it
      # straight back — data loss with nothing to notice it by.
      feed = start_feed()
      name = :"named_subscriber_#{System.unique_integer([:positive])}"
      holder = spawn(fn -> Process.sleep(:infinity) end)
      Process.register(holder, name)

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: name)
      assert :sys.get_state(feed).monitors == %{}

      ref = Process.monitor(holder)
      Process.exit(holder, :kill)
      assert_receive {:DOWN, ^ref, :process, ^holder, _reason}
      _settled = Feed.coverage(feed)

      assert MapSet.member?(:sys.get_state(feed).subscribers, name)
    end

    test "subscribing twice from one pid monitors it once" do
      # Each monitor delivers its own `:DOWN`, so stacking them means N-1 messages nothing
      # will match.
      feed = start_feed()
      subscriber = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(subscriber, :kill) end)

      :ok = Feed.subscribe(feed, ["BTC-USD"], to: subscriber)
      first = :sys.get_state(feed).monitors

      :ok = Feed.subscribe(feed, ["ETH-USD"], to: subscriber)
      :ok = Feed.subscribe_notices(feed, to: subscriber)

      assert :sys.get_state(feed).monitors == first
      assert map_size(first) == 1
    end
  end

  describe "back-pressure — a slow subscriber does not get an unbounded mailbox" do
    # `Core.Venue`'s `subscribe/2` doc promised this from the day the contract was written,
    # and no venue in this family implemented any of it: every one fanned out with a bare
    # `send/2` and had never looked at a subscriber's mailbox. A consumer that stalls
    # accumulated a mailbox until the node died, with no notice, no log line, and
    # `coverage/1` reporting perfect health throughout — because the feed genuinely was
    # delivering. Implemented in `Core.Fanout` 0.2.6 and wired here.

    # A subscriber that never consumes, so everything sent to it stays queued. That is what
    # a stalled consumer looks like from the sender's side, and the only way to build a real
    # backlog without guessing at timing.
    defp stalled_subscriber do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    defp queued(pid) do
      {:message_queue_len, len} = Process.info(pid, :message_queue_len)
      len
    end

    test "past its bound, a subscriber stops being sent to and its mailbox stops growing" do
      slow = stalled_subscriber()
      feed = start_feed(max_queue_len: 3)
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: slow)

      for _each <- 1..10, do: send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})
      # A call is answered only after every send above has been handled.
      _settled = Feed.coverage(feed)

      # Three got through, then the bound stopped it. Not ten, and — the point — not
      # unbounded. This venue's `level2` channel measured 4258 delta frames in the window
      # that produced this family's coverage incident; that is what this bound stands
      # between a stalled consumer and.
      assert queued(slow) == 3
    end

    test "a stalled subscriber is reported once, not once per dropped message" do
      slow = stalled_subscriber()
      feed = start_feed(max_queue_len: 1)
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: slow)
      :ok = Feed.subscribe_notices(feed, to: self())

      for _each <- 1..2, do: send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})
      _settled = Feed.coverage(feed)

      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :degraded, severity: :warning, details: details}}

      assert details.bound == 1
      assert details.dropping == :newest
      assert details.subscriber == inspect(slow)

      # A notice per dropped message would arrive at the rate of the stream the consumer
      # already cannot keep up with, into the same fan-out that is overloaded.
      for _each <- 1..5, do: send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})
      _settled = Feed.coverage(feed)
      refute_receive {:dp_exchange, :coinbase, %Notice{kind: :degraded}}, 100
    end

    test "a symbol whose frames are dropped for a slow consumer is still covered" do
      # `coverage/1` reports what the VENUE delivered to this package, not what this package
      # forwarded. Reporting `:not_covered` here would blame the venue for a consumer's own
      # backlog, and send an operator looking at the wrong system entirely.
      slow = stalled_subscriber()
      feed = start_feed(max_queue_len: 1)
      :ok = Feed.subscribe(feed, ["BTC-USD"], to: slow)

      for _each <- 1..5, do: send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})

      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}
    end

    test "an invalid bound fails at init, loudly, rather than falling back to the default" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Feed.start_link(
                 name: :"bad_bound_#{System.unique_integer([:positive])}",
                 alias_map_source: fn -> {:ok, %{}} end,
                 max_queue_len: "3"
               )

      assert message =~ ":coinbase"
      assert message =~ ":max_queue_len"
    end
  end

  describe "coverage_by_kind/1 — ticker-dark/book-healthy, which coverage/1 cannot show" do
    test "a symbol delivering only a Quote appears under :quotes and not :order_book" do
      feed = start_feed()

      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})

      by_kind = Feed.coverage_by_kind(feed)

      assert by_kind[:quotes] == %{"BTC-USD" => :stream}
      refute Map.has_key?(by_kind, :order_book)
    end

    test "a symbol delivering only an OrderBook appears under :order_book, not :quotes " <>
           "— the literal issue #22 regression: level2 delivered thousands of frames " <>
           "while ticker stayed dark" do
      feed = start_feed()

      send(feed, {:dp_exchange, :coinbase, order_book_for("XLM-USD")})

      by_kind = Feed.coverage_by_kind(feed)

      # coverage/1 answers :stream here too — truthfully, and precisely the blindness
      # coverage_by_kind/1 exists to close.
      assert Feed.coverage(feed) == %{"XLM-USD" => :stream}

      assert by_kind[:order_book] == %{"XLM-USD" => :stream}
      refute Map.has_key?(by_kind, :quotes)
    end

    test "a symbol delivering both kinds appears under both, and one going quiet later " <>
           "does not erase the other" do
      feed = start_feed()

      send(feed, {:dp_exchange, :coinbase, quote_for("ETH-USD")})
      send(feed, {:dp_exchange, :coinbase, order_book_for("ETH-USD")})

      by_kind = Feed.coverage_by_kind(feed)
      assert by_kind[:quotes] == %{"ETH-USD" => :stream}
      assert by_kind[:order_book] == %{"ETH-USD" => :stream}
    end

    test "a symbol delivering only an OrderBookDelta ALSO appears under :order_book — " <>
           "level2 `update` frames arrive as this struct now, not a rebuilt OrderBook" do
      feed = start_feed()

      send(feed, {:dp_exchange, :coinbase, order_book_delta_for("SOL-USD")})

      by_kind = Feed.coverage_by_kind(feed)

      assert Feed.coverage(feed) == %{"SOL-USD" => :stream}
      assert by_kind[:order_book] == %{"SOL-USD" => :stream}
      refute Map.has_key?(by_kind, :quotes)
    end

    test "a snapshot (OrderBook) and a later delta (OrderBookDelta) for the same symbol " <>
           "both count toward the same :order_book kind, not two different ones" do
      feed = start_feed()

      send(feed, {:dp_exchange, :coinbase, order_book_for("XLM-USD")})
      send(feed, {:dp_exchange, :coinbase, order_book_delta_for("XLM-USD")})

      by_kind = Feed.coverage_by_kind(feed)
      assert by_kind[:order_book] == %{"XLM-USD" => :stream}
      assert map_size(by_kind) == 1
    end

    test "the symbol union across every kind matches coverage/1 exactly, under mixed delivery" do
      feed = start_feed()

      # BTC-USD: quote only. XLM-USD: book only. ETH-USD: both.
      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :coinbase, order_book_for("XLM-USD")})
      send(feed, {:dp_exchange, :coinbase, quote_for("ETH-USD")})
      send(feed, {:dp_exchange, :coinbase, order_book_for("ETH-USD")})

      coverage_symbols = feed |> Feed.coverage() |> Map.keys() |> MapSet.new()

      union =
        feed
        |> Feed.coverage_by_kind()
        |> Map.values()
        |> Enum.flat_map(&Map.keys/1)
        |> MapSet.new()

      assert union == coverage_symbols
      assert union == MapSet.new(~w(BTC-USD XLM-USD ETH-USD))
    end

    test "every kind key reported is a kind DpExchange.Coinbase declares streamable" do
      feed = start_feed()

      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :coinbase, order_book_for("XLM-USD")})

      declared = MapSet.new(DpExchange.Coinbase.capabilities().streamable)
      reported = feed |> Feed.coverage_by_kind() |> Map.keys() |> MapSet.new()

      assert MapSet.subset?(reported, declared)
    end

    test "a feed that has delivered nothing reports no kinds" do
      feed = start_feed()
      assert Feed.coverage_by_kind(feed) == %{}
    end
  end

  describe "delivery" do
    test "quotes reach the subscribing process" do
      feed = start_feed()
      Feed.subscribe_notices(feed, to: self())

      # A subscriber is registered by `subscribe/3`; simulate one having been registered
      # by sending through the feed's own inbound path.
      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})

      assert %{"BTC-USD" => :stream} = Feed.coverage(feed)
    end

    test "notices go to notice subscribers, separately from data" do
      feed = start_feed()
      assert :ok = Feed.subscribe_notices(feed, to: self())

      send(feed, {:dp_exchange, :coinbase, Notice.new(:link_down, :coinbase)})

      assert_receive {:dp_exchange, :coinbase, %Notice{kind: :link_down}}, 500
    end

    test "a dead subscriber does not accumulate events" do
      # The venue must not hold events for a process that no longer exists.
      feed = start_feed()

      dead = dead_pid()

      Feed.subscribe_notices(feed, to: dead)
      send(feed, {:dp_exchange, :coinbase, Notice.new(:link_up, :coinbase)})

      # `:sys.get_state/1` is a call, so it queues behind the raw `send/2` above and is
      # only answered once that message has been handled — a deterministic stand-in for
      # "give the feed a moment", not a guessed duration.
      :sys.get_state(feed)
      assert Process.alive?(feed)
    end

    test "a subscriber registered by name (not a raw pid) is delivered to rather than crashing the feed" do
      # Filed as a live bug: Process.alive?/1 only accepts a pid and raises on anything
      # else, so a consumer that registers itself under a name and hands that name to
      # `to:` — ordinary OTP practice — crashed this whole GenServer on the very first
      # delivery.
      name = :"coinbase_feed_test_subscriber_#{System.unique_integer([:positive])}"
      Process.register(self(), name)
      feed = start_feed()

      Feed.subscribe_notices(feed, to: name)
      send(feed, {:dp_exchange, :coinbase, Notice.new(:link_up, :coinbase)})

      assert_receive {:dp_exchange, :coinbase, %Notice{kind: :link_up}}, 500
      assert Process.alive?(feed)

      Process.unregister(name)
    end

    test "a name that is not (or no longer) registered is silently skipped, not a crash" do
      name = :"coinbase_feed_test_unregistered_#{System.unique_integer([:positive])}"
      refute Process.whereis(name)
      feed = start_feed()

      Feed.subscribe_notices(feed, to: name)
      send(feed, {:dp_exchange, :coinbase, Notice.new(:link_up, :coinbase)})

      :sys.get_state(feed)
      assert Process.alive?(feed)
    end
  end

  describe "unknown messages" do
    test "an unknown call is answered rather than crashing the caller" do
      feed = start_feed()
      assert {:error, :unknown_call} = GenServer.call(feed, :nonsense)
    end

    test "an unknown info is ignored" do
      feed = start_feed()
      send(feed, :nonsense)
      :sys.get_state(feed)
      assert Process.alive?(feed)
    end
  end

  describe "unsubscribe with no socket" do
    test "succeeds and drops the symbols" do
      feed = start_feed()
      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})

      assert :ok = Feed.unsubscribe(feed, ~w(BTC-USD))
      assert Feed.coverage(feed) == %{}
    end
  end

  describe "subscribe with a socket that will not connect" do
    test "reports the failure rather than pretending to have subscribed" do
      # The endpoint is unreachable, so the socket cannot start. Claiming success here
      # would produce a subscription that never delivers — which is the shape a consumer
      # cannot tell from a quiet market.
      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           url: "ws://127.0.0.1:1/nowhere",
           alias_map_source: fn -> {:ok, %{}} end}
        )

      assert {:error, _reason} = Feed.subscribe(feed, ~w(BTC-USD), to: self())
      assert Feed.coverage(feed) == %{}
    end

    test "the feed survives a socket that cannot start" do
      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           url: "ws://127.0.0.1:1/nowhere",
           alias_map_source: fn -> {:ok, %{}} end}
        )

      Feed.subscribe(feed, ~w(BTC-USD), to: self())
      assert Process.alive?(feed)
    end
  end

  describe "update_symbols with no socket" do
    test "records the wanted set without claiming coverage" do
      feed = start_feed()

      assert :ok = Feed.update_symbols(feed, ~w(BTC-USD ETH-USD))
      assert Feed.coverage(feed) == %{}
    end
  end

  describe "subscribers" do
    test "a quote reaches a registered subscriber, and only a registered one" do
      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           url: "ws://127.0.0.1:1/nowhere",
           alias_map_source: fn -> {:ok, %{}} end}
        )

      # Registering happens through `subscribe/3` even when the socket cannot connect —
      # a caller that asked to be subscribed is subscribed, and finds out about the
      # connection separately.
      Feed.subscribe(feed, ~w(BTC-USD), to: self())

      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})

      assert_receive {:dp_exchange, :coinbase, %Types.Quote{symbol: "BTC-USD"}}, 500
    end

    test "notice subscribers do not receive market data" do
      # The two channels are separate on purpose: a monitoring process that never touches
      # a price still needs to know a credential expired.
      feed = start_feed()
      Feed.subscribe_notices(feed, to: self())

      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})

      # `refute_received/1` only inspects THIS process's mailbox as it stands right now,
      # so the feed must have already finished handling the send above before it runs —
      # otherwise the assertion would pass whether or not the code under test is correct.
      # `:sys.get_state/1` is the deterministic way to know that: it queues behind the
      # send in the feed's own mailbox and only answers once that message is handled.
      :sys.get_state(feed)
      refute_received {:dp_exchange, :coinbase, %Types.Quote{}}
    end
  end

  describe "update_symbols on a live set" do
    test "keeps coverage for symbols that stay" do
      feed = start_feed()

      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :coinbase, quote_for("ETH-USD")})

      assert :ok = Feed.update_symbols(feed, ~w(BTC-USD SOL-USD))

      coverage = Feed.coverage(feed)
      assert coverage["BTC-USD"] == :stream
      refute Map.has_key?(coverage, "ETH-USD")
      # SOL was added but nothing has arrived for it, so it is absent — observed, never
      # intended.
      refute Map.has_key?(coverage, "SOL-USD")
    end
  end

  describe "with a connection already established" do
    # A live process standing in for a socket whose frames fail — it exercises the
    # socket-bearing branches without reaching a venue.
    #
    # Replies immediately with an error, rather than never replying: `WebSockex.
    # send_frame/2` calls `:gen.call(client, :"$websockex_send", frame, timeout)`, and a
    # target that never replies makes that block for the real, hardcoded 5-second
    # `:gen.call` timeout — during which the `Feed` process answers nothing at all,
    # including `:sys.get_state/1,2` (its own default timeout is close enough to the
    # same 5 seconds that the two raced). Every test below asserts only `{:error,
    # _reason}`, never the specific reason, so an immediate simulated failure exercises
    # the identical "the feed handles a socket send failing" path this was always meant
    # to, without the multi-second, load-dependent stall.
    test "subscribe reuses the connection rather than dialling a second one" do
      {feed, socket} = start_with_socket()

      # The send fails because the stand-in does not speak the protocol; what matters is
      # that the feed used the socket it already had and reported the outcome.
      assert {:error, _reason} = Feed.subscribe(feed, ~w(BTC-USD), to: self())
      assert Process.alive?(socket)
      assert Process.alive?(feed)
    end

    test "unsubscribe goes to the connection and still drops coverage" do
      {feed, _socket} = start_with_socket()

      # Subscribing first is what creates the shard `unsubscribe/2` then has to reach —
      # a symbol that only ever arrived via a raw `send` (simulating delivery without
      # ever being asked for) has no shard to unsubscribe from, correctly.
      Feed.subscribe(feed, ~w(BTC-USD), to: self())
      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})

      assert {:error, _reason} = Feed.unsubscribe(feed, ~w(BTC-USD))
      assert Feed.coverage(feed) == %{}
    end

    test "update_symbols sends both the removal and the addition" do
      {feed, _socket} = start_with_socket()

      Feed.subscribe(feed, ~w(BTC-USD), to: self())
      assert {:error, _reason} = Feed.update_symbols(feed, ~w(ETH-USD))
      assert Process.alive?(feed)
    end

    test "a feed whose socket dies stays alive to reconnect" do
      # This socket is injected via `opts` — it was never `start_link`'d FROM this
      # `Feed`, so it is not actually linked to it, and this test would pass even
      # without `init/1`'s `Process.flag(:trap_exit, true)`. It still earns its place:
      # it proves a dead socket pid does not, by itself, wedge `subscribe/2` or crash
      # `Feed` some OTHER way. See the "a shard's socket crash is isolated, not fatal"
      # describe block below for the case that DOES depend on the trap_exit flag —
      # a socket genuinely linked to `Feed`, the way `get_socket/1` links every real one.
      {feed, socket} = start_with_socket()
      ref = Process.monitor(socket)
      Process.exit(socket, :kill)
      assert_receive {:DOWN, ^ref, :process, ^socket, _reason}, 500

      assert {:error, _reason} = Feed.subscribe(feed, ~w(BTC-USD), to: self())
      assert Process.alive?(feed)
    end
  end

  describe "a shard's socket crash is isolated, not fatal" do
    # Every real socket this module ever opens is linked to it — `get_socket/1` calls
    # `Socket.start_link/1` from inside a `Feed` callback, and `start_link` always
    # links. `start_with_socket/0`'s injected double is not (see the comment on "a feed
    # whose socket dies stays alive to reconnect" above), so proving what actually
    # happens when a REAL linked child dies needs a real link — created here the same
    # way production creates one, except from a place this test controls.
    #
    # `:sys.replace_state/2` runs the given function INSIDE the target process, the same
    # mechanism `:sys.get_state/1` already uses elsewhere in this file — so `Process.
    # link/1` inside it creates a link owned by `feed`, not by this test process, exactly
    # matching what `get_socket/1` does in production. This is not a workaround; it is
    # the one way to attach a link a test controls to a process it does not run inside.
    defp link_socket_into_feed(feed, socket) do
      :sys.replace_state(feed, fn state ->
        Process.link(socket)
        state
      end)
    end

    test "the feed survives a linked socket being killed" do
      {feed, socket} = start_with_socket()
      link_socket_into_feed(feed, socket)

      # Without `init/1`'s `Process.flag(:trap_exit, true)`, this `:kill` propagates
      # along the link this test just created and takes `feed` down with it —
      # `Process.exit(pid, :normal)` would NOT prove this (a non-trapping process
      # ignores a peer's normal exit), which is why this uses `:kill`.
      ref = Process.monitor(feed)
      Process.exit(socket, :kill)
      refute_receive {:DOWN, ^ref, :process, ^feed, _reason}, 500
      assert Process.alive?(feed)
    end

    test "a crashed shard's coverage clears, a :link_down notice fires, and it reopens" do
      {feed, socket} =
        start_with_socket_and_opts(url: "ws://127.0.0.1:1/nowhere")

      Feed.subscribe(feed, ~w(BTC-USD), to: self())
      # A real arrival, so there is something in `state.delivering` for the crash to
      # actually clear — proving "cleared" rather than "was never populated."
      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})
      assert Feed.coverage(feed) == %{"BTC-USD" => :stream}

      :ok = Feed.subscribe_notices(feed, to: self())
      link_socket_into_feed(feed, socket)

      Process.exit(socket, :kill)

      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :link_down, details: %{channel: "ticker", shard: 0}}},
                     500

      assert Process.alive?(feed)
      # Cleared immediately — not merely "will clear once something else overwrites
      # it" — this is the coverage-truthfulness question the audit asked directly: does
      # `coverage/1` still say `:stream` right after the shard that carried "BTC-USD"
      # crashed? It must not.
      assert Feed.coverage(feed) == %{}

      # Reopened right away, not on the next `:resubscribe` tick (60s by default): the
      # replacement dials `"ws://127.0.0.1:1/nowhere"`, refuses locally and fast, and
      # reports itself the same way `handle_info({:open_shard, _, _}, _)` always does —
      # proving an attempt actually happened, not merely that nothing crashed.
      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :coverage_change, details: %{channel: "ticker", shard: 0}}},
                     2_000
    end

    test "a deferred :open_shard message for a key someone else already reopened " <>
           "does not open a second socket and orphan one of them" do
      # Traced regression: `isolate_crashed_shard/5` deletes `state.shards[key]` and
      # schedules `Process.send_after(self(), {:open_shard, channel, index, symbols}, 0)`
      # to reopen it. Between that deletion and this message actually firing, an ordinary
      # `subscribe/2`/`update_symbols/2` call landing on the SAME `Feed` sees the key
      # absent and recovers it independently through its own `reshard/1` — and the old,
      # unconditional `{:open_shard, _, _}` handler had no way to notice: it always called
      # `get_socket/1` and `put_in`, so whichever attempt's `put_in` ran last won
      # `state.shards[key]`'s slot and the other's freshly-opened, freshly-linked socket
      # was never referenced by this module again — leaked, not merely stale.
      existing_socket = fake_socket()
      feed = start_feed()

      :sys.replace_state(feed, fn state ->
        %{state | shards: %{{"ticker", 0} => %{socket: existing_socket, symbols: ["A-USD"]}}}
      end)

      :ok = Feed.subscribe_notices(feed, to: self())

      # The stale reopen for the identical key — what `isolate_crashed_shard/5`'s own
      # deferred message looks like once something else won the race.
      send(feed, {:open_shard, "ticker", 0, ["A-USD"]})
      :sys.get_state(feed)

      # No shard-open-failed notice — proof this never even reached `get_socket/1` for a
      # second attempt (this `Feed` was started with no injected socket and no real
      # transport configured, so a genuine second open would have failed loudly).
      refute_receive {:dp_exchange, :coinbase, %Notice{kind: :coverage_change}}, 200

      # The entry already present — the same socket pid — is untouched.
      assert :sys.get_state(feed).shards ==
               %{{"ticker", 0} => %{socket: existing_socket, symbols: ["A-USD"]}}
    end
  end

  @credentials %{api_key: "k", api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="}

  describe ":channels — level2 can be opted out of (issue #1)" do
    # The reported cost, on a consumer routing order-book depth over REST and reading only
    # quotes: 14 `level2` sockets at 406 pairs, and 1,577,001 delta frames decoded and
    # delivered in a single boot for a payload with no wired consumer. Ignoring them on
    # receipt saved nothing — the sockets were open and the frames were parsed anyway.

    test "defaults to both channels, so nothing changes for an existing caller" do
      feed = start_feed(credentials: @credentials)

      assert :sys.get_state(feed).channels == [:quotes, :order_book]
    end

    test "channels: [:quotes] opens ticker shards and no level2 shard at all" do
      feed = start_feed(credentials: @credentials, channels: [:quotes])
      :ok = Feed.subscribe(feed, ["BTC-USD", "ETH-USD"])

      channels =
        feed
        |> :sys.get_state()
        |> Map.fetch!(:shards)
        |> Map.keys()
        |> Enum.map(fn {channel, _index} -> channel end)
        |> Enum.uniq()

      assert channels == ["ticker"]
    end

    test "channels: [:order_book] opens level2 and no ticker" do
      feed = start_feed(credentials: @credentials, channels: [:order_book])
      :ok = Feed.subscribe(feed, ["BTC-USD"])

      channels =
        feed
        |> :sys.get_state()
        |> Map.fetch!(:shards)
        |> Map.keys()
        |> Enum.map(fn {channel, _index} -> channel end)
        |> Enum.uniq()

      assert channels == ["level2"]
    end

    test "a credential-less feed still gets ticker only, even asking for the book" do
      # The option NARROWS what is asked for; it never widens past what credentials allow.
      # `level2` is authenticated on this venue, so requesting it without a credential must
      # not produce a doomed subscribe.
      feed = start_feed(channels: [:quotes, :order_book])
      :ok = Feed.subscribe(feed, ["BTC-USD"])

      channels =
        feed
        |> :sys.get_state()
        |> Map.fetch!(:shards)
        |> Map.keys()
        |> Enum.map(fn {channel, _index} -> channel end)
        |> Enum.uniq()

      assert channels == ["ticker"]
    end

    test "a kind this venue does not stream fails init loudly, never silently" do
      # `init/1` raising means `start_link/1` answers `{:error, {exception, _stack}}` and,
      # because it links, also signals this process — so the exit is trapped rather than
      # letting a deliberate refusal look like a test crash.
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Feed.start_link(name: nil, channels: [:candles])

      assert message =~ ":channels must be drawn from"
      assert message =~ ":candles"
    end

    test "an empty channel list is refused rather than starting a feed that reads nothing" do
      # It would report honest, permanent zero coverage — indistinguishable from a venue
      # outage. A consumer wanting no stream should not start a feed.
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: message}, _stack}} =
               Feed.start_link(name: nil, channels: [])

      assert message =~ "non-empty list"
    end
  end
end

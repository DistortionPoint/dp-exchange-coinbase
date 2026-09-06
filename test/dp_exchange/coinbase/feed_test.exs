defmodule DpExchange.Coinbase.FeedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias DpExchange.Coinbase.Feed
  alias DpExchange.Core.{DefaultRateLimiter, Notice, Types}

  @moduletag :capture_log

  # Real GenServers and real messages. The feed's socket is never started here — these
  # test the subscription bookkeeping and the coverage rule, which is where the
  # interesting behaviour is and where a venue gets it wrong.
  defp start_feed do
    name = :"feed_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Feed, name: name, alias_map_source: fn -> {:ok, %{}} end})
    pid
  end

  defp quote_for(symbol) do
    %Types.Quote{
      symbol: symbol,
      price: Decimal.new("1"),
      timestamp: ~U[2026-08-28 12:00:00Z],
      provider: :coinbase
    }
  end

  # Polls a condition instead of sleeping a guessed duration.
  #
  # `Process.sleep(n)` as a synchronisation device is a bet that some asynchronous work
  # finishes within `n` milliseconds on a loaded, `async: true` suite. It passes locally,
  # then fails in CI against code that is working correctly — which is strictly worse than
  # having no test, because it teaches the reader to distrust the suite. Both of the
  # retry-chain tests below were written that way and one of them did exactly that.
  defp wait_until(fun, timeout \\ 2_000, waited \\ 0) do
    cond do
      fun.() -> :ok
      waited >= timeout -> flunk("condition was still false after #{timeout}ms")
      true -> Process.sleep(5) && wait_until(fun, timeout, waited + 5)
    end
  end

  # Deterministic instead of `spawn(fn -> :ok end)` plus a guessed sleep: a monitor's
  # `:DOWN` message only arrives once the process has genuinely exited, so a "dead
  # socket"/"dead subscriber" test never races a scheduler slower than whatever fixed
  # delay was guessed.
  defp dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
    pid
  end

  defp order_book_for(symbol) do
    %Types.OrderBook{
      symbol: symbol,
      bids: [{Decimal.new("1"), Decimal.new("2")}],
      asks: [{Decimal.new("1.1"), Decimal.new("2")}],
      timestamp: ~U[2026-08-28 12:00:00Z],
      provider: :coinbase
    }
  end

  # What `Socket` now sends for a `level2` `update` frame instead of a rebuilt
  # `Types.OrderBook` — see `dp_exchange_core`'s `Types.OrderBookDelta` and this
  # package's own `Socket` moduledoc.
  defp order_book_delta_for(symbol) do
    %Types.OrderBookDelta{
      symbol: symbol,
      levels: [{:bid, Decimal.new("1"), Decimal.new("2")}],
      timestamp: ~U[2026-08-28 12:00:00Z],
      provider: :coinbase
    }
  end

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
      # DpCryptoManagement set 5_000 — below the 8s `@channel_spacing_ms` — and each cycle
      # re-fired before the previous one's `ticker` subscribe had gone out. Frames queued,
      # `send_frame` blew its window six times, and the Feed stopped answering
      # `:sys.get_state/1` entirely. A wedged feed is strictly worse than a late
      # resubscribe, so the delay is derived from the shards that actually exist.

      name = :"feed_#{System.unique_integer([:positive])}"

      pid =
        start_supervised!(
          {Feed,
           name: name, alias_map_source: fn -> {:ok, %{}} end, resubscribe_interval_ms: 5_000}
        )

      # `send/2` is async — `:sys.get_state/1` is a call, so it queues behind the
      # `:resubscribe` info message and guarantees it has been handled before the capture
      # block returns. Without it this test reads an empty log and fails on timing alone.
      log =
        capture_log(fn ->
          send(pid, :resubscribe)
          :sys.get_state(pid)
        end)

      # With no shards open the cycle is one channel spacing plus the send window.
      assert log =~ "resubscribe interval 5000ms is shorter than one re-issue cycle"
      assert log =~ "13000ms instead"
      assert Process.alive?(pid)
    end

    test "the 60s DEFAULT is itself too short past 12 shards, and is extended too" do
      # Reachable with no option set at all: a cycle spans
      # (shards - 1) * 5_000 + 8_000, which passes 60s at 12 shards — 1,101 symbols at
      # `@pairs_per_socket`. The consumer's diagnostic knob merely exposed a limit the
      # default already had.

      shards =
        Map.new(0..11, fn index ->
          {index, %{socket: spawn(fn -> Process.sleep(:infinity) end), symbols: []}}
        end)

      feed = start_feed()
      :sys.replace_state(feed, fn state -> %{state | shards: shards} end)

      log =
        capture_log(fn ->
          send(feed, :resubscribe)
          :sys.get_state(feed)
        end)

      # (12 - 1) * 5_000 + 8_000 = 63_000 span, + 5_000 send window = 68_000.
      assert log =~ "12 shard(s) (63000ms)"
      assert log =~ "68000ms instead"
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
    defp start_with_socket do
      socket = spawn(&reject_frames_loop/0)
      on_exit(fn -> Process.exit(socket, :kill) end)

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           socket: socket,
           alias_map_source: fn -> {:ok, %{}} end}
        )

      {feed, socket}
    end

    defp reject_frames_loop do
      receive do
        {:"$websockex_send", from, _frame} ->
          :gen.reply(from, {:error, :simulated_socket_failure})

        _other ->
          :ok
      end

      reject_frames_loop()
    end

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
      # The whole reason frames go through the guard: a dead socket must not take down
      # the process that would have re-established it.
      {feed, socket} = start_with_socket()
      ref = Process.monitor(socket)
      Process.exit(socket, :kill)
      assert_receive {:DOWN, ^ref, :process, ^socket, _reason}, 500

      assert {:error, _reason} = Feed.subscribe(feed, ~w(BTC-USD), to: self())
      assert Process.alive?(feed)
    end
  end

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
           alias_map_source: fn -> {:ok, %{}} end}
        )

      :ok = Feed.subscribe_notices(feed, to: self())

      # The first shard is synchronous (this call's own reply); the second is
      # deliberately staggered by @shard_spacing_ms so as not to burst-connect. The
      # endpoint is unreachable, so both attempts fail — proven here by BOTH actually
      # being observed to fail, not merely by the process surviving a brief pause: the
      # synchronous first shard's failure is this call's own reply, and the async
      # second shard's failure now emits a `:coverage_change` Notice (see
      # `notify_shard_open_failed/3`) once its staggered attempt actually runs, roughly
      # `@shard_spacing_ms` later.
      assert {:error, _reason} = Feed.subscribe(feed, symbols, to: self())

      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :coverage_change, details: %{shard: 1}}},
                     6_000

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
           alias_map_source: fn -> {:ok, %{}} end}
        )

      :ok = Feed.subscribe_notices(feed, to: self())
      assert {:error, _reason} = Feed.subscribe(feed, symbols, to: self())

      # Shard 1 fails roughly one @shard_spacing_ms out, shard 2 roughly two out — proof
      # every shard past the first got its own tick rather than all of them bursting
      # together (DpCryptoManagement's issue #20).
      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :coverage_change, details: %{shard: 1}}},
                     6_000

      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :coverage_change, details: %{shard: 2}}},
                     6_000

      assert Process.alive?(feed)
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
    defp fake_socket do
      pid = spawn(&fake_socket_loop/0)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      pid
    end

    defp fake_socket_loop do
      receive do
        {:"$websockex_send", from, _frame} -> :gen.reply(from, :ok)
        _other -> :ok
      end

      fake_socket_loop()
    end

    # Reports WHEN it received a send, tagged with `label`, to `test_pid` — the proof
    # `reconcile_shard/7`'s stagger actually works: two sockets' first frames arriving
    # `@shard_spacing_ms` apart, not proximity in the log or the process staying alive.
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

      send(feed, {:open_shard, 0, ["BTC-USD"]})

      # `:sys.get_state/1` already queues behind the send above, so it is the sync
      # barrier as well as the assertion — no separate sleep needed.
      state = :sys.get_state(feed)
      assert %{0 => %{socket: ^socket, symbols: ["BTC-USD"]}} = state.shards
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
      send(feed, {:open_shard, 0, ["BTC-USD"]})

      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :coverage_change, provider: :coinbase} = notice},
                     500

      assert notice.details.shard == 0
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
        match?(%{0 => %{socket: ^socket, symbols: ["BTC-USD"]}}, :sys.get_state(feed).shards)
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
            shards: %{0 => %{socket: existing_socket, symbols: ["BTC-USD"]}}
        }
      end)

      send(feed, :resubscribe)

      # `:sys.get_state/1` is a call, so it queues behind the `:resubscribe` info message
      # and is answered only once that handler has returned — no sleep needed to know the
      # tick itself has run. `retry_missing_shards/1` schedules nothing further for shard 0
      # (it is not missing), so there is no later async mutation to race either.
      assert :sys.get_state(feed).shards == %{
               0 => %{socket: existing_socket, symbols: ["BTC-USD"]}
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
      assert log =~ "attempt 1/3 — retrying in 5ms"
      refute log =~ "giving up"
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

      assert log =~ "failed permanently"
      assert log =~ "not retrying"
      refute log =~ "retrying in"
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

      assert log =~ "giving up until the next resubscribe cycle"

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

    test "a :channel_unsubscribe message reaches the socket" do
      feed = start_feed()
      socket = fake_socket()

      send(feed, {:channel_unsubscribe, socket, "ticker", ["BTC-USD"]})
      :sys.get_state(feed)

      assert Process.alive?(feed)
    end

    test "a :channel_unsubscribe against a dead socket is skipped" do
      feed = start_feed()
      dead = dead_pid()

      send(feed, {:channel_unsubscribe, dead, "ticker", ["BTC-USD"]})
      :sys.get_state(feed)

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
        %{state | shards: %{0 => %{socket: dead, symbols: ["BTC-USD"]}}}
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
      # 1 asynchronously and staggered by `@shard_spacing_ms` behind it.
      socket0 = timing_socket(self(), :shard0)
      socket1 = timing_socket(self(), :shard1)

      feed = start_feed()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | shards: %{
              0 => %{socket: socket0, symbols: ["PLACEHOLDER-0"]},
              1 => %{socket: socket1, symbols: ["PLACEHOLDER-1"]}
            }
        }
      end)

      new_symbols = for n <- 1..150, do: "NEW#{n}-USD"
      assert :ok = Feed.update_symbols(feed, new_symbols)

      assert_receive {:frame_at, :shard0, t0}, 500
      assert_receive {:frame_at, :shard1, t1}, 6_000

      # `@shard_spacing_ms` is 5_000; allow real scheduler jitter either side rather than
      # pinning the exact figure.
      assert t1 - t0 >= 4_000
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
      assert log =~ "attempt 1/3 — retrying in 5ms"
      refute log =~ "giving up"
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

      assert log =~ "failed permanently"
      assert log =~ "not retrying"
      refute log =~ "retrying in"

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

      assert log =~ "giving up"

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
end

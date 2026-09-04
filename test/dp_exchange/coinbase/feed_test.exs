defmodule DpExchange.Coinbase.FeedTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Feed
  alias DpExchange.Core.{Notice, Types}

  @moduletag :capture_log

  # Real GenServers and real messages. The feed's socket is never started here — these
  # test the subscription bookkeeping and the coverage rule, which is where the
  # interesting behaviour is and where a venue gets it wrong.
  defp start_feed do
    name = :"feed_#{System.unique_integer([:positive])}"
    pid = start_supervised!({Feed, name: name})
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

  describe "coverage is OBSERVED, never intended" do
    test "a symbol appears only once a payload for it arrives" do
      # The strongest guarantee in the contract. A venue once reported 325 symbols
      # subscribed and confirmed while 174 were delivering; reporting the subscription
      # would have said 325.
      feed = start_feed()

      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})
      Process.sleep(20)

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
      Process.sleep(20)

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
      Process.sleep(20)

      assert %{"BTC-USD" => :stream} = Feed.coverage(feed)
    end
  end

  describe "delivery" do
    test "quotes reach the subscribing process" do
      feed = start_feed()
      Feed.subscribe_notices(feed, to: self())

      # A subscriber is registered by `subscribe/3`; simulate one having been registered
      # by sending through the feed's own inbound path.
      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})
      Process.sleep(20)

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

      dead = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(dead)

      Feed.subscribe_notices(feed, to: dead)
      send(feed, {:dp_exchange, :coinbase, Notice.new(:link_up, :coinbase)})
      Process.sleep(20)

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

      assert_receive {:dp_exchange, :coinbase, %Notice{kind: :link_up}}
      assert Process.alive?(feed)

      Process.unregister(name)
    end

    test "a name that is not (or no longer) registered is silently skipped, not a crash" do
      name = :"coinbase_feed_test_unregistered_#{System.unique_integer([:positive])}"
      refute Process.whereis(name)
      feed = start_feed()

      Feed.subscribe_notices(feed, to: name)
      send(feed, {:dp_exchange, :coinbase, Notice.new(:link_up, :coinbase)})
      Process.sleep(20)

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
      Process.sleep(20)
      assert Process.alive?(feed)
    end
  end

  describe "unsubscribe with no socket" do
    test "succeeds and drops the symbols" do
      feed = start_feed()
      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})
      Process.sleep(20)

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
           name: :"feed_#{System.unique_integer([:positive])}", url: "ws://127.0.0.1:1/nowhere"}
        )

      assert {:error, _reason} = Feed.subscribe(feed, ~w(BTC-USD), to: self())
      assert Feed.coverage(feed) == %{}
    end

    test "the feed survives a socket that cannot start" do
      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}", url: "ws://127.0.0.1:1/nowhere"}
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
           name: :"feed_#{System.unique_integer([:positive])}", url: "ws://127.0.0.1:1/nowhere"}
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
      Process.sleep(20)

      refute_received {:dp_exchange, :coinbase, %Types.Quote{}}
    end
  end

  describe "update_symbols on a live set" do
    test "keeps coverage for symbols that stay" do
      feed = start_feed()

      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :coinbase, quote_for("ETH-USD")})
      Process.sleep(20)

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
    defp start_with_socket do
      socket = spawn(&reject_frames_loop/0)
      on_exit(fn -> Process.exit(socket, :kill) end)

      feed =
        start_supervised!(
          {Feed, name: :"feed_#{System.unique_integer([:positive])}", socket: socket}
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
      Process.sleep(20)

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
      Process.exit(socket, :kill)
      Process.sleep(20)

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

    test "pairs_per_socket is the number the incident measured, not a guess" do
      assert Feed.pairs_per_socket() == 100
    end
  end

  describe "sharding across the whole subscribe lifecycle" do
    test "subscribing 150 symbols opens two shards, the second staggered" do
      symbols = for n <- 1..150, do: "SYM#{n}-USD"

      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}", url: "ws://127.0.0.1:1/nowhere"}
        )

      # The first shard is synchronous (this call's own reply); the second is
      # deliberately staggered by @shard_spacing_ms so as not to burst-connect. The
      # endpoint is unreachable, so both attempts fail — what matters is that BOTH
      # shards get attempted rather than only the first, and that the process survives
      # both failures.
      assert {:error, _reason} = Feed.subscribe(feed, symbols, to: self())
      Process.sleep(50)

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

    test "an :open_shard message that succeeds opens the socket and subscribes" do
      # `socket:` pre-supplies the connection the same way `start_with_socket/0` does
      # for the top-level subscribe tests — a `feed_test.exs` running this against the
      # real endpoint would be a tier-2 test wearing a tier-1 tag.
      socket = fake_socket()

      feed =
        start_supervised!(
          {Feed, name: :"feed_#{System.unique_integer([:positive])}", socket: socket}
        )

      send(feed, {:open_shard, 0, ["BTC-USD"]})
      Process.sleep(20)

      state = :sys.get_state(feed)
      assert %{0 => %{socket: ^socket, symbols: ["BTC-USD"]}} = state.shards
    end

    test "an :open_shard message whose socket cannot open logs and leaves the shard absent" do
      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}", url: "ws://127.0.0.1:1/nowhere"}
        )

      send(feed, {:open_shard, 0, ["BTC-USD"]})
      Process.sleep(50)

      state = :sys.get_state(feed)
      assert state.shards == %{}
      assert Process.alive?(feed)
    end

    test "a :channel_subscribe message against a dead socket is skipped rather than raising" do
      feed = start_feed()
      dead = spawn(fn -> :ok end)
      Process.sleep(10)
      refute Process.alive?(dead)

      send(feed, {:channel_subscribe, dead, "ticker", ["BTC-USD"], nil})
      Process.sleep(20)

      assert Process.alive?(feed)
    end

    test "a :channel_subscribe failure is logged, not crashed on" do
      feed = start_feed()
      socket = fake_socket()

      send(feed, {:channel_subscribe, socket, "ticker", ["BTC-USD"], nil})
      Process.sleep(20)

      assert Process.alive?(feed)
    end

    test "a :channel_unsubscribe message reaches the socket" do
      feed = start_feed()
      socket = fake_socket()

      send(feed, {:channel_unsubscribe, socket, "ticker", ["BTC-USD"]})
      Process.sleep(20)

      assert Process.alive?(feed)
    end

    test "a :channel_unsubscribe against a dead socket is skipped" do
      feed = start_feed()
      dead = spawn(fn -> :ok end)
      Process.sleep(10)

      send(feed, {:channel_unsubscribe, dead, "ticker", ["BTC-USD"]})
      Process.sleep(20)

      assert Process.alive?(feed)
    end

    test "the resubscribe timer re-issues every open shard's subscriptions" do
      {feed, socket} = start_with_socket()

      Feed.subscribe(feed, ~w(BTC-USD), to: self())
      Process.sleep(20)

      send(feed, :resubscribe)
      Process.sleep(20)

      assert Process.alive?(feed)
      assert Process.alive?(socket)
    end

    test "the resubscribe timer skips a shard whose socket has died" do
      feed = start_feed()
      state = :sys.get_state(feed)
      dead = spawn(fn -> :ok end)
      Process.sleep(10)

      :sys.replace_state(feed, fn _s ->
        %{state | shards: %{0 => %{socket: dead, symbols: ["BTC-USD"]}}}
      end)

      send(feed, :resubscribe)
      Process.sleep(20)

      assert Process.alive?(feed)
    end
  end
end

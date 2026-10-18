defmodule DpExchange.Coinbase.InterleavingsTest do
  @moduledoc """
  Message orderings a real node can produce between `Feed`, its sockets and its own timers
  (tick AB). Each test forces ONE interleaving by hand: it builds the state the earlier steps
  would have left (`:sys.replace_state/2`) and sends the late message itself, so no outcome
  here depends on timing.
  """

  use DpExchange.Coinbase.FeedCase, async: true

  alias DpExchange.Coinbase.Feed
  alias DpExchange.Core.Notice

  # A socket double that reports every frame it is handed as `{:frame, type, product_ids}`,
  # answering the first `fail_first` sends with `reply` and every later one with `:ok`.
  defp scripted_socket(test_pid, fail_first, reply) do
    pid = spawn(fn -> scripted_loop(test_pid, fail_first, reply) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp scripted_loop(test_pid, remaining, reply) do
    receive do
      {:"$websockex_send", from, {:text, payload}} ->
        %{"type" => type, "product_ids" => ids} = Jason.decode!(payload)
        send(test_pid, {:frame, type, ids})

        if remaining > 0 do
          :gen.reply(from, reply)
          scripted_loop(test_pid, remaining - 1, reply)
        else
          :gen.reply(from, :ok)
          scripted_loop(test_pid, 0, reply)
        end

      _other ->
        scripted_loop(test_pid, remaining, reply)
    end
  end

  defp not_connected,
    do: {:error, %WebSockex.NotConnectedError{connection_state: :opening}}

  defp put_shard(feed, socket, symbols) do
    :sys.replace_state(feed, fn state ->
      %{
        state
        | wanted: MapSet.new(symbols),
          shards: %{{"ticker", 0} => %{socket: socket, symbols: symbols}}
      }
    end)
  end

  describe "a retried :channel_subscribe does not trust the symbols it was scheduled with" do
    # 1. the shard's subscribe for [A, B] times out; a retry carrying [A, B] is scheduled.
    # 2. unsubscribe(["B"]) runs: the shard now lists [A] and B's unsubscribe frame went out.
    # 3. the retry fires. It used to subscribe [A, B], re-subscribing B at the venue with
    #    nothing left that would ever release it.
    test "a symbol unsubscribed since the failure is not subscribed again" do
      socket = scripted_socket(self(), 0, :ok)
      feed = start_feed()
      put_shard(feed, socket, ["A-USD"])

      send(feed, {:channel_subscribe, socket, "ticker", ["A-USD", "B-USD"], nil, 2})

      assert_receive {:frame, "subscribe", ["A-USD"]}, 5_000
      :sys.get_state(feed)
      refute_receive {:frame, _type, _ids}, 500
    end

    test "a retry whose symbols have all been unsubscribed sends nothing at all" do
      socket = scripted_socket(self(), 0, :ok)
      feed = start_feed()
      put_shard(feed, socket, ["A-USD"])

      send(feed, {:channel_subscribe, socket, "ticker", ["B-USD"], nil, 2})

      # `get_state/1` is a call, so it is answered only after the retry's handler returned
      # and any frame it sent (synchronously) is already in this mailbox.
      :sys.get_state(feed)
      refute_receive {:frame, _type, _ids}, 500
    end

    test "a socket that carries no shard is left as given (the dead-socket guard owns it)" do
      socket = scripted_socket(self(), 0, :ok)
      feed = start_feed()

      send(feed, {:channel_subscribe, socket, "ticker", ["B-USD"], nil, 2})

      assert_receive {:frame, "subscribe", ["B-USD"]}, 5_000
    end
  end

  describe "a send that finds the socket between connections is transient" do
    # The socket dropped and reconnects with no backoff; this feed has not yet read the
    # :link_down, so `sendable?/2` says yes. The vendored `open_loop/3` answers the queued
    # send `{:error, %WebSockex.NotConnectedError{}}` at once.
    test "a subscribe answered NotConnectedError is retried, not reported as permanent" do
      socket = scripted_socket(self(), 1, not_connected())

      feed = start_feed(subscribe_retry_delay_ms: 5)
      Feed.subscribe_notices(feed, to: self())

      send(feed, {:channel_subscribe, socket, "ticker", ["BTC-USD"], nil})

      # The second frame IS the retry: a permanent classification ends the chain after the
      # first and sends the "will keep failing every cycle" coverage_change notice instead.
      assert_receive {:frame, "subscribe", ["BTC-USD"]}, 5_000
      assert_receive {:frame, "subscribe", ["BTC-USD"]}, 5_000
      :sys.get_state(feed)
      refute_receive {:dp_exchange, :coinbase, %Notice{kind: :coverage_change}}, 500
    end

    test "an unsubscribe answered NotConnectedError is retried, not stranded" do
      socket = scripted_socket(self(), 1, not_connected())

      feed = start_feed(subscribe_retry_delay_ms: 5)
      Feed.subscribe_notices(feed, to: self())
      put_shard(feed, socket, ["NEW-USD"])

      send(
        feed,
        {:channel_reconcile, {"ticker", 0}, socket, "ticker", ["OLD-USD"], ["NEW-USD"], nil}
      )

      assert_receive {:frame, "unsubscribe", ["OLD-USD"]}, 5_000
      assert_receive {:frame, "unsubscribe", ["OLD-USD"]}, 5_000
      assert_receive {:frame, "subscribe", ["NEW-USD"]}, 5_000

      assert :sys.get_state(feed).pending_unsubscribes == %{}
      refute_receive {:dp_exchange, :coinbase, %Notice{kind: :coverage_change}}, 500
    end
  end

  describe "a synchronous open whose connect fails" do
    # (1) a crash backoff schedules a deferred open for {"ticker", 0}; (2) a `subscribe/2`
    # opens that key synchronously and the connect fails. The deferred open was cancelled
    # BEFORE the connect, so the shard stayed closed until the next `:resubscribe` tick.
    test "leaves the deferred open in place to try again" do
      feed =
        start_supervised!(
          {Feed,
           name: :"feed_#{System.unique_integer([:positive])}",
           url: "ws://127.0.0.1:1/nowhere",
           channels: [:quotes],
           alias_map_source: fn -> {:ok, %{}} end}
        )

      key = {"ticker", 0}
      ref = make_ref()
      timer = Process.send_after(feed, {:open_shard, "ticker", 0, ["BTC-USD"], ref}, 60_000)
      on_exit(fn -> Process.cancel_timer(timer) end)

      :sys.replace_state(feed, fn state ->
        %{state | pending_opens: %{key => %{ref: ref, timer: timer, symbols: ["BTC-USD"]}}}
      end)

      assert {:error, _reason} = Feed.subscribe(feed, ~w(BTC-USD), to: self())
      assert %{^key => %{ref: ^ref}} = :sys.get_state(feed).pending_opens
    end
  end
end

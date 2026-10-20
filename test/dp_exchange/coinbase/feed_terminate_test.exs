defmodule DpExchange.Coinbase.FeedTerminateTest do
  @moduledoc """
  A feed that stops takes its shard sockets with it, and closes their links on the metrics
  channel.

  Every socket is a linked child of the feed and does not trap exits, so a supervisor's
  `:shutdown` already ended them, and a `:normal` stop (`GenServer.stop/1`'s default) did not:
  a link ignores a `:normal` exit, and the sockets went on delivering to a feed that no longer
  existed. None of them ran a disconnect callback either, so a consumer's link gauge stayed
  "up". Tier 1: the sockets are doubles that answer sends.
  """

  use DpExchange.Coinbase.FeedCase, async: true

  alias DpExchange.Coinbase.Feed

  # Handlers run in the emitting process, so filtering on the feed's pid keeps other async
  # tests' events out.
  defp attach_down(feed) do
    test_pid = self()
    id = "feed-terminate-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:dp_exchange, :link, :down],
      fn _event, _measurements, metadata, feed_pid ->
        if self() == feed_pid, do: send(test_pid, {:link_down, metadata})
      end,
      feed
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp feed_with_shard(socket) do
    feed = start_feed()

    :sys.replace_state(feed, fn state ->
      %{state | shards: %{{"ticker", 0} => %{socket: socket, symbols: ["A-USD"]}}}
    end)

    attach_down(feed)
    feed
  end

  test "a feed stopped with :normal stops its sockets, and reports each link closed once" do
    socket = fake_socket()
    ref = Process.monitor(socket)
    feed = feed_with_shard(socket)

    :ok = GenServer.stop(feed, :normal)

    assert_receive {:DOWN, ^ref, :process, ^socket, :shutdown}, 5_000
    assert_receive {:link_down, %{provider: :coinbase, reason: ":normal"}}, 5_000
    refute_receive {:link_down, _metadata}, 500
  end

  test "a feed stopped by its supervisor does the same, with that reason" do
    socket = fake_socket()
    ref = Process.monitor(socket)
    _feed = feed_with_shard(socket)

    :ok = stop_supervised(Feed)

    assert_receive {:DOWN, ^ref, :process, ^socket, :shutdown}, 5_000
    assert_receive {:link_down, %{provider: :coinbase, reason: ":shutdown"}}, 5_000
    refute_receive {:link_down, _metadata}, 500
  end

  test "a socket that already reported its own drop is not reported closed a second time" do
    socket = fake_socket()
    ref = Process.monitor(socket)
    feed = feed_with_shard(socket)

    send(feed, {:dp_exchange, :coinbase, :link_down, socket})
    assert MapSet.member?(:sys.get_state(feed).down_links, socket)

    :ok = GenServer.stop(feed, :normal)

    # Still stopped; only the second report is withheld.
    assert_receive {:DOWN, ^ref, :process, ^socket, :shutdown}, 5_000
    refute_receive {:link_down, _metadata}, 500
  end

  test "a feed with no shards stops quietly" do
    feed = start_feed()
    attach_down(feed)

    :ok = GenServer.stop(feed, :normal)

    refute_receive {:link_down, _metadata}, 500
  end
end

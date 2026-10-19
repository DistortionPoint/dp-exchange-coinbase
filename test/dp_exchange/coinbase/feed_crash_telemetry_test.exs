defmodule DpExchange.Coinbase.FeedCrashTelemetryTest do
  @moduledoc """
  A shard socket that crashes runs no `handle_disconnect/2`, so the `Feed` is the only place
  that can report its link as lost on the metrics channel. A socket that already reported its
  own drop must not be reported twice.
  """

  use DpExchange.Coinbase.FeedCase, async: true

  alias DpExchange.Coinbase.Feed
  alias DpExchange.Core.Notice

  defp attach(marker) do
    test_pid = self()
    id = "crash-telemetry-#{marker}"

    :telemetry.attach(
      id,
      [:dp_exchange, :link, :down],
      fn _event, _measurements, metadata, _config ->
        if is_binary(metadata[:reason]) and metadata[:reason] =~ marker,
          do: send(test_pid, {:link_down, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp feed_with_shard(socket) do
    feed = start_feed()
    key = {"ticker", 0}

    :sys.replace_state(feed, fn state ->
      %{state | shards: %{key => %{socket: socket, symbols: ["A-USD"]}}}
    end)

    feed
  end

  defp marker, do: "marker_#{System.unique_integer([:positive])}"

  test "a crashed shard socket emits link_down once, with bounded reason text" do
    marker = marker()
    attach(marker)
    socket = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(socket, :kill) end)
    feed = feed_with_shard(socket)

    send(feed, {:EXIT, socket, {:boom, marker}})

    assert_receive {:link_down, %{provider: :coinbase, reason: reason}}, 5_000
    assert reason =~ marker
    assert byte_size(reason) < 4_096
    refute_receive {:link_down, _metadata}, 500
  end

  test "a socket that already reported its own drop is not reported again on crash" do
    marker = marker()
    attach(marker)
    socket = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(socket, :kill) end)
    feed = feed_with_shard(socket)

    send(feed, {:dp_exchange, :coinbase, :link_down, socket})
    assert MapSet.member?(:sys.get_state(feed).down_links, socket)

    send(feed, {:EXIT, socket, {:boom, marker}})
    # A synchronous call: the EXIT above has been handled once this returns.
    _state = :sys.get_state(feed)

    refute_receive {:link_down, _metadata}, 500
  end

  # Handlers run in the emitting process, so filtering on the feed's pid keeps other async
  # tests' retirements out.
  defp attach_retired(feed) do
    test_pid = self()
    id = "retired-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:dp_exchange, :link, :down],
      fn _event, _measurements, metadata, feed_pid ->
        if self() == feed_pid, do: send(test_pid, {:retired_down, metadata})
      end,
      feed
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  test "a retired shard's link is closed on the metrics channel, with no notice" do
    feed = feed_with_shard(fake_socket())
    attach_retired(feed)
    :ok = Feed.subscribe_notices(feed, to: self())

    :sys.replace_state(feed, fn state -> %{state | wanted: MapSet.new(["A-USD"])} end)
    assert :ok = Feed.unsubscribe(feed, ["A-USD"])

    assert_receive {:retired_down, %{provider: :coinbase, reason: ":retired"}}, 5_000
    assert :sys.get_state(feed).shards == %{}
    refute_receive {:retired_down, _metadata}, 500
    refute_receive {:dp_exchange, :coinbase, %Notice{kind: :link_down}}, 500
  end

  test "a retired shard whose link already reported its drop is not closed twice" do
    socket = fake_socket()
    feed = feed_with_shard(socket)
    attach_retired(feed)

    :sys.replace_state(feed, fn state ->
      %{state | wanted: MapSet.new(["A-USD"]), down_links: MapSet.new([socket])}
    end)

    assert :ok = Feed.unsubscribe(feed, ["A-USD"])
    _settled = :sys.get_state(feed)
    refute_receive {:retired_down, _metadata}, 500
  end

  test "nor is a second :link_down notice sent: a down closes an up, and none came between" do
    socket = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(socket, :kill) end)
    feed = feed_with_shard(socket)
    :ok = Feed.subscribe_notices(feed, to: self())

    # The socket's own drop reaches subscribers as the socket's `:link_down` notice; the feed
    # is only told which shard it was.
    send(feed, {:dp_exchange, :coinbase, :link_down, socket})
    assert MapSet.member?(:sys.get_state(feed).down_links, socket)

    send(feed, {:EXIT, socket, {:boom, marker()}})
    _state = :sys.get_state(feed)

    refute_receive {:dp_exchange, :coinbase, %Notice{kind: :link_down}}, 500
  end

  test "a crash of a socket whose link was up reports the shard as down once" do
    socket = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(socket, :kill) end)
    feed = feed_with_shard(socket)
    :ok = Feed.subscribe_notices(feed, to: self())

    send(feed, {:EXIT, socket, {:boom, marker()}})

    assert_receive {:dp_exchange, :coinbase,
                    %Notice{kind: :link_down, details: %{reason: :shard_crashed}}},
                   5_000

    refute_receive {:dp_exchange, :coinbase, %Notice{kind: :link_down}}, 500
  end
end

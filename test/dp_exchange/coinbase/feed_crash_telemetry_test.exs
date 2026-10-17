defmodule DpExchange.Coinbase.FeedCrashTelemetryTest do
  @moduledoc """
  A shard socket that crashes runs no `handle_disconnect/2`, so the `Feed` is the only place
  that can report its link as lost on the metrics channel. A socket that already reported its
  own drop must not be reported twice.
  """

  use DpExchange.Coinbase.FeedCase, async: true

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
end

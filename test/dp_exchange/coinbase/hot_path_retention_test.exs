defmodule DpExchange.Coinbase.HotPathRetentionTest do
  @moduledoc """
  Structural proofs for the hot-path fixes of tick AD: what a long-lived structure retains,
  and which timers outlive the work that armed them. No wall-clock assertions: the checks are
  on binary reference sizes, process state and timer references.
  """

  use DpExchange.Coinbase.FeedCase, async: true

  alias DpExchange.Coinbase.{Feed, Socket}
  alias DpExchange.Core.Notice

  # A frame far larger than anything kept from it. The padding rides in a field the decoder
  # parses, so the decoded strings really are sub-binaries of this payload.
  @padding String.duplicate("x", 200_000)

  defp socket_state do
    %{
      subscriber: self(),
      credentials: nil,
      delivering: MapSet.new(),
      connected_once?: false,
      last_seq: nil,
      stale_run: nil,
      last_frame_at: nil,
      silence_check: nil,
      connected_at: System.monotonic_time(:millisecond) - 60_000,
      short_sessions: 0
    }
  end

  defp frame(payload, state), do: Socket.handle_frame({:text, Jason.encode!(payload)}, state)

  defp retained_bytes(binary), do: :binary.referenced_byte_size(binary)

  # Answers every `WebSockex.send_frame/2` with `:ok`, as a connected socket would.
  defp acknowledge_sends do
    receive do
      {:"$websockex_send", from, _frame} -> :gen.reply(from, :ok)
    end

    acknowledge_sends()
  end

  describe "Socket keeps no reference into a large frame" do
    test "a fault subject remembered in reported_faults does not pin its frame" do
      payload = %{
        "channel" => "market_trades",
        "sequence_num" => 1,
        "events" => [
          %{
            "type" => "update",
            "trades" => [
              %{"product_id" => "BTC-USD", "trade_id" => nil, "padding" => @padding}
            ]
          }
        ]
      }

      assert {:ok, state} = frame(payload, socket_state())

      assert [{:market_trades, subject, _kind}] = MapSet.to_list(state.reported_faults)
      assert subject == "BTC-USD"
      assert retained_bytes(subject) < 1_000

      assert_received {:dp_exchange, :coinbase, %Notice{details: %{payload: noticed}}}
      assert retained_bytes(noticed) < 1_000
    end

    test "an unsubscribed channel name remembered in reported_faults does not pin its frame" do
      payload = %{
        "channel" => "status",
        "sequence_num" => 1,
        "events" => [%{"padding" => @padding}]
      }

      assert {:ok, state} = frame(payload, socket_state())

      assert [{:unsubscribed_channel, channel, :received}] =
               MapSet.to_list(state.reported_faults)

      assert channel == "status"
      assert retained_bytes(channel) < 1_000
    end

    test "a venue error text quoted into a notice does not pin its frame" do
      payload = %{"type" => "error", "message" => "boom " <> @padding}

      assert {:ok, _state} = frame(payload, socket_state())

      assert_received {:dp_exchange, :coinbase, %Notice{message: message}}
      assert byte_size(message) == 1_024
      assert retained_bytes(message) < 2_000
    end
  end

  describe "Feed does not leave bookkeeping or timers behind" do
    test "a retired shard takes its gap bookkeeping and trailing gap timer with it" do
      feed = start_feed()
      key = {"level2", 0}
      socket = spawn(fn -> acknowledge_sends() end)
      on_exit(fn -> Process.exit(socket, :kill) end)

      # A timer that would fire long after the test, standing in for the trailing re-issue
      # `gap_resubscribe/3` arms.
      timer = Process.send_after(self(), :stand_in_gap_timer, 600_000)

      :sys.replace_state(feed, fn state ->
        %{
          state
          | shards: %{key => %{socket: socket, symbols: ["BTC-USD"]}},
            gap_resubscribed_at: %{key => System.monotonic_time(:millisecond)},
            gap_resubscribe_due: %{key => timer}
        }
      end)

      # Nothing is wanted, so the shard vanishes and is retired once its release is sent.
      assert :ok = Feed.update_symbols(feed, [])

      state = :sys.get_state(feed)
      assert state.shards == %{}
      assert state.gap_resubscribed_at == %{}
      assert state.gap_resubscribe_due == %{}
      assert Process.read_timer(timer) == false
    end

    test "an alias-map fetch that answers cancels its timeout timer" do
      test = self()

      source = fn ->
        send(test, {:fetching, self()})

        receive do
          :answer -> {:ok, %{}}
        end
      end

      name = :"feed_#{System.unique_integer([:positive])}"
      feed = start_supervised!({Feed, [name: name, alias_map_source: source]})

      send(feed, :fetch_alias_map)
      assert_receive {:fetching, task}, 5_000

      %{alias_map_fetch: %{timer: timer}} = :sys.get_state(feed)
      assert is_integer(Process.read_timer(timer))

      send(task, :answer)
      wait_until(fn -> :sys.get_state(feed).alias_map_fetch == nil end)

      assert Process.read_timer(timer) == false
      assert :sys.get_state(feed).alias_map_status == :ok
    end

    test "an alias-map fetch that dies cancels its timeout timer" do
      test = self()

      source = fn ->
        send(test, {:fetching, self()})
        Process.sleep(:infinity)
      end

      name = :"feed_#{System.unique_integer([:positive])}"

      feed =
        start_supervised!(
          {Feed, [name: name, alias_map_source: source, alias_map_retry_delay_ms: 600_000]}
        )

      send(feed, :fetch_alias_map)
      assert_receive {:fetching, task}, 5_000

      %{alias_map_fetch: %{timer: timer}} = :sys.get_state(feed)
      assert is_integer(Process.read_timer(timer))

      Process.exit(task, :kill)
      wait_until(fn -> :sys.get_state(feed).alias_map_fetch == nil end)

      assert Process.read_timer(timer) == false
    end
  end
end

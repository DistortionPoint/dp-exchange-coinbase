defmodule DpExchange.Coinbase.SocketBranchesTest do
  @moduledoc """
  `Socket` branches no other test reached: which URLs a credentialed socket may dial, how a
  drop is counted when no session ran, frames whose fields are present but unreadable, and
  who hears a socket's notices and link reports (a registered name hears them as it hears
  data; a state with no subscriber at all hears none and the work goes on).

  The WebSockex callbacks are called directly with real payloads, as `SocketTest` does.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Socket
  alias DpExchange.Core.{Notice, Types}

  @moduletag :capture_log

  @credentials %{api_key: "test-key-not-real", api_secret: "test-secret-not-real"}

  defp state do
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

  defp numbered(sequence_num),
    do: %{"channel" => "heartbeats", "sequence_num" => sequence_num, "events" => []}

  describe "start_link/1 — which URLs a credentialed socket may dial" do
    test "a wss:// URL passes the plaintext check" do
      # Only the check is under test: the venue named is a closed local port, so the dial
      # itself fails, quickly and locally, with something other than the refusal.
      Process.flag(:trap_exit, true)
      opts = [subscriber: self(), credentials: @credentials, url: "wss://127.0.0.1:1/"]

      assert {:error, reason} = Socket.start_link(opts)
      refute reason == {:insecure_url, :coinbase}
    end

    test "a %URI{} for a remote plaintext host is refused like its string" do
      uri = URI.parse("ws://example.invalid/")
      opts = [subscriber: self(), credentials: @credentials, url: uri]

      result = Socket.start_link(opts)

      assert result == {:error, {:insecure_url, :coinbase}}
      refute inspect(result) =~ "example.invalid"
    end

    test "a URL that cannot be inspected is refused, not assumed safe" do
      opts = [subscriber: self(), credentials: @credentials, url: ~c"ws://example.invalid/"]

      assert Socket.start_link(opts) == {:error, {:insecure_url, :coinbase}}
    end
  end

  describe "handle_disconnect/2 — a drop with no session behind it" do
    test "is not a stable session, so it counts toward the backoff" do
      # websockex reports attempt 1 for a drop with no recorded connect time (no session
      # ran since the last drop). With nothing to measure the age from, "healthy blip" would
      # be a guess; the answer that cannot cause a reconnect storm is no.
      never_connected = %{state() | connected_at: nil}

      assert {:reconnect, after_drop} =
               Socket.handle_disconnect(%{reason: :closed, attempt_number: 1}, never_connected)

      assert after_drop.short_sessions == 1
    end

    test "reports no link_down: there was no link_up for it to close" do
      never_connected = %{state() | connected_at: nil}

      assert {:reconnect, _after_drop} =
               Socket.handle_disconnect(%{reason: :closed, attempt_number: 1}, never_connected)

      refute_receive {:dp_exchange, :coinbase, %Notice{kind: :link_down}}, 500
      refute_receive {:dp_exchange, :coinbase, :link_down, _socket}, 500
    end
  end

  describe "handle_disconnect/2 — a failed reconnect attempt is not another link going down" do
    # `websockex` calls the callback for the drop of a live session and again for every
    # reconnect attempt that fails. Each of the later calls used to send a `:link_down`
    # notice, a telemetry event and a `Feed` link report with no `:link_up` between them.
    setup do
      marker = "marker_#{System.unique_integer([:positive])}"
      test = self()
      id = "link-down-pairing-#{marker}"

      :telemetry.attach(
        id,
        [:dp_exchange, :link, :down],
        fn _event, _measurements, metadata, _config ->
          if is_binary(metadata[:reason]) and metadata[:reason] =~ marker,
            do: send(test, {:telemetry_link_down, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
      %{reason: {:remote, marker}}
    end

    test "the session's drop reports once; the failed attempt after it reports nothing",
         %{reason: reason} do
      me = self()

      assert {:reconnect, after_drop} =
               Socket.handle_disconnect(%{reason: reason, attempt_number: 1}, state())

      assert after_drop.connected_at == nil
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :link_down}}
      assert_received {:dp_exchange, :coinbase, :link_down, ^me}
      assert_received {:telemetry_link_down, _metadata}

      # The reconnect fails: attempt 2, and `handle_connect/2` has not run since the drop.
      assert {:reconnect, _still_down} =
               Socket.handle_disconnect(%{reason: reason, attempt_number: 2}, after_drop)

      refute_receive {:dp_exchange, :coinbase, %Notice{kind: :link_down}}, 500
      refute_receive {:dp_exchange, :coinbase, :link_down, _socket}, 500
      refute_receive {:telemetry_link_down, _metadata}, 500
    end

    test "a reconnect that succeeds re-arms the pairing: the next drop reports again",
         %{reason: reason} do
      assert {:reconnect, down} =
               Socket.handle_disconnect(%{reason: reason, attempt_number: 1}, state())

      assert_received {:dp_exchange, :coinbase, %Notice{kind: :link_down}}

      assert {:ok, up} = Socket.handle_connect(%{}, %{down | connected_once?: true})
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :link_up}}
      refute_received {:dp_exchange, :coinbase, %Notice{kind: :link_down}}

      assert {:reconnect, _down_again} =
               Socket.handle_disconnect(%{reason: reason, attempt_number: 1}, up)

      assert_received {:dp_exchange, :coinbase, %Notice{kind: :link_down}}
    end
  end

  describe "frames whose fields are present but unreadable" do
    @envelope_time "2026-08-28T14:53:45.649112Z"

    test "a ticker row with no price is reported, never delivered as a quote" do
      payload = %{
        "channel" => "ticker",
        "timestamp" => @envelope_time,
        "events" => [%{"tickers" => [%{"product_id" => "BTC-USD"}]}]
      }

      assert {:ok, _state} = frame(payload, state())

      refute_received {:dp_exchange, :coinbase, %Types.Quote{}}
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = notice}
      assert notice.details.channel == :ticker
      assert notice.details.reason == :unexpected_payload
    end

    test "a volume that is a number, not text, is nil rather than guessed" do
      ticker = %{"product_id" => "BTC-USD", "price" => "79478.7", "volume_24_h" => 1234}

      payload = %{
        "channel" => "ticker",
        "timestamp" => @envelope_time,
        "events" => [%{"tickers" => [ticker]}]
      }

      assert {:ok, _state} = frame(payload, state())

      assert_received {:dp_exchange, :coinbase, %Types.Quote{} = delivered}
      assert delivered.volume == nil
      assert delivered.volume_window == nil
    end

    test "a level2 row with a readable price and an unreadable quantity refuses the frame" do
      row = %{
        "event_time" => "2026-08-28T14:53:45.000000Z",
        "side" => "bid",
        "price_level" => "100.00",
        "new_quantity" => "lots"
      }

      payload = %{
        "channel" => "l2_data",
        "timestamp" => @envelope_time,
        "events" => [%{"type" => "update", "product_id" => "BTC-USD", "updates" => [row]}]
      }

      assert {:ok, _state} = frame(payload, state())

      refute_received {:dp_exchange, :coinbase, %Types.OrderBookDelta{}}
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = notice}
      assert notice.details.reason == :unreadable_price_level_or_quantity
      assert notice.details.bad_rows == 1
    end

    test "a trade time that is not text is reported with the value as it came" do
      trade = %{
        "product_id" => "BTC-USD",
        "trade_id" => "1",
        "price" => "1",
        "size" => "1",
        "time" => 123,
        "side" => "BUY"
      }

      payload = %{
        "channel" => "market_trades",
        "timestamp" => @envelope_time,
        "events" => [%{"type" => "update", "trades" => [trade]}]
      }

      assert {:ok, _state} = frame(payload, state())

      refute_received {:dp_exchange, :coinbase, %Types.Trade{}}
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = notice}
      assert notice.details.reason == {:unparseable_venue_timestamp, "123"}
    end
  end

  describe "an event of a subscribed channel that is none of the known shapes" do
    # These were dropped without a word, so a venue changing the shape of its ticker or book
    # events read as a quiet market. Reported once per shape and connection; the frame's other
    # events are still decoded.
    @event_time "2026-08-28T14:53:45.000000Z"

    test "a ticker event with no tickers, or no object at all, is reported once per shape" do
      ticker = %{"product_id" => "BTC-USD", "price" => "100.5"}
      good = %{"type" => "update", "tickers" => [ticker]}
      bad = %{"type" => "update", "tickers" => nil}

      payload = %{
        "channel" => "ticker",
        "timestamp" => @event_time,
        "events" => [bad, bad, "junk", "more junk", good]
      }

      assert {:ok, after_frame} = frame(payload, state())

      assert_received {:dp_exchange, :coinbase, %Types.Quote{symbol: "BTC-USD"}}

      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = shape}
      assert shape.details.channel == :ticker
      assert shape.details.reason == :unexpected_event
      assert shape.details.payload == "type=update keys=tickers,type"
      assert is_binary(shape.details.event)

      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = junk}
      assert junk.details.payload == "not an object: string"

      # The repeats were withheld, and a second frame with the same shapes says nothing more.
      refute_received {:dp_exchange, :coinbase, %Notice{}}
      assert {:ok, _again} = frame(payload, after_frame)
      refute_receive {:dp_exchange, :coinbase, %Notice{kind: :data_quality}}, 500
    end

    test "a level2 event with no usable product or rows is reported; neighbours deliver" do
      row = %{
        "event_time" => @event_time,
        "side" => "bid",
        "price_level" => "100.00",
        "new_quantity" => "2"
      }

      events = [
        %{"type" => "update", "product_id" => "BTC-USD", "updates" => nil},
        %{"type" => "update", "product_id" => 7, "updates" => []},
        %{"type" => "mystery"},
        42,
        %{"type" => "snapshot", "product_id" => "ETH-USD", "updates" => [row]}
      ]

      payload = %{"channel" => "l2_data", "timestamp" => @event_time, "events" => events}

      assert {:ok, _state} = frame(payload, state())

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{symbol: "ETH-USD"}}

      shapes =
        for _notice <- 1..3 do
          assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = notice}
          assert notice.details.channel == :level2
          assert notice.details.reason == :unexpected_event
          notice.details.payload
        end

      assert Enum.sort(shapes) == [
               "not an object: number",
               "type=mystery keys=type",
               "type=update keys=product_id,type,updates"
             ]

      refute_received {:dp_exchange, :coinbase, %Notice{}}
    end
  end

  describe "a socket whose subscriber is a registered name" do
    setup do
      name = :"socket_subscriber_#{System.unique_integer([:positive])}"
      Process.register(self(), name)
      %{named: %{state() | subscriber: name, connected_once?: true}}
    end

    test "hears the notices and the link reports, as it hears data", %{named: named} do
      me = self()

      assert {:ok, _connected} = Socket.handle_connect(%{}, named)
      assert_received {:dp_exchange, :coinbase, %Notice{kind: :link_up}}
      assert_received {:dp_exchange, :coinbase, :reconnected, ^me}

      assert {:reconnect, _state} =
               Socket.handle_disconnect(%{reason: :closed, attempt_number: 1}, named)

      assert_received {:dp_exchange, :coinbase, %Notice{kind: :link_down}}
      assert_received {:dp_exchange, :coinbase, :link_down, ^me}
    end

    test "is told which connection gapped", %{named: named} do
      me = self()

      assert {:ok, after_first} = frame(numbered(10), named)
      assert {:ok, _after_gap} = frame(numbered(14), after_first)

      assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality} = notice}
      assert notice.details.reason == :sequence_gap
      assert_received {:dp_exchange, :coinbase, :sequence_gap, ^me}
    end
  end

  describe "a state with no subscriber at all" do
    setup do
      %{bare: Map.delete(state(), :subscriber)}
    end

    test "connecting and dropping say nothing, and carry on", %{bare: bare} do
      assert {:ok, _connected} = Socket.handle_connect(%{}, %{bare | connected_once?: true})

      assert {:reconnect, _state} =
               Socket.handle_disconnect(%{reason: :closed, attempt_number: 1}, bare)

      refute_received {:dp_exchange, :coinbase, _anything}
    end

    test "a gap in the numbering says nothing, and carries on", %{bare: bare} do
      assert {:ok, after_first} = frame(numbered(10), bare)
      assert {:ok, after_gap} = frame(numbered(14), after_first)

      assert after_gap.last_seq == 14
      refute_received {:dp_exchange, :coinbase, _anything}
    end
  end
end

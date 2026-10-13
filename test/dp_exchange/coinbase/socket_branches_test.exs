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
      refute reason == :insecure_websocket_url
    end

    test "a %URI{} for a remote plaintext host is refused like its string" do
      uri = URI.parse("ws://example.invalid/")
      opts = [subscriber: self(), credentials: @credentials, url: uri]

      result = Socket.start_link(opts)

      assert result == {:error, :insecure_websocket_url}
      refute inspect(result) =~ "example.invalid"
    end

    test "a URL that cannot be inspected is refused, not assumed safe" do
      opts = [subscriber: self(), credentials: @credentials, url: ~c"ws://example.invalid/"]

      assert Socket.start_link(opts) == {:error, :insecure_websocket_url}
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

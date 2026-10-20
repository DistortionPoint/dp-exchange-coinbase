defmodule DpExchange.Coinbase.SocketSecretHygieneTest do
  @moduledoc """
  Where the signed JWT of an authenticated subscribe, and the credentials it is signed from,
  could still have reached something that prints or exports them, and the other places a
  value from a venue frame could outlive it. Tier 1: the sockets here talk to a TCP server on
  `127.0.0.1`.

    * the vendored websockex's `[:websockex, :frame, :sent]` telemetry event carried the whole
      frame, token included, to any handler attached to it;
    * a socket that stopped left a queued `$websockex_send` message (the frame, token
      included) in the mailbox its crash report prints, and its sender without an answer;
    * `Credentials.wrap/1` raised `FunctionClauseError` for a secret that was not a map, and
      OTP prints the failed call's arguments;
    * `WebSockex.URLError` carries the URL it refused, whole;
    * a trade id decoded from a frame kept the frame alive in whoever held the trade.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Credentials, Feed, FrameSender, Socket}
  alias DpExchange.Core.{Notice, Types}

  @moduletag :capture_log

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  @timeouts [socket_connect_timeout: 5_000, socket_recv_timeout: 5_000]

  # A frame far larger than anything kept from it.
  @padding String.duplicate("x", 200_000)

  # A 32-byte Ed25519 seed, Base64: what `Auth.jwt/2` signs with.
  @credentials %{
    api_key: "organizations/org/apiKeys/key",
    api_secret: Base.encode64(String.duplicate("k", 32))
  }

  defp socket_opts(port), do: [url: "ws://127.0.0.1:#{port}/", subscriber: self()] ++ @timeouts

  describe "a sent frame on the telemetry channel" do
    test "reaches a [:websockex, :frame, :sent] handler without the token it carried" do
      {listen_socket, port} = listen()
      serve(listen_socket, [&upgrade_then_hold/1])

      {:ok, socket} = Socket.start_link(socket_opts(port))
      on_exit(fn -> if Process.alive?(socket), do: Process.exit(socket, :kill) end)
      assert_receive {:dp_exchange, :coinbase, %Notice{kind: :link_up}}, 10_000

      attach_sent(socket)

      assert :ok = Socket.subscribe(socket, "level2", ["BTC-USD"], @credentials)

      assert_receive {:sent, %{frame: {:text, text}}}, 5_000
      assert is_binary(text)
      # A JWT's header is Base64 of `{"`, which always starts `eyJ`.
      refute text =~ "eyJ"
      assert text =~ "redacted"
    end
  end

  describe "a socket that stops" do
    test "answers a send still queued, so the frame is not left in its crash report" do
      Process.flag(:trap_exit, true)
      {listen_socket, port} = listen()
      serve(listen_socket, [&upgrade_then_hold/1])

      {:ok, socket} = Socket.start_link(socket_opts(port))
      assert_receive {:dp_exchange, :coinbase, %Notice{kind: :link_up}}, 10_000

      # A silence check whose clock reading is gone: the callback raises, which is a crash.
      trigger = make_ref()

      :sys.replace_state(socket, fn state ->
        %{state | silence_check: trigger, last_frame_at: nil}
      end)

      # Suspended, so the crash trigger is in the mailbox BEFORE the frame, and the frame is
      # still queued when the socket goes down.
      :ok = :sys.suspend(socket)
      send(socket, {:silence_check, trigger})
      frame = {:text, "eyJ-queued-frame"}
      sender = Task.async(fn -> FrameSender.send(socket, frame, "test") end)
      wait_for_queue(socket, 2)
      :ok = :sys.resume(socket)

      assert {:error, %WebSockex.NotConnectedError{connection_state: :closing}} =
               Task.await(sender, 10_000)

      assert_receive {:EXIT, ^socket, {%ArithmeticError{}, _stacktrace}}, 10_000
    end
  end

  describe "a url the socket refuses" do
    test "is not echoed into the error" do
      url = "ftp://user:hunter2-secret@example.invalid/feed?token=hunter2-secret"

      result = Socket.start_link(url: url, subscriber: self())

      assert result == {:error, {:invalid_url, :coinbase}}
      refute inspect(result) =~ "hunter2"
    end
  end

  describe "credentials that are not a map" do
    test "are refused by name, without the value" do
      secrets = [
        "hunter2-secret",
        [api_secret: "hunter2-secret"],
        {:key, "hunter2-secret"}
      ]

      for secret <- secrets do
        error = assert_raise ArgumentError, fn -> Credentials.wrap(secret) end
        refute Exception.message(error) =~ "hunter2"
      end
    end

    test "fail the start of a feed with an error that does not carry them" do
      Process.flag(:trap_exit, true)
      name = :"feed_#{System.unique_integer([:positive])}"

      result = Feed.start_link(name: name, credentials: "hunter2-secret")

      assert {:error, {%ArgumentError{}, _stacktrace}} = result
      refute inspect(result) =~ "hunter2"
    end
  end

  describe "a trade decoded from a frame" do
    test "keeps nothing of the frame it came from" do
      state = %{
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

      payload = %{
        "channel" => "market_trades",
        "sequence_num" => 1,
        "events" => [
          %{
            "type" => "update",
            "trades" => [
              %{
                "product_id" => "BTC-USD",
                "trade_id" => "1101555350",
                "price" => "100.5",
                "size" => "0.01",
                "time" => "2026-10-02T12:00:00.123456Z",
                "side" => "BUY",
                "padding" => @padding
              }
            ]
          }
        ]
      }

      assert {:ok, _state} = Socket.handle_frame({:text, Jason.encode!(payload)}, state)

      assert_received {:dp_exchange, :coinbase, %Types.Trade{id: id, symbol: symbol}}
      assert id == "1101555350"
      assert :binary.referenced_byte_size(id) < 1_000
      assert :binary.referenced_byte_size(symbol) < 1_000
    end
  end

  # Handlers run in the emitting process, so filtering on the socket's pid keeps other async
  # tests' frames out.
  defp attach_sent(socket) do
    test_pid = self()
    id = "websockex-sent-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:websockex, :frame, :sent],
      fn _event, _measurements, metadata, socket_pid ->
        if self() == socket_pid, do: send(test_pid, {:sent, metadata})
      end,
      socket
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp wait_for_queue(socket, count, waited \\ 0) do
    {:message_queue_len, queued} = Process.info(socket, :message_queue_len)

    cond do
      queued >= count ->
        :ok

      waited >= 5_000 ->
        flunk("the socket's mailbox held #{queued} messages after #{waited}ms, wanted #{count}")

      true ->
        Process.sleep(5)
        wait_for_queue(socket, count, waited + 5)
    end
  end

  defp listen do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(listen_socket) end)
    {:ok, port} = :inet.port(listen_socket)
    {listen_socket, port}
  end

  # Each handler serves one accepted connection, in order.
  defp serve(listen_socket, handlers) do
    server =
      spawn(fn ->
        Enum.each(handlers, fn handler ->
          {:ok, client_socket} = :gen_tcp.accept(listen_socket, 10_000)
          handler.(client_socket)
        end)
      end)

    on_exit(fn -> Process.exit(server, :kill) end)
  end

  # Upgrades, then reads and ignores whatever the client sends until it closes.
  defp upgrade_then_hold(socket) do
    upgrade(socket)
    hold(socket)
  end

  defp hold(socket) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, _data} -> hold(socket)
      {:error, _closed} -> :ok
    end
  end

  defp upgrade(socket) do
    {:ok, request} = recv_until_headers_end(socket, "")

    :ok =
      :gen_tcp.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Accept: #{accept_header(request)}\r\n\r\n"
      )
  end

  defp recv_until_headers_end(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      case :gen_tcp.recv(socket, 0, 5_000) do
        {:ok, data} -> recv_until_headers_end(socket, acc <> data)
        {:error, _reason} = error -> error
      end
    end
  end

  defp accept_header(request) do
    [_full_match, key] = Regex.run(~r/Sec-WebSocket-Key:\s*(\S+)/i, request)

    :sha
    |> :crypto.hash(key <> @handshake_guid)
    |> Base.encode64()
  end
end

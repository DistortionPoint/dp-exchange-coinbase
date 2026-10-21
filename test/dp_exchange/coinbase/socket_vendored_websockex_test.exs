defmodule DpExchange.Coinbase.SocketVendoredWebSockexTest do
  @moduledoc """
  The two defects `DpExchange.Coinbase.Vendor.WebSockex` exists to fix, each driven through
  a real `Socket.start_link/1` against a real TCP server on `127.0.0.1`. Tier 1, no network:
  a unit call to a callback cannot show that the library driving it does not stall or raise
  first.

    * **The opening handshake has a deadline**, `socket_connect_timeout` plus
      `socket_recv_timeout`. websockex 0.5.1 bounds each `recv` of the upgrade response
      separately and every chunk restarts that timer, so a peer that trickled the response
      held a start or a reconnect open indefinitely. Measured 2026-09-27: this module's
      `start_link/1` against a server sending one byte every 200 ms was still connecting
      at 12 s.
    * **A malformed close frame disconnects instead of crashing.** websockex 0.5.1's
      `websocket_loop/3` has no clause for `WebSockex.Frame.parse_frame/1`'s own error
      return, so a close frame with an invalid status code raised `CaseClauseError` before
      `handle_disconnect/2` could run. Measured live on Webull; the defect is websockex's.
    * **A frame has a size bound.** The length a header announces is the peer's word, and
      websockex 0.5.1 held every chunk until that many bytes had arrived. A frame, or a
      fragmented message, past `:max_frame_bytes` is closed with status 1009 instead.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Socket
  alias DpExchange.Core.Notice

  @moduletag :capture_log

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  # 200 + 300: the deadline under test is 500 ms.
  @timeouts [socket_connect_timeout: 200, socket_recv_timeout: 300]

  # FIN + close, length 10, "bye-bye!!!": the first two bytes are no valid close code.
  @malformed_close_frame <<136, 10, 98, 121, 101, 45, 98, 121, 101, 33, 33, 33>>

  test "a start whose upgrade response trickles in fails at the deadline" do
    {listen_socket, port} = listen()
    serve(listen_socket, [&trickle/1])

    task = Task.async(fn -> Socket.start_link(socket_opts(port)) end)

    # Without the deadline this call does not return at all, so the yield is what fails.
    # No tighter wall-clock bound: under a loaded suite 500 ms of deadline measured 3.6 s
    # end to end, and returning at all is the property under test.
    assert {:ok, {:error, %WebSockex.ConnError{original: :timeout}}} =
             Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
  end

  test "a reconnect whose upgrade response trickles in fails at the deadline and retries" do
    test_pid = self()
    {listen_socket, port} = listen()

    serve(listen_socket, [
      &upgrade_then_close/1,
      &trickle/1,
      fn socket ->
        send(test_pid, :third_connection)
        :gen_tcp.close(socket)
      end
    ])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    # The first reconnect trickles. Only a deadline ends it, and only then can the socket
    # make its next attempt: attempt 2 waits one second of backoff, so this lands at about
    # 1.5 s. Without the deadline it never arrives.
    assert_receive :third_connection, 10_000
  end

  test "a malformed close frame disconnects cleanly instead of crashing the socket" do
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade_then_send_malformed_close/1])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    # `handle_disconnect/2` ran: it is what sends `:link_down`. Upstream crashed first.
    assert_receive {:dp_exchange, :coinbase, %Notice{kind: :link_down, details: details}},
                   10_000

    assert details.reason == :disconnected
    assert details.message =~ "invalid_close_code"
    assert Process.alive?(socket_pid)
  end

  test "a large frame delivered in hundreds of chunks is decoded whole, and the next one too" do
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade_then_send_chunked/1])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port))
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    # The frame is valid JSON only if every one of its ~400 KB arrived and was joined in
    # order: a lost or reordered chunk would be a `:data_quality` notice, never this one.
    assert_receive {:dp_exchange, :coinbase,
                    %Notice{kind: :credentials_rejected, message: message}},
                   10_000

    assert String.length(message) == 1_024
    assert String.starts_with?(message, "authentication failure")

    # A small frame straight behind the large one: the buffer carried on correctly.
    assert_receive {:dp_exchange, :coinbase,
                    %Notice{kind: :credentials_rejected, message: "unauthorized after"}},
                   10_000
  end

  # Vendored fix 7: the length a frame header announces is the peer's word. websockex 0.5.1
  # held every chunk until the announced last byte arrived, so a header announcing four
  # gigabytes held whatever followed for as long as the peer sent it.
  test "a frame announcing more than the bound is closed with 1009, not held" do
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade_then_announce_four_gigabytes/1])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port) ++ [max_frame_bytes: 2_000])
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    # `handle_disconnect/2` ran, with this side's own close as the reason. Held, the socket
    # would still be waiting for the other 4 GB and no notice would come.
    assert_receive {:dp_exchange, :coinbase, %Notice{kind: :link_down, details: details}},
                   10_000

    assert details.reason == :disconnected
    assert details.message =~ "frame too large"
    assert Process.alive?(socket_pid)
  end

  test "a fragmented message that grows past the bound is closed with 1009" do
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade_then_send_oversized_fragments/1])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port) ++ [max_frame_bytes: 2_000])
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    assert_receive {:dp_exchange, :coinbase, %Notice{kind: :link_down, details: details}},
                   10_000

    assert details.message =~ "too large"
    assert Process.alive?(socket_pid)
  end

  test "many small frames in one read are not mistaken for one large frame" do
    {listen_socket, port} = listen()
    serve(listen_socket, [&upgrade_then_send_backlog/1])

    {:ok, socket_pid} = Socket.start_link(socket_opts(port) ++ [max_frame_bytes: 2_000])
    on_exit(fn -> if Process.alive?(socket_pid), do: Process.exit(socket_pid, :kill) end)

    # 100 frames of ~40 bytes arrive together: 4 KB in the buffer, twice the bound, and every
    # frame is whole. All 100 are decoded and none closes the connection.
    for _frame <- 1..100 do
      assert_receive {:dp_exchange, :coinbase,
                      %Notice{kind: :credentials_rejected, message: "unauthorized backlog"}},
                     10_000
    end

    refute_receive {:dp_exchange, :coinbase, %Notice{kind: :link_down}}
  end

  test "a wss peer whose certificate nothing trusts is refused" do
    # websockex's own default is `verify: :verify_none`. Against this server, the TLS
    # handshake used to complete and the upgrade request went out.
    key = [key: {:rsa, 2048, 65_537}]

    %{server_config: server} =
      :public_key.pkix_test_data(%{
        server_chain: %{root: key, intermediates: [], peer: key},
        client_chain: %{root: key, intermediates: [], peer: key}
      })

    {:ok, listen_socket} = :ssl.listen(0, [:binary, active: false, reuseaddr: true] ++ server)
    on_exit(fn -> :ssl.close(listen_socket) end)
    {:ok, {_address, port}} = :ssl.sockname(listen_socket)
    test_pid = self()

    spawn(fn ->
      {:ok, transport} = :ssl.transport_accept(listen_socket, 10_000)
      send(test_pid, {:server_handshake, elem(:ssl.handshake(transport, 5_000), 0)})
    end)

    # Generous timeouts: this asserts a TLS refusal, and a 2048-bit RSA handshake on a loaded
    # machine can outlast the 500 ms handshake deadline the other tests here use.
    opts =
      socket_opts(port)
      |> Keyword.merge(url: "wss://localhost:#{port}/", socket_connect_timeout: 10_000)
      |> Keyword.put(:socket_recv_timeout, 10_000)

    assert {:error, %WebSockex.ConnError{original: {:tls_alert, _alert}}} =
             Socket.start_link(opts)

    assert_receive {:server_handshake, :error}, 5_000
  end

  defp socket_opts(port), do: [url: "ws://127.0.0.1:#{port}/", subscriber: self()] ++ @timeouts

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

  defp trickle(socket) do
    {:ok, _request} = recv_until_headers_end(socket, "")
    :ok = :gen_tcp.send(socket, "HTTP/1.1 101 Switching Protocols\r\n")
    drip(socket)
  end

  # One byte every 100 ms, which restarts a per-`recv` timer of 300 ms forever. Stops when
  # the client closes, which is what the deadline does.
  defp drip(socket) do
    case :gen_tcp.send(socket, "X") do
      :ok ->
        Process.sleep(100)
        drip(socket)

      {:error, _closed} ->
        :ok
    end
  end

  defp upgrade_then_close(socket) do
    upgrade(socket)
    :gen_tcp.close(socket)
  end

  defp upgrade_then_send_malformed_close(socket) do
    upgrade(socket)
    :ok = :gen_tcp.send(socket, @malformed_close_frame)
    # Waits for the client to tear down, so the close cannot race the frame.
    _client_closed = :gen_tcp.recv(socket, 0, 5_000)
    :gen_tcp.close(socket)
  end

  # A ~400 KB text frame (64-bit length form) sent as 400 chunks of 1 KB with a pause between
  # them, so they arrive as separate TCP reads; then one small frame, in the same breath as
  # the last chunk.
  defp upgrade_then_send_chunked(socket) do
    upgrade(socket)
    :ok = :inet.setopts(socket, nodelay: true)

    padding = String.duplicate("x", 400 * 1_024)
    large = Jason.encode!(%{"type" => "error", "message" => "authentication failure " <> padding})
    small = Jason.encode!(%{"type" => "error", "message" => "unauthorized after"})

    large_frame = <<0x81, 127, byte_size(large)::64, large::binary>>
    small_frame = <<0x81, byte_size(small), small::binary>>

    {init, [last]} = large_frame |> chunk_binary(1_024) |> Enum.split(-1)

    for chunk <- init do
      :ok = :gen_tcp.send(socket, chunk)
      Process.sleep(1)
    end

    :ok = :gen_tcp.send(socket, last <> small_frame)

    # Waits for the client to tear down, so the close cannot race the frames.
    _client_closed = :gen_tcp.recv(socket, 0, 15_000)
    :gen_tcp.close(socket)
  end

  # A text frame whose 64-bit length announces 4 GB, followed by 1,500 bytes of it.
  defp upgrade_then_announce_four_gigabytes(socket) do
    upgrade(socket)
    :ok = :gen_tcp.send(socket, <<0x81, 127, 4_000_000_000::64>> <> String.duplicate("x", 1_500))

    # Waits for the client's close frame, so the close cannot race the header.
    await_client_close(socket)
    :gen_tcp.close(socket)
  end

  # Waits for the client's CLOSE frame, not for any byte. Every connection opens with the
  # client's heartbeat subscribe, so a bare `recv` returned on that frame and the server then
  # closed the socket at once: the client's own 1009 close failed to send (`:closed`) and
  # reported `{:remote, :closed}`, and a burst test saw a `:link_down` that this server caused.
  defp await_client_close(socket, acc \\ <<>>) do
    case :gen_tcp.recv(socket, 0, 15_000) do
      {:ok, data} ->
        acc = acc <> data
        if client_closed?(acc), do: :ok, else: await_client_close(socket, acc)

      {:error, _closed} ->
        :ok
    end
  end

  # Client frames are masked. Walks the whole frames received so far (every one here is under
  # 126 bytes) and says whether any is a close (opcode 8).
  defp client_closed?(<<0x88, _rest::binary>>), do: true

  defp client_closed?(<<_fin_opcode, 1::1, len::7, _mask::32, rest::binary>>)
       when len < 126 and byte_size(rest) >= len do
    <<_payload::binary-size(len), more::binary>> = rest
    client_closed?(more)
  end

  defp client_closed?(_partial_or_empty), do: false

  # The start of a fragmented text message and its first continuation, 1,500 bytes each (FIN
  # clear on both). Each frame is under the 2,000-byte bound; the message is not once the
  # second arrives. A pause between them keeps them in separate reads.
  defp upgrade_then_send_oversized_fragments(socket) do
    upgrade(socket)
    :ok = :inet.setopts(socket, nodelay: true)
    payload = String.duplicate("x", 1_500)

    :ok = :gen_tcp.send(socket, <<0x01, 126, 1_500::16>> <> payload)
    Process.sleep(200)
    :ok = :gen_tcp.send(socket, <<0x00, 126, 1_500::16>> <> payload)

    await_client_close(socket)
    :gen_tcp.close(socket)
  end

  # 100 whole frames in one write: more bytes than the bound, none of them an incomplete frame.
  defp upgrade_then_send_backlog(socket) do
    upgrade(socket)
    body = Jason.encode!(%{"type" => "error", "message" => "unauthorized backlog"})
    frame = <<0x81, byte_size(body), body::binary>>
    :ok = :gen_tcp.send(socket, String.duplicate(frame, 100))

    await_client_close(socket)
    :gen_tcp.close(socket)
  end

  defp chunk_binary(binary, size) when byte_size(binary) <= size, do: [binary]

  defp chunk_binary(binary, size) do
    <<chunk::binary-size(size), rest::binary>> = binary
    [chunk | chunk_binary(rest, size)]
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

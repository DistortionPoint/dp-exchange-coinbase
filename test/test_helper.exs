# Tier 2 hits Coinbase's live public API. Excluded by default and run by hand: a venue
# that sees a package polling it on a timer will rate-limit or block.
ExUnit.start(exclude: [:tier2])

# **Tier 1 never reaches a venue, and this makes that a fact rather than a convention.** A
# request that brings no `:plug` of its own gets this one, which refuses it and names the
# host. Measured 2026-09-27: a tier-1 run opened a real connection to a venue, from a test
# that had forgotten its stub. Nothing failed, because the venue answered. Not installed
# for a tier-2 run (`mix test --only tier2`), which is the one place the live API is meant.
tier2_run? =
  ExUnit.configuration()
  |> Keyword.get(:include, [])
  |> Enum.any?(&(&1 == :tier2 or match?({:tier2, _value}, &1)))

require Logger

unless tier2_run? do
  Req.default_options(
    plug: fn conn ->
      message =
        "NETWORK-GUARD: a tier-1 test sent #{conn.method} #{conn.host}#{conn.request_path} " <>
          "to the network. Give the call its own `plug:`."

      Logger.error(message)
      raise message
    end
  )
end

# **A quiet venue on loopback, standing in for the real one.** Every socket a test does not
# aim elsewhere dials `:websocket_url` (see `DpExchange.Coinbase.Socket`'s
# `default_endpoint/0`). Until 2026-09-27 that was the live venue, and sixteen tier-1 tests
# only passed because Coinbase accepted the connection. This server accepts every upgrade
# and then says nothing, the shape of a venue with no trades, so those tests keep a
# connected socket without a byte leaving the machine. It lives for the whole run.
defmodule DpExchange.Coinbase.TestSupport.QuietVenue do
  @moduledoc false

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @spec start() :: :inet.port_number()
  def start do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, packet: :raw, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)
    spawn(fn -> accept_loop(listen) end)
    port
  end

  defp accept_loop(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        handler = spawn(fn -> receive(do: (:go -> serve(socket))) end)
        :ok = :gen_tcp.controlling_process(socket, handler)
        send(handler, :go)
        accept_loop(listen)

      {:error, _closed} ->
        :ok
    end
  end

  defp serve(socket) do
    with {:ok, request} <- recv_headers(socket, ""),
         [_whole, key] <- Regex.run(~r/Sec-WebSocket-Key:\s*(\S+)/i, request) do
      accept = :sha |> :crypto.hash(key <> @handshake_guid) |> Base.encode64()

      :gen_tcp.send(
        socket,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Accept: #{accept}\r\n\r\n"
      )

      drain(socket)
    end
  end

  defp recv_headers(socket, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      with {:ok, data} <- :gen_tcp.recv(socket, 0), do: recv_headers(socket, acc <> data)
    end
  end

  defp drain(socket) do
    case :gen_tcp.recv(socket, 0) do
      {:ok, _frame} -> drain(socket)
      {:error, _closed} -> :gen_tcp.close(socket)
    end
  end
end

Application.put_env(
  :dp_exchange_coinbase,
  :websocket_url,
  "ws://127.0.0.1:#{DpExchange.Coinbase.TestSupport.QuietVenue.start()}/"
)

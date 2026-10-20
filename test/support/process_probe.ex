defmodule DpExchange.Coinbase.ProcessProbe do
  @moduledoc """
  The processes of this venue that hold a credential, started with no outside network, for
  conformance group 51 (`process_probe:` of `DpExchange.Core.AdapterContract`).

  The group renders `:sys.get_status/2` of each pid, which is what OTP prints in a crash
  report, and fails if the canary it handed in is in it. It covers:

    * the tree's `DpExchange.Coinbase.Supervisor`, whose child specs carry the start options
      (the credentials are wrapped before they get there);
    * its `Feed`, which holds the credentials for the life of the process;
    * its `FeedLedger`, which must hold none;
    * a `Socket`, connected to a loopback WebSocket server this module stands up in-process.

  The group's map has string keys (`"api_key"`); this venue reads atoms, so they are converted
  here. A map the venue ignored would prove nothing.
  """

  alias DpExchange.Coinbase.Socket
  alias DpExchange.Coinbase.Supervisor, as: VenueSupervisor

  @handshake_guid "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

  @doc """
  Starts the tree and one socket from `secrets`; answers `{:ok, [pid]}`.
  """
  @spec start(map()) :: {:ok, [pid()]} | {:error, term()}
  def start(secrets) do
    credentials = Map.new(secrets, fn {key, value} -> {to_atom(key), value} end)
    name = :"process_probe_#{System.unique_integer([:positive])}"

    opts = [
      name: name,
      credentials: credentials,
      channels: [:quotes],
      alias_map_source: fn -> {:ok, %{}} end
    ]

    with {:ok, tree} <- VenueSupervisor.start_link(opts),
         {:ok, socket} <- start_socket(credentials) do
      feed = Process.whereis(VenueSupervisor.feed_name(opts))
      ledger = Process.whereis(VenueSupervisor.ledger_name(opts))

      if is_pid(feed) and is_pid(ledger),
        do: {:ok, [tree, feed, ledger, socket]},
        else: {:error, {:tree_not_running, name}}
    end
  end

  defp to_atom(key) when is_atom(key), do: key
  defp to_atom(key) when is_binary(key), do: String.to_atom(key)

  defp start_socket(credentials) do
    listen_opts = [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]
    {:ok, listen} = :gen_tcp.listen(0, listen_opts)

    {:ok, port} = :inet.port(listen)
    spawn(fn -> serve(listen) end)

    Socket.start_link(
      url: "ws://127.0.0.1:#{port}/",
      subscriber: self(),
      credentials: credentials,
      socket_connect_timeout: 5_000,
      socket_recv_timeout: 5_000
    )
  end

  # Upgrades one connection and reads whatever the client sends until it closes.
  defp serve(listen) do
    {:ok, client} = :gen_tcp.accept(listen, 10_000)
    {:ok, request} = recv_headers(client, "")

    :ok =
      :gen_tcp.send(
        client,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Accept: #{accept_header(request)}\r\n\r\n"
      )

    hold(client)
  end

  defp hold(client) do
    case :gen_tcp.recv(client, 0, 60_000) do
      {:ok, _data} -> hold(client)
      {:error, _closed} -> :ok
    end
  end

  defp recv_headers(client, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      with {:ok, data} <- :gen_tcp.recv(client, 0, 5_000), do: recv_headers(client, acc <> data)
    end
  end

  defp accept_header(request) do
    [_full_match, key] = Regex.run(~r/Sec-WebSocket-Key:\s*(\S+)/i, request)

    :sha
    |> :crypto.hash(key <> @handshake_guid)
    |> Base.encode64()
  end
end

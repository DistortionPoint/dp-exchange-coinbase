defmodule DpExchange.Coinbase.Feed do
  @moduledoc """
  This venue's subscription lifecycle — internal. The facade's `subscribe/2`,
  `unsubscribe/2`, `update_symbols/2` and `coverage/1` are served from here.

  ## What a consumer can and cannot learn

  A consumer learns *what is arriving*, through `coverage/1`. It cannot learn how: this
  module owns the socket, the sharding and the pacing, and none of that reaches the
  facade.

  ## Coverage is observed, never intended

  A symbol enters the coverage map when **a payload for it arrives**, never when it is
  subscribed. That distinction is the strongest guarantee in the contract and it exists
  because a venue once reported 325 symbols subscribed and confirmed while 174 were
  delivering. Reporting the subscription would have said 325.

  A symbol that has been subscribed and has delivered nothing is simply absent, which the
  facade documents as `:not_covered`.

  ## Sharding

  Coinbase carries its whole subscription on one connection. That is measured, not
  assumed: once its self-killing heartbeat was fixed it subscribed 401 of 401 pairs on a
  single socket, and sharding it anyway opened 14 connections for no gain.

  So there is no shard arithmetic here. A venue that needs it — one whose socket stops
  accepting subscribes after about ten pairs — adds it in *its* package, where the
  measurement lives.
  """

  use GenServer

  alias DpExchange.Coinbase.Socket
  alias DpExchange.Core.Notice

  require Logger

  @channel "ticker"

  # WebSockex's own send window, which is not configurable.
  @frame_window_ms 5_000

  # Derived from the most frames one call can send, not guessed.
  #
  # `WebSockex.send_frame/2` blocks for up to `@frame_window_ms` before the guard can
  # turn its exit into a return, and that wait happens inside `handle_call/3`. With
  # `GenServer.call`'s five-second default the two race, and the caller times out first —
  # so a slow socket surfaces as a caller-side exit instead of the
  # `{:error, :send_timeout}` the guard exists to produce, losing the one piece of
  # information that says "retry the batch" rather than "the venue is gone".
  #
  # `update_symbols/2` is the worst case: it can send an unsubscribe *and* a subscribe,
  # so a single call can wait out **two** windows. The third is headroom, because a
  # timeout here manufactures exactly the failure the guard was written to prevent.
  @call_timeout @frame_window_ms * 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec subscribe(GenServer.server(), [String.t()], keyword()) :: :ok | {:error, term()}
  def subscribe(feed \\ __MODULE__, symbols, opts \\ []) do
    GenServer.call(feed, {:subscribe, symbols, Keyword.get(opts, :to, self())}, @call_timeout)
  end

  @spec unsubscribe(GenServer.server(), [String.t()]) :: :ok | {:error, term()}
  def unsubscribe(feed \\ __MODULE__, symbols),
    do: GenServer.call(feed, {:unsubscribe, symbols}, @call_timeout)

  @spec update_symbols(GenServer.server(), [String.t()]) :: :ok | {:error, term()}
  def update_symbols(feed \\ __MODULE__, symbols),
    do: GenServer.call(feed, {:update_symbols, symbols}, @call_timeout)

  @spec coverage(GenServer.server()) :: %{String.t() => :stream | :internal_poll | :not_covered}
  def coverage(feed \\ __MODULE__), do: GenServer.call(feed, :coverage)

  @spec subscribe_notices(GenServer.server(), keyword()) :: :ok
  def subscribe_notices(feed \\ __MODULE__, opts \\ []),
    do: GenServer.call(feed, {:subscribe_notices, Keyword.get(opts, :to, self())})

  # --- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok,
     %{
       credentials: Keyword.get(opts, :credentials),
       socket_opts: Keyword.take(opts, [:url]),
       # An already-established connection. Ordinary use leaves this nil and the feed
       # dials its own on first subscribe; it is set on a reconnect, and by tests that
       # need the socket-bearing branches without reaching a venue.
       socket: Keyword.get(opts, :socket),
       subscribers: MapSet.new(),
       notice_subscribers: MapSet.new(),
       wanted: MapSet.new(),
       delivering: %{}
     }}
  end

  @impl true
  def handle_call({:subscribe, symbols, subscriber}, _from, state) do
    state = %{
      state
      | subscribers: MapSet.put(state.subscribers, subscriber),
        wanted: MapSet.union(state.wanted, MapSet.new(symbols))
    }

    case ensure_socket(state) do
      {:ok, state} ->
        {:reply, Socket.subscribe(state.socket, @channel, symbols, state.credentials), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:unsubscribe, symbols}, _from, %{socket: nil} = state) do
    {:reply, :ok, drop(state, symbols)}
  end

  def handle_call({:unsubscribe, symbols}, _from, state) do
    result = Socket.unsubscribe(state.socket, @channel, symbols)
    {:reply, result, drop(state, symbols)}
  end

  def handle_call({:update_symbols, symbols}, _from, state) do
    wanted = MapSet.new(symbols)
    added = MapSet.difference(wanted, state.wanted) |> MapSet.to_list()
    removed = MapSet.difference(state.wanted, wanted) |> MapSet.to_list()

    state = %{state | wanted: wanted, delivering: Map.take(state.delivering, symbols)}

    result =
      cond do
        is_nil(state.socket) -> :ok
        removed != [] -> Socket.unsubscribe(state.socket, @channel, removed)
        true -> :ok
      end

    result =
      if added != [] and state.socket,
        do: Socket.subscribe(state.socket, @channel, added, state.credentials),
        else: result

    {:reply, result, state}
  end

  def handle_call(:coverage, _from, state) do
    # Only what arrived. A subscribed symbol that has delivered nothing is absent, and
    # the facade documents absence as `:not_covered`.
    {:reply, Map.new(state.delivering, fn {symbol, _at} -> {symbol, :stream} end), state}
  end

  def handle_call({:subscribe_notices, subscriber}, _from, state) do
    {:reply, :ok, %{state | notice_subscribers: MapSet.put(state.notice_subscribers, subscriber)}}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_call}, state}

  @impl true
  def handle_info({:dp_exchange, :coinbase, %Notice{} = notice}, state) do
    fan_out(state.notice_subscribers, {:dp_exchange, :coinbase, notice})
    {:noreply, state}
  end

  def handle_info({:dp_exchange, :coinbase, quote_struct} = message, state) do
    fan_out(state.subscribers, message)

    {:noreply,
     %{
       state
       | delivering: Map.put(state.delivering, quote_struct.symbol, :os.system_time(:millisecond))
     }}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp ensure_socket(%{socket: socket} = state) when is_pid(socket), do: {:ok, state}

  defp ensure_socket(state) do
    opts = Keyword.merge(state.socket_opts, subscriber: self(), credentials: state.credentials)

    case Socket.start_link(opts) do
      {:ok, socket} -> {:ok, %{state | socket: socket}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp drop(state, symbols) do
    %{
      state
      | wanted: MapSet.difference(state.wanted, MapSet.new(symbols)),
        delivering: Map.drop(state.delivering, symbols)
    }
  end

  # A dead subscriber stops delivery. The venue must not accumulate events for a process
  # that no longer exists.
  defp fan_out(subscribers, message) do
    Enum.each(subscribers, fn pid -> if Process.alive?(pid), do: send(pid, message) end)
  end
end

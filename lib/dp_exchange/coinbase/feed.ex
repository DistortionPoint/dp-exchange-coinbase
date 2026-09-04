defmodule DpExchange.Coinbase.Feed do
  @moduledoc """
  This venue's subscription lifecycle — internal. The facade's `subscribe/2`,
  `unsubscribe/2`, `update_symbols/2` and `coverage/1` are served from here.

  ## What a consumer can and cannot learn

  A consumer learns *what is arriving*, through `coverage/1`. It cannot learn how: this
  module owns the sockets, the sharding and the pacing, and none of that reaches the
  facade.

  ## Coverage is observed, never intended

  A symbol enters the coverage map when **a payload for it arrives**, never when it is
  subscribed. That distinction is the strongest guarantee in the contract and it exists
  because a venue once reported 325 symbols subscribed and confirmed while 174 were
  delivering. Reporting the subscription would have said 325.

  A symbol that has been subscribed and has delivered nothing is simply absent, which the
  facade documents as `:not_covered`.

  ## Sharded — this used to run on one connection, and that stopped being true

  This venue's whole scope used to run on a single socket, and that was measured: once
  its self-killing heartbeat was fixed it subscribed 401 of 401 pairs on one connection,
  and sharding it anyway opened fourteen connections for no gain.

  **That stopped being true on 2026-08-26.** Coinbase started answering a `level2`
  subscribe over its per-session limit with `"too many L2 streams requested in a single
  session"`, closing the socket — a total data gap, not degraded coverage: measured
  2026-08-27 against a real ~400-symbol universe, 355 of 405 pairs went stale and 1,480
  refusals were logged in one window. The measurement about one socket being enough was
  honest when it was taken; it stopped being true the moment the venue's own limit did.

  `@pairs_per_socket` is **100**, carried over from the reference fix this replaces
  rather than re-derived — the number came from a real production incident, not this
  package's own probing, and is recorded as such rather than presented as freshly
  measured.

  ## `level2` before `ticker`, on the same socket

  Each shard's socket carries both channels for its own slice of symbols, `level2`
  subscribed first: it is what takes a shard from partial to full coverage, and
  subscribing it before the lighter channel means the book is already flowing by the
  time `ticker` adds its own load. The two are spaced apart on the wire — a `level2`
  subscribe triggers a full per-symbol book snapshot, and firing `ticker`'s subscribe
  into a socket still decoding that arrives as a `send_timeout` and can take the
  connection down with it.

  ## A reconnect that does not resubscribe is a coverage collapse with no error

  WebSockex reconnects a dropped socket on its own, and a bare reconnect leaves it
  connected and subscribed to **nothing** — silently, because a socket that is up and
  receiving nothing is not itself an error. That is a real, measured incident on this
  venue's own reference implementation: coverage decayed from full to the REST-poll
  floor over roughly forty minutes with the feed still reporting healthy, because
  nothing re-asked the venue for anything after the reconnect.

  This coordinator re-issues every shard's subscriptions on a timer, unconditionally.
  Re-subscribing a channel the socket already carries costs one frame the venue ignores;
  not re-subscribing one it silently dropped costs the shard's whole coverage until
  someone notices a quiet chart.

  ## Every shard beyond the first must open on its own tick, not the same one

  `@shard_spacing_ms` staggers shard opens **relative to each other**, not relative to a
  fixed instant. A scope wide enough to need three or more shards — DpCryptoManagement's
  issue #20, 406 symbols / 5 shards, filed against real production traffic — used to
  schedule every shard past the first (the synchronous one) with the *same* fixed delay,
  so all of them opened in the same instant: exactly the connect burst this module's own
  design note above warns the venue answers with resets. Only the shard whose burst-mate
  connections lost that race ever delivered a tick; coverage sat at whatever fraction of
  one shard survived, indistinguishable from the outside from a quiet market. The
  60-second unconditional resubscribe re-issued the same burst every minute. Both paths
  now schedule each shard's turn `position * @shard_spacing_ms` after the one before it.
  """

  use GenServer

  alias DpExchange.Coinbase.Socket
  alias DpExchange.Core.Notice

  require Logger

  @channels ["level2", "ticker"]

  # See the moduledoc: measured on the venue this package replaces, not on this one.
  @pairs_per_socket 100

  # Between opening each shard's socket. Opening several connections in the same instant
  # is a connect burst the venue answers with resets.
  @shard_spacing_ms 5_000

  # Between a shard's `level2` and `ticker` subscribes on the same socket. `level2`
  # triggers a full snapshot per symbol and the connection is busy decoding it; firing
  # `ticker` on top of that arrives as a `send_timeout`.
  @channel_spacing_ms 8_000

  # Re-issue every shard's current subscriptions on this cadence, unconditionally — see
  # the moduledoc on reconnects.
  @resubscribe_interval_ms 60_000

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
  # `update_symbols/2` is the worst case: it can send an unsubscribe *and* a subscribe
  # on each of a symbol's affected shards, so a single call can wait out several windows.
  @call_timeout @frame_window_ms * 3

  @spec pairs_per_socket() :: pos_integer()
  def pairs_per_socket, do: @pairs_per_socket

  @doc "The scope split into one list per socket."
  @spec shards([String.t()]) :: [[String.t()]]
  def shards([]), do: []
  def shards(symbols), do: Enum.chunk_every(symbols, @pairs_per_socket)

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
    Process.send_after(self(), :resubscribe, @resubscribe_interval_ms)

    {:ok,
     %{
       credentials: Keyword.get(opts, :credentials),
       socket_opts: Keyword.take(opts, [:url]),
       # A pre-established connection, consumed the first time any shard opens. Ordinary
       # use leaves this `nil` and the feed dials its own; it is set by tests that need
       # the socket-bearing branches without reaching a venue.
       injected_socket: Keyword.get(opts, :socket),
       # index => %{socket: pid, symbols: [...]}. Populated as shards open; a shard
       # whose socket has not opened yet (still waiting out its `@shard_spacing_ms`
       # delay, or the connect failed) is simply absent — its symbols stay on whatever
       # this package's REST poll answers until the socket comes up.
       shards: %{},
       subscribers: MapSet.new(),
       notice_subscribers: MapSet.new(),
       wanted: MapSet.new(),
       delivering: %{}
     }}
  end

  @impl true
  def handle_call({:subscribe, symbols, subscriber}, _from, state) do
    wanted = MapSet.union(state.wanted, MapSet.new(symbols))
    state = %{state | subscribers: MapSet.put(state.subscribers, subscriber), wanted: wanted}
    {result, state} = reshard(state)
    {:reply, result, state}
  end

  def handle_call({:unsubscribe, symbols}, _from, state) do
    wanted = MapSet.difference(state.wanted, MapSet.new(symbols))
    state = %{state | wanted: wanted, delivering: Map.drop(state.delivering, symbols)}
    {result, state} = reshard(state)
    {:reply, result, state}
  end

  def handle_call({:update_symbols, symbols}, _from, state) do
    wanted = MapSet.new(symbols)
    state = %{state | wanted: wanted, delivering: Map.take(state.delivering, symbols)}
    {result, state} = reshard(state)
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

  def handle_info({:dp_exchange, :coinbase, payload} = message, state) do
    fan_out(state.subscribers, message)

    delivering =
      Map.put(state.delivering, delivered_symbol(payload), :os.system_time(:millisecond))

    {:noreply, %{state | delivering: delivering}}
  end

  def handle_info({:open_shard, index, symbols}, state) do
    case get_socket(state) do
      {:ok, socket, state} ->
        state = put_in(state.shards[index], %{socket: socket, symbols: symbols})
        schedule_channel_subscribes(socket, symbols, state.credentials)
        {:noreply, state}

      {:error, reason} ->
        # Never silent: this shard's symbols keep arriving over whatever REST poll runs
        # beside this feed, but at poll cadence rather than stream cadence, and that
        # difference has to be findable rather than inferred from a quiet chart.
        Logger.warning(
          "[Coinbase Feed] shard #{index} did not open (#{inspect(reason)}) — " <>
            "its #{length(symbols)} symbol(s) stay on the internal poll only"
        )

        {:noreply, state}
    end
  end

  def handle_info({:channel_subscribe, socket, channel, symbols, credentials}, state) do
    if Process.alive?(socket) do
      case Socket.subscribe(socket, channel, symbols, credentials) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Coinbase Feed] #{channel} subscribe for #{length(symbols)} symbol(s) " <>
              "failed: #{inspect(reason)}"
          )
      end
    end

    {:noreply, state}
  end

  def handle_info({:channel_unsubscribe, socket, channel, symbols}, state) do
    if Process.alive?(socket), do: Socket.unsubscribe(socket, channel, symbols)
    {:noreply, state}
  end

  def handle_info(:resubscribe, state) do
    Process.send_after(self(), :resubscribe, @resubscribe_interval_ms)

    # Staggered the same way `reshard/1` staggers opening several new shards: re-issuing
    # every shard's `level2` subscribe in the same instant is the identical connect/subscribe
    # burst the moduledoc warns about, just recurring every minute instead of once at boot.
    state.shards
    |> Enum.sort_by(fn {index, _shard} -> index end)
    |> Enum.with_index()
    |> Enum.each(fn {{_index, %{socket: socket, symbols: symbols}}, position} ->
      if Process.alive?(socket) do
        Process.send_after(
          self(),
          {:resubscribe_shard, socket, symbols, state.credentials},
          position * @shard_spacing_ms
        )
      end
    end)

    {:noreply, state}
  end

  def handle_info({:resubscribe_shard, socket, symbols, credentials}, state) do
    if Process.alive?(socket), do: schedule_channel_subscribes(socket, symbols, credentials)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- internal ------------------------------------------------------------

  # Recomputes shards from `state.wanted` and reconciles: a shard whose symbol set
  # changed gets its socket's subscriptions brought current, a brand-new shard gets a
  # socket opened, and a shard that no longer has any symbols is dropped — its socket is
  # left to WebSockex's own lifecycle rather than torn down here, because a shard
  # reappearing moments later (a common `update_symbols` pattern) should not pay to
  # reopen a connection it only just closed.
  #
  # ## Why exactly one shard is handled synchronously
  #
  # A caller subscribing to ten symbols touches one shard and needs to know, in the
  # reply, whether that connection actually accepted the request — reporting success
  # unconditionally would produce a subscription that never delivers, indistinguishable
  # from a quiet market. A caller whose `update_symbols` spans four hundred symbols
  # touches four shards, and dialling all four inline would block the reply behind
  # `@channel_spacing_ms` several times over and risk a connect burst besides.
  #
  # So: the FIRST shard this call actually touches — the lowest index among the ones
  # newly opened or reconciled — runs inline and its outcome is the call's reply, same
  # as the single-socket design this replaces. Every other shard the same call touches
  # is staggered, exactly as a shard opened by a later, separate call would be.
  defp reshard(state) do
    new_shards =
      state.wanted
      |> MapSet.to_list()
      |> shards()
      |> Enum.with_index()
      |> Map.new(fn {symbols, index} -> {index, symbols} end)

    existing_indices = Map.keys(state.shards)
    wanted_indices = Map.keys(new_shards)
    new_indices = Enum.sort(wanted_indices -- existing_indices)

    # A shard whose whole symbol set was just removed disappears from `new_shards`
    # entirely — nothing above asked for any of its symbols any more. That must still
    # reach the venue as an unsubscribe on every symbol the shard was carrying, or the
    # venue keeps streaming them while this package's own bookkeeping has already
    # forgotten it asked to. Folded into `new_shards` as an explicit empty entry so
    # `reconcile_shard/6`'s ordinary removed-symbols path handles it — the same
    # operation, not a special case.
    vanishing_indices = existing_indices -- wanted_indices
    new_shards = Enum.reduce(vanishing_indices, new_shards, &Map.put(&2, &1, []))

    touched_indices =
      (wanted_indices ++ vanishing_indices)
      |> Enum.filter(fn index ->
        index in new_indices or shard_changed?(state, index, new_shards)
      end)
      |> Enum.sort()

    case touched_indices do
      [] ->
        state = drop_unwanted_shards(state, existing_indices, wanted_indices)
        {:ok, state}

      [primary | rest] ->
        {result, state} = touch_shard(state, primary, new_shards, sync: true, delay: 0)

        state =
          rest
          |> Enum.with_index(1)
          |> Enum.reduce(state, fn {index, position}, acc ->
            {_result, acc} =
              touch_shard(acc, index, new_shards,
                sync: false,
                delay: position * @shard_spacing_ms
              )

            acc
          end)

        state = drop_unwanted_shards(state, existing_indices, wanted_indices)
        {result, state}
    end
  end

  defp shard_changed?(state, index, new_shards) do
    case get_in(state.shards[index]) do
      nil -> false
      %{symbols: current} -> current != Map.fetch!(new_shards, index)
    end
  end

  defp drop_unwanted_shards(state, existing_indices, wanted_indices) do
    %{state | shards: Map.drop(state.shards, existing_indices -- wanted_indices)}
  end

  defp touch_shard(state, index, new_shards, sync: sync?, delay: delay) do
    wanted_symbols = Map.fetch!(new_shards, index)

    case get_in(state.shards[index]) do
      nil ->
        open_shard(state, index, wanted_symbols, sync?, delay)

      %{symbols: current, socket: socket} ->
        reconcile_shard(state, index, socket, current, wanted_symbols, sync?)
    end
  end

  defp open_shard(state, index, symbols, true, _delay) do
    case get_socket(state) do
      {:ok, socket, state} ->
        state = put_in(state.shards[index], %{socket: socket, symbols: symbols})
        result = subscribe_first_channel(socket, symbols, state.credentials)
        schedule_remaining_channel_subscribes(socket, symbols, state.credentials)
        {result, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp open_shard(state, index, symbols, false, delay) do
    Process.send_after(self(), {:open_shard, index, symbols}, delay)
    {:ok, state}
  end

  defp reconcile_shard(state, index, socket, current, wanted, true) do
    added = wanted -- current
    removed = current -- wanted

    result =
      cond do
        not Process.alive?(socket) ->
          :ok

        added != [] ->
          result = subscribe_first_channel(socket, added, state.credentials)
          schedule_remaining_channel_subscribes(socket, added, state.credentials)

          if removed != [],
            do:
              Enum.each(channels_for(state.credentials), &Socket.unsubscribe(socket, &1, removed))

          result

        removed != [] ->
          channels_for(state.credentials)
          |> Enum.map(&Socket.unsubscribe(socket, &1, removed))
          |> List.last()

        true ->
          :ok
      end

    {result, put_in(state.shards[index], %{socket: socket, symbols: wanted})}
  end

  defp reconcile_shard(state, index, socket, current, wanted, false) do
    added = wanted -- current
    removed = current -- wanted

    if removed != [] and Process.alive?(socket) do
      Enum.each(channels_for(state.credentials), fn channel ->
        Process.send_after(self(), {:channel_unsubscribe, socket, channel, removed}, 0)
      end)
    end

    if added != [] and Process.alive?(socket) do
      schedule_channel_subscribes(socket, added, state.credentials)
    end

    {:ok, put_in(state.shards[index], %{socket: socket, symbols: wanted})}
  end

  defp subscribe_first_channel(socket, symbols, credentials) do
    [first | _rest] = channels_for(credentials)
    Socket.subscribe(socket, first, symbols, credentials)
  end

  defp schedule_remaining_channel_subscribes(socket, symbols, credentials) do
    [_first | rest] = channels_for(credentials)

    rest
    |> Enum.with_index(1)
    |> Enum.each(fn {channel, position} ->
      Process.send_after(
        self(),
        {:channel_subscribe, socket, channel, symbols, credentials},
        position * @channel_spacing_ms
      )
    end)
  end

  defp schedule_channel_subscribes(socket, symbols, credentials) do
    credentials
    |> channels_for()
    |> Enum.with_index()
    |> Enum.each(fn {channel, channel_index} ->
      Process.send_after(
        self(),
        {:channel_subscribe, socket, channel, symbols, credentials},
        channel_index * @channel_spacing_ms
      )
    end)
  end

  # `level2` requires credentials — see `@authenticated_channels` in `Socket`. A
  # credential-less caller only ever wanted the public `ticker` channel anyway, and
  # sending a doomed `level2` subscribe would either report a `credentials_required`
  # error as this call's synchronous result (masking that `ticker` will work fine) or
  # cost a wire round trip to learn what the credential's absence already answers.
  defp channels_for(nil), do: ["ticker"]
  defp channels_for(_credentials), do: @channels

  defp get_socket(%{injected_socket: socket} = state) when is_pid(socket) do
    {:ok, socket, %{state | injected_socket: nil}}
  end

  defp get_socket(state) do
    opts = Keyword.merge(state.socket_opts, subscriber: self(), credentials: state.credentials)

    case Socket.start_link(opts) do
      {:ok, socket} -> {:ok, socket, state}
      {:error, reason} -> {:error, reason}
    end
  end

  # `Types.Quote` and `Types.OrderBook` both carry `:symbol`; this is the one place
  # coverage tracking needs to be generic over which kind arrived.
  defp delivered_symbol(%{symbol: symbol}), do: symbol

  # A dead subscriber stops delivery. The venue must not accumulate events for a process
  # that no longer exists.
  #
  # A subscriber may be a raw pid or a registered name — `subscribe/2`'s `to:` accepts
  # either, matching ordinary OTP practice (a consumer registering itself by name and
  # handing that name to a producer). `Process.alive?/1` only accepts a pid and raises on
  # anything else, so a registered-name subscriber crashed this whole GenServer on every
  # delivery. Resolving first, uniformly, fixes both: a dead pid resolves to itself and
  # `Process.alive?/1` filters it; an unregistered name resolves to `nil` and is silently
  # skipped, the same as a dead subscriber already was.
  defp fan_out(subscribers, message) do
    Enum.each(subscribers, fn subscriber ->
      case resolve_subscriber(subscriber) do
        pid when is_pid(pid) -> send(pid, message)
        nil -> :ok
      end
    end)
  end

  defp resolve_subscriber(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid
  end

  defp resolve_subscriber(name) when is_atom(name), do: Process.whereis(name)
end

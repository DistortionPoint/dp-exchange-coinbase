defmodule DpExchange.Coinbase.FeedCase do
  @moduledoc """
  The shared fixtures behind the feed test files, and why there is more than one file.

  `feed_test.exs` used to hold all 127 of them, and at 21.3s it WAS this package's suite —
  the other six hundred tests finished in under five. Its slowest ones are slow on purpose:
  a call that must outlast `GenServer.call/2`'s five-second default, an alias-map fetch that
  must exhaust a retry ladder, a stranded unsubscribe that must survive a failed retry tick.
  None of that waiting can be trimmed without deleting the thing being proved.

  ExUnit parallelises across FILES and serialises within one, so keeping them together made
  every one of those waits run end to end rather than alongside each other. Split four ways
  the suite is paced by its single longest test instead of by their sum.

  Splitting is only worth doing if the files do not drift apart, which is what this template
  is for: one `start_feed/1`, one set of fixtures, one `wait_until/1`. A helper that exactly
  one file uses stays in that file.
  """

  use ExUnit.CaseTemplate

  alias DpExchange.Coinbase.Feed
  alias DpExchange.Core.Types

  using do
    quote do
      import DpExchange.Coinbase.FeedCase

      @moduletag :capture_log
    end
  end

  @doc """
  A feed with a stubbed alias-map source and no socket.

  Real GenServers and real messages. The feed's socket is never started here — these test
  the subscription bookkeeping and the coverage rule, which is where the interesting
  behaviour is and where a venue gets it wrong.
  """
  @spec start_feed(keyword()) :: pid()
  def start_feed(opts \\ []) do
    name = :"feed_#{System.unique_integer([:positive])}"
    start_supervised!({Feed, [name: name, alias_map_source: fn -> {:ok, %{}} end] ++ opts})
  end

  @doc "A minimal quote for `symbol`."
  @spec quote_for(String.t()) :: Types.Quote.t()
  def quote_for(symbol) do
    %Types.Quote{
      symbol: symbol,
      price: Decimal.new("1"),
      venue_time: ~U[2026-08-28 12:00:00Z],
      observed_at: ~U[2026-08-28 12:00:00Z],
      provider: :coinbase
    }
  end

  @doc """
  Polls a condition instead of sleeping a guessed duration.

  `Process.sleep(n)` as a synchronisation device is a bet that some asynchronous work
  finishes within `n` milliseconds on a loaded, `async: true` suite. It passes locally, then
  fails in CI against code that is working correctly — which is strictly worse than having
  no test, because it teaches the reader to distrust the suite. Both of the retry-chain
  tests were written that way and one of them did exactly that.
  """
  @spec wait_until((-> boolean()), non_neg_integer(), non_neg_integer()) :: :ok
  def wait_until(fun, timeout \\ 2_000, waited \\ 0) do
    cond do
      fun.() -> :ok
      waited >= timeout -> flunk("condition was still false after #{timeout}ms")
      true -> Process.sleep(5) && wait_until(fun, timeout, waited + 5)
    end
  end

  @doc """
  A pid that is certainly dead.

  Deterministic instead of `spawn(fn -> :ok end)` plus a guessed sleep: a monitor's `:DOWN`
  message only arrives once the process has genuinely exited, so a "dead socket"/"dead
  subscriber" test never races a scheduler slower than whatever fixed delay was guessed.
  """
  @spec dead_pid() :: pid()
  def dead_pid do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 500
    pid
  end

  @doc "A minimal order book for `symbol`."
  @spec order_book_for(String.t()) :: Types.OrderBook.t()
  def order_book_for(symbol) do
    %Types.OrderBook{
      symbol: symbol,
      bids: [{Decimal.new("1"), Decimal.new("2")}],
      asks: [{Decimal.new("1.1"), Decimal.new("2")}],
      venue_time: ~U[2026-08-28 12:00:00Z],
      observed_at: ~U[2026-08-28 12:00:00Z],
      provider: :coinbase
    }
  end

  @doc """
  A level2 delta for `symbol`.

  What `Socket` now sends for a `level2` `update` frame instead of a rebuilt
  `Types.OrderBook` — see `dp_exchange_core`'s `Types.OrderBookDelta` and this package's own
  `Socket` moduledoc.
  """
  @spec order_book_delta_for(String.t()) :: Types.OrderBookDelta.t()
  def order_book_delta_for(symbol) do
    %Types.OrderBookDelta{
      symbol: symbol,
      levels: [{:bid, Decimal.new("1"), Decimal.new("2")}],
      timestamp: ~U[2026-08-28 12:00:00Z],
      provider: :coinbase
    }
  end

  @doc """
  A feed with a socket already injected, plus the socket double itself.

  The double answers `WebSockex.send_frame/2` immediately with a failure rather than
  stalling: `:gen.call/4` expects a reply, and a socket that never replies makes every send
  sit out the caller timeout, which is a multi-second, load-dependent stall standing in for
  a socket that had already died. The tests here assert only `{:error, _reason}`, never the
  specific reason, so an immediate simulated failure exercises the identical path.
  """
  @spec start_with_socket() :: {pid(), pid()}
  def start_with_socket, do: start_with_socket_and_opts([])

  @doc "As `start_with_socket/0`, with extra options merged into the feed."
  @spec start_with_socket_and_opts(keyword()) :: {pid(), pid()}
  def start_with_socket_and_opts(opts) do
    socket = spawn(&reject_frames_loop/0)
    on_exit(fn -> Process.exit(socket, :kill) end)

    feed =
      start_supervised!(
        {Feed,
         [
           name: :"feed_#{System.unique_integer([:positive])}",
           socket: socket,
           alias_map_source: fn -> {:ok, %{}} end
         ] ++ opts}
      )

    {feed, socket}
  end

  defp reject_frames_loop do
    receive do
      {:"$websockex_send", from, _frame} ->
        :gen.reply(from, {:error, :simulated_socket_failure})

      _other ->
        :ok
    end

    reject_frames_loop()
  end

  @doc """
  A socket double that answers every send successfully.

  `WebSockex.send_frame/2` calls `:gen.call(client, :"$websockex_send", frame, timeout)`,
  which, per the `:gen` protocol, expects the receiver to reply via `:gen.reply/2`.
  Replying immediately, correctly, is what an actually "fake" socket does; sleeping forever
  was standing in for a socket that had already died, not one that was merely slow, and
  there is a separate, dedicated fake (`dead/0`, inline where used) for that case.
  """
  @spec fake_socket() :: pid()
  def fake_socket do
    pid = spawn(&fake_socket_loop/0)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    pid
  end

  defp fake_socket_loop do
    receive do
      {:"$websockex_send", from, _frame} -> :gen.reply(from, :ok)
      _other -> :ok
    end

    fake_socket_loop()
  end
end

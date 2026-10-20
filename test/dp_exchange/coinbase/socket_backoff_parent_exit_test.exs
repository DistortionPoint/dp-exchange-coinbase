defmodule DpExchange.Coinbase.SocketBackoffExitTest do
  @moduledoc """
  A socket waiting out its reconnect backoff is ended at once by an exit signal.

  `Socket.handle_disconnect/2` waits out the backoff (up to 30s) inside the callback. The
  socket process does not trap exits (nothing in `WebSockex` or this package's fork does), so
  the signal `Feed` sends when it retires or stops a shard (`Process.exit(pid, :shutdown)`),
  or the link when `Feed` crashes, kills it mid-sleep and it never dials the venue again. An
  earlier version of this test, and of the code, assumed the process trapped exits and read a
  `{:EXIT, parent, _}` message; that message is never delivered.

  The callback is driven directly, in a process of its own. Tier 1: no socket is opened.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Socket

  @moduletag :capture_log

  # Attempt 7 is at the 30s cap (1s doubling, `@max_reconnect_delay_ms`), and jitter only
  # shortens it to 22.5s at worst. Far longer than any margin below, so only the signal can
  # end the wait in time.
  @capped_attempt 7

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
      connected_at: nil,
      short_sessions: 0
    }
  end

  # Runs `handle_disconnect/2` in its own, non-trapping process and reports that it is about
  # to wait, so the signal this test sends next cannot arrive before the process exists.
  defp start_waiting do
    test_pid = self()
    socket_state = state()
    status = %{reason: :closed, attempt_number: @capped_attempt}

    {pid, ref} =
      spawn_monitor(fn ->
        send(test_pid, {:waiting, self()})
        Socket.handle_disconnect(status, socket_state)
        send(test_pid, {:backoff_finished, self()})
      end)

    assert_receive {:waiting, ^pid}, 5_000
    {pid, ref}
  end

  test "a :shutdown signal ends a socket in its backoff with that reason" do
    {pid, ref} = start_waiting()

    Process.exit(pid, :shutdown)

    assert_receive {:DOWN, ^ref, :process, ^pid, :shutdown}, 5_000
    refute_received {:backoff_finished, ^pid}
  end

  test "the process does not trap exits, so no EXIT message is waiting to be read" do
    {pid, ref} = start_waiting()

    assert {:trap_exit, false} = Process.info(pid, :trap_exit)

    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
  end
end

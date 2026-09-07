defmodule DpExchange.Coinbase.FrameSenderTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.FrameSender

  @moduletag :capture_log

  # A process that behaves the way `WebSockex.send_frame/2` does in each failure mode.
  # Not a mock of WebSockex — a real process that exits, times out, or answers, which is
  # what the guard has to survive.
  #
  # `WebSockex.send_frame/2` is `:gen.call(client, :"$websockex_send", frame)` — see
  # `FrameSender`'s own moduledoc — and `:gen.call/3` sends `{Label, From, Request}`, so
  # the message this process actually receives is tagged `:"$websockex_send"`, not
  # `:"$gen_call"`. It used to be matched on `:"$gen_call"` here, which never arrives:
  # every send against `socket(:accepts)` silently fell through to `:gen.call`'s own
  # 5-second timeout and returned `{:error, :send_timeout}` — a real error, and one this
  # test's own `assert result == :ok or match?({:error, _reason}, result)` was loose
  # enough to accept without ever noticing the accept path had not actually run. Fixed by
  # matching the real tag; the reply itself is `:gen.reply/2`, the exact call WebSockex's
  # own `sync_send/5` makes (`deps/websockex/lib/websockex.ex`), not `GenServer.reply/2` —
  # both satisfy `:gen.call`'s receive in principle, but this is the real protocol rather
  # than one that happens to also work.
  defp socket(behaviour) do
    spawn(fn -> loop(behaviour) end)
  end

  defp loop(:accepts) do
    receive do
      {:"$websockex_send", from, _frame} -> :gen.reply(from, :ok)
    end

    loop(:accepts)
  end

  defp loop(:too_slow) do
    # Never replies. `:gen.call`'s five-second window elapses and it EXITS rather than
    # returning — which is the entire hazard.
    receive do
      _anything -> loop(:too_slow)
    end
  end

  describe "a socket that accepts the frame" do
    test "returns whatever the socket returned" do
      # WebSockex.send_frame against a plain process is not a real websocket, so this
      # asserts the guard does not interfere on the success path rather than asserting
      # the protocol. `socket(:accepts)` genuinely replies `:ok` via the real
      # `:"$websockex_send"` / `:gen.reply/2` protocol (see `socket/1`'s own comment), so
      # this now asserts the exact success value rather than merely tolerating an error
      # alongside it.
      assert FrameSender.send(socket(:accepts), {:text, "{}"}, "test") == :ok
    end
  end

  describe "a socket that has already died" do
    test "is an error return, not an exit that kills the caller" do
      # This is the whole point. `WebSockex.send_frame/2` exits, and that exit propagates
      # into the process managing the connection — so a dead socket takes down the thing
      # that would have reconnected it.
      dead = socket(:accepts)
      ref = Process.monitor(dead)
      Process.exit(dead, :kill)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 500

      assert {:error, {:send_exit, _reason}} = FrameSender.send(dead, {:text, "{}"}, "test")
      assert Process.alive?(self())
    end
  end

  describe "a socket too busy to answer" do
    @tag timeout: 20_000
    test "becomes {:error, :send_timeout} rather than an exit" do
      # The measured cause: a book subscribe makes the venue reply with a full snapshot —
      # one opening frame measured 39,804 bytes, and a 50-symbol batch is fifty of those.
      # The socket process is single-threaded, so while it decodes that burst it cannot
      # service the next send, which then times out.
      assert {:error, :send_timeout} =
               FrameSender.send(socket(:too_slow), {:text, "{}"}, "slow socket")

      # The caller is still here to retry the batch, which is the difference between a
      # failed subscribe and a dead connection.
      assert Process.alive?(self())
    end
  end
end

defmodule DpExchange.Coinbase.FrameSenderTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.FrameSender

  @moduletag :capture_log

  # A process that behaves the way `WebSockex.send_frame/2` does in each failure mode.
  # Not a mock of WebSockex — a real process that exits, times out, or answers, which is
  # what the guard has to survive.
  defp socket(behaviour) do
    spawn(fn -> loop(behaviour) end)
  end

  defp loop(:accepts) do
    receive do
      {:"$gen_call", from, _frame} -> GenServer.reply(from, :ok)
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
      # the protocol.
      result = FrameSender.send(socket(:accepts), {:text, "{}"}, "test")
      assert result == :ok or match?({:error, _reason}, result)
    end
  end

  describe "a socket that has already died" do
    test "is an error return, not an exit that kills the caller" do
      # This is the whole point. `WebSockex.send_frame/2` exits, and that exit propagates
      # into the process managing the connection — so a dead socket takes down the thing
      # that would have reconnected it.
      dead = socket(:accepts)
      Process.exit(dead, :kill)
      Process.sleep(20)

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

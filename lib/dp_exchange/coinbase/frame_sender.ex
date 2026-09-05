defmodule DpExchange.Coinbase.FrameSender do
  @moduledoc """
  Sends a WebSocket frame without letting a slow socket kill the caller.

  ## The hazard

  `WebSockex.send_frame/2` is not a plain function call. It is:

      {:ok, res} = :gen.call(client, :"$websockex_send", frame)

  with `:gen.call`'s **default 5000 ms timeout**, and on timeout it does not return an
  error — it `exit`s:

      exit({reason, {WebSockex, :call, [client, frame]}})

  That exit propagates into whatever called it. When the caller is the process managing
  the connection, a socket that takes longer than five seconds to accept a frame
  **destroys the connection it was being sent on**.

  ## Why five seconds is not enough

  This is the half that matters, and the half a careless copy loses.

  A subscribe on a book channel makes the venue reply with a **full snapshot** — Gemini's
  opening `l2` frame measured **39,804 bytes**, and a 50-symbol batch is fifty of those.
  The socket process is single-threaded: while it decodes that burst it cannot service the
  next `send_frame`, which then times out.

  Observed 2026-08-10, and it is self-reinforcing:

      batch subscribe exited: {:timeout, {WebSockex, :call, ...}}   # 50 pairs
      batch subscribe exited: {:noproc, ...}                        # socket dead
      subscribed 0 pairs

  Raising the timeout in the layer *above* cannot work while the layer beneath exits at
  five, which is why the same failure kept coming back after being "fixed".

  ## What this does instead

  Catches the exit and returns `{:error, :send_timeout}`. A slow socket becomes a failed
  **batch**, which a caller can report and retry, rather than a dead connection that takes
  every later batch with it.

  **This does not mean the frame was not sent.** `:gen.call` timing out means we stopped
  waiting for the acknowledgement; the socket may deliver it a moment later. Subscribes
  are idempotent on every venue in this family, so a duplicate is harmless — whereas a
  lost connection is not.

  ## The five seconds is not actually fixed — this module chooses not to change it

  The vendored websockex 0.5.1 exposes `WebSockex.send_frame/3`, a timeout argument and
  all (`deps/websockex/lib/websockex.ex`). An override exists upstream; `send/3` below
  still calls the 2-arg form deliberately, so nothing here changes behaviour on the
  strength of that alone. If a longer timeout turns out to help with the incident above,
  that is a decision for the design doc, with reasoning, not a drive-by here.

  ## Why this module is here and not in the contract

  Core ships no transport dependency at any strength, so it cannot ship this. Each venue
  that speaks WebSocket carries its own copy. **This is the first one written**; the other
  frame-WebSocket venue in the family copies this module *and this moduledoc*. Copy the
  reason, not just the code — without it the guard reads as defensive padding and the next
  person tidying up deletes it.
  """

  require Logger

  @typedoc "Anything `WebSockex.send_frame/2` accepts."
  @type frame :: {:text, String.t()} | {:binary, binary()} | atom()

  @doc """
  Sends `frame` to `pid`, converting a send timeout into an error return.

  Returns `:ok`, `{:error, reason}` from the socket itself, or `{:error, :send_timeout}`
  when the socket did not acknowledge within WebSockex's five-second window.
  """
  @spec send(pid(), frame(), String.t()) :: :ok | {:error, term()}
  def send(pid, frame, context \\ "frame") do
    WebSockex.send_frame(pid, frame)
  catch
    # BOUNDARY: `WebSockex.send_frame/2` exits rather than returning on timeout, and that
    # exit would otherwise kill the process sending this frame. Converting it to a value
    # is the entire point of this module.
    :exit, {:timeout, _call} ->
      Logger.warning(
        "[FrameSender] #{context}: socket did not accept the frame within WebSockex's " <>
          "5s send window — reporting a failed send rather than letting the exit take " <>
          "the connection down"
      )

      {:error, :send_timeout}

    # BOUNDARY: the socket is already gone. Same reasoning — the caller decides what to
    # do about it, and it can only make that decision if it is still alive.
    :exit, reason ->
      Logger.warning("[FrameSender] #{context}: send exited: #{inspect(reason)}")
      {:error, {:send_exit, reason}}
  end
end

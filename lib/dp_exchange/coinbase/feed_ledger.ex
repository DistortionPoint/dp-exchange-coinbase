defmodule DpExchange.Coinbase.FeedLedger do
  @moduledoc """
  What a `DpExchange.Coinbase.Feed` has been asked for, kept outside the feed. Internal.

  A feed that crashes is restarted by its supervisor from the options it was started with,
  and those never carry what consumers asked for afterwards: every symbol, every data
  subscriber and every notice subscriber was gone, the feed reported nothing for them, and a
  consumer that had called `subscribe/2` once simply stopped receiving data. Nothing told it
  to subscribe again.

  This is the durable half of that intent: the wanted symbols and the two subscriber sets.
  `DpExchange.Coinbase.Supervisor` starts it **before** the feed and under `:rest_for_one`,
  so a feed crash restarts only the feed, and a crash of the ledger (which loses what it
  held) restarts the feed behind it, which then starts empty rather than from a stale
  picture. The feed writes after every accepted change and reads once, in `handle_continue/2`
  after it starts, to re-monitor its subscribers and subscribe its symbols again.

  It holds no credentials: the feed's come from its own start options, inside the redacting
  `DpExchange.Coinbase.Credentials` struct. It holds no socket, no shard and no frame.
  Writes are casts: a feed must not wait on, or fail with, its own bookkeeping.
  """

  use Agent

  @typedoc "The feed's durable intent."
  @type snapshot :: %{
          wanted: [String.t()],
          subscribers: [pid() | atom()],
          notice_subscribers: [pid() | atom()]
        }

  @doc """
  Starts the ledger, registered under `opts[:name]`, holding nothing.
  """
  @spec start_link(keyword()) :: Agent.on_start()
  def start_link(opts) do
    Agent.start_link(fn -> nil end, name: Keyword.fetch!(opts, :name))
  end

  @doc "Replaces what the ledger holds. A cast: never waits, never fails."
  @spec put(GenServer.server() | nil, snapshot()) :: :ok
  def put(nil, _snapshot), do: :ok
  def put(ledger, snapshot), do: Agent.cast(ledger, fn _held -> snapshot end)

  @doc """
  What the ledger holds, or `nil` when it holds nothing or is not running.
  """
  @spec fetch(GenServer.server() | nil) :: snapshot() | nil
  def fetch(nil), do: nil

  def fetch(ledger) do
    Agent.get(ledger, & &1, 5_000)
  catch
    :exit, _reason -> nil
  end
end

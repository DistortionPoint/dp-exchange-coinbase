defmodule DpExchange.Coinbase.FeedRestartTest do
  @moduledoc """
  A feed that crashes comes back with what consumers had asked of it.

  A supervisor restarts a feed from its start options, which never carried the symbols and
  subscribers added afterwards, so a consumer that called `subscribe/2` once silently stopped
  receiving data. `DpExchange.Coinbase.FeedLedger` keeps that intent outside the feed, under
  `:rest_for_one`, and the restarted feed reads it back and tells each subscriber it did.
  Tier 1: the shard socket is a double that answers sends.
  """

  use DpExchange.Coinbase.FeedCase, async: true

  alias DpExchange.Coinbase.{Feed, FeedLedger}
  alias DpExchange.Coinbase.Supervisor, as: VenueSupervisor
  alias DpExchange.Core.{Notice, Types}

  defp start_tree(extra) do
    name = :"venue_#{System.unique_integer([:positive])}"

    opts =
      [name: name, channels: [:quotes], alias_map_source: fn -> {:ok, %{}} end] ++ extra

    start_supervised!(%{
      id: name,
      start: {VenueSupervisor, :start_link, [opts]},
      type: :supervisor
    })

    opts
  end

  defp wait_for_new(name, old) do
    wait_until(fn ->
      pid = Process.whereis(name)
      is_pid(pid) and pid != old
    end)

    Process.whereis(name)
  end

  defp kill(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
  end

  test "a killed feed is restarted with the same wanted set, subscribed again, still delivering" do
    opts = start_tree(socket: fake_socket())
    feed = VenueSupervisor.feed_name(opts)
    old = Process.whereis(feed)

    assert :ok = Feed.subscribe(feed, ["A-USD", "B-USD"], [])
    assert Feed.wanted(feed) == ["A-USD", "B-USD"]

    kill(old)
    new = wait_for_new(feed, old)

    # Every subscriber is told, with the existing coverage-change kind.
    assert_receive {:dp_exchange, :coinbase,
                    %Notice{
                      kind: :coverage_change,
                      details: %{reason: :feed_restarted, symbols: ["A-USD", "B-USD"]}
                    }},
                   5_000

    # The same wanted set, and the shard was subscribed again.
    assert Feed.wanted(feed) == ["A-USD", "B-USD"]
    assert map_size(:sys.get_state(new).shards) == 1

    # The subscriber is still the subscriber: a delivery reaches it, and covers the symbol.
    send(new, {:dp_exchange, :coinbase, quote_for("A-USD")})
    assert_receive {:dp_exchange, :coinbase, %Types.Quote{symbol: "A-USD"}}, 5_000
    assert Feed.coverage(feed) == %{"A-USD" => :stream}
  end

  test "a change made after one restart survives the next" do
    opts = start_tree(socket: fake_socket())
    feed = VenueSupervisor.feed_name(opts)

    assert :ok = Feed.subscribe(feed, ["A-USD"], [])
    first = Process.whereis(feed)
    kill(first)
    second = wait_for_new(feed, first)

    assert :ok = Feed.unsubscribe(feed, ["A-USD"])
    assert :ok = Feed.subscribe(feed, ["C-USD"], [])
    kill(second)
    wait_for_new(feed, second)

    assert Feed.wanted(feed) == ["C-USD"]
  end

  test "a subscriber that died before the restart is not restored, and neither are its symbols" do
    opts = start_tree(socket: fake_socket())
    feed = VenueSupervisor.feed_name(opts)

    subscriber = spawn(fn -> Process.sleep(:infinity) end)
    assert :ok = Feed.subscribe(feed, ["A-USD"], to: subscriber)

    # The feed is killed before it can act on the subscriber's death, which it would otherwise
    # have handled itself by releasing the symbols.
    :ok = :sys.suspend(feed)
    kill(subscriber)
    old = Process.whereis(feed)
    kill(old)
    wait_for_new(feed, old)

    assert Feed.wanted(feed) == []
  end

  test "the ledger crashing restarts the feed behind it, which starts from nothing" do
    opts = start_tree(socket: fake_socket())
    feed = VenueSupervisor.feed_name(opts)
    ledger = VenueSupervisor.ledger_name(opts)

    assert :ok = Feed.subscribe(feed, ["A-USD"], [])
    old_feed = Process.whereis(feed)
    old_ledger = Process.whereis(ledger)

    kill(old_ledger)
    wait_for_new(feed, old_feed)

    assert Feed.wanted(feed) == []
    assert FeedLedger.fetch(ledger) == nil
  end
end

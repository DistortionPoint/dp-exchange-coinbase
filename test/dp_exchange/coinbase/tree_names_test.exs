defmodule DpExchange.Coinbase.TreeNamesTest do
  @moduledoc """
  Two trees of this venue in one VM, started with nothing but distinct `name:`s.

  The feed, the rate limiter and the feed ledger are registered processes. Their defaults are
  fixed names, so a second tree collided with the first unless the caller also invented a
  `:feed`, a `:limiter` and a `:ledger`. They are now derived from the tree's `:name`
  (`Module.concat(name, Feed)` and so on) when a non-default atom is given and the explicit
  option is not; the default tree keeps the names it always had. The facade resolves the same
  names from `name:` in its own options.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase
  alias DpExchange.Coinbase.{Feed, FeedLedger}
  alias DpExchange.Coinbase.Supervisor, as: VenueSupervisor

  @moduletag :capture_log

  defp start_tree(name) do
    opts = [name: name, channels: [:quotes], alias_map_source: fn -> {:ok, %{}} end]
    spec = %{id: name, start: {VenueSupervisor, :start_link, [opts]}, type: :supervisor}
    start_supervised!(spec)
    opts
  end

  defp unique_name, do: :"tree_#{System.unique_integer([:positive])}"

  describe "the names" do
    test "the default tree keeps the names it always had" do
      assert VenueSupervisor.feed_name([]) == Feed
      assert VenueSupervisor.limiter_name([]) == DpExchange.Coinbase.RateLimiter
      assert VenueSupervisor.ledger_name([]) == FeedLedger
      assert VenueSupervisor.feed_name(name: VenueSupervisor) == Feed
      assert VenueSupervisor.feed_name(name: Coinbase) == Feed
    end

    test "a non-default atom name derives all three" do
      assert VenueSupervisor.feed_name(name: :cb_a) == Module.concat(:cb_a, "Feed")
      assert VenueSupervisor.limiter_name(name: :cb_a) == Module.concat(:cb_a, "RateLimiter")
      assert VenueSupervisor.ledger_name(name: :cb_a) == Module.concat(:cb_a, "FeedLedger")
    end

    test "an explicit option wins over a derived name" do
      assert VenueSupervisor.feed_name(name: :cb_a, feed: :my_feed) == :my_feed
      assert VenueSupervisor.limiter_name(name: :cb_a, limiter: :my_limiter) == :my_limiter
      assert VenueSupervisor.ledger_name(name: :cb_a, ledger: :my_ledger) == :my_ledger
    end

    test "a name that is not an atom derives nothing" do
      assert VenueSupervisor.feed_name(name: "Sub-portfolio") == Feed
      assert VenueSupervisor.feed_name(name: {:global, :cb}) == Feed
    end
  end

  describe "two trees started with only distinct names" do
    test "run side by side, each with its own feed, limiter and ledger" do
      a = unique_name()
      b = unique_name()
      opts_a = start_tree(a)
      opts_b = start_tree(b)

      names = [
        &VenueSupervisor.feed_name/1,
        &VenueSupervisor.limiter_name/1,
        &VenueSupervisor.ledger_name/1
      ]

      for fun <- names do
        pid_a = Process.whereis(fun.(opts_a))
        pid_b = Process.whereis(fun.(opts_b))

        assert is_pid(pid_a)
        assert is_pid(pid_b)
        assert pid_a != pid_b
      end
    end

    test "the facade reaches each tree's own feed from name:" do
      a = unique_name()
      b = unique_name()
      start_tree(a)
      start_tree(b)

      assert :ok = Coinbase.subscribe_notices(name: a)
      assert Coinbase.wanted(name: a) == []
      assert Coinbase.wanted(name: b) == []
      assert Coinbase.coverage(name: a) == %{}
      assert :ok = Coinbase.update_symbols([], name: b)
    end
  end
end

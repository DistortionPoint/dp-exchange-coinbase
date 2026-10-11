defmodule DpExchange.Coinbase.InvalidSubscriberTest do
  @moduledoc """
  A `:to` that `Core.Fanout.resolve/1` has no clause for is refused in the caller, and a
  feed addressed by `{:global, _}` or `{:via, _, _}` is a feed, not a crash.
  """

  use DpExchange.Coinbase.FeedCase, async: true

  alias DpExchange.Coinbase
  alias DpExchange.Coinbase.{Fake, Feed}

  # `nil` is absent to `Config.opt/3` (it falls back to the caller), so it is not listed.
  @bad_subscribers ["consumer", 42, {:global, :somebody}, {:via, Registry, {:r, :k}}, true]

  describe "Feed refuses a subscriber it cannot send to" do
    test "subscribe/3 and subscribe_notices/2 answer the refusal and record nothing" do
      feed = start_feed()
      before = :sys.get_state(feed)

      for bad <- @bad_subscribers do
        assert {:error, {:invalid_subscriber, ^bad}} =
                 Feed.subscribe(feed, ["BTC-USD"], to: bad)

        assert {:error, {:invalid_subscriber, ^bad}} = Feed.subscribe_notices(feed, to: bad)
      end

      after_state = :sys.get_state(feed)
      assert after_state.subscribers == before.subscribers
      assert after_state.notice_subscribers == before.notice_subscribers
      assert after_state.wanted == before.wanted
      assert Process.alive?(feed)
    end

    test "symbols are validated before the subscriber" do
      feed = start_feed()

      assert {:error, {:invalid_symbols, [:eth]}} = Feed.subscribe(feed, [:eth], to: "consumer")
    end

    test "a pid and a registered name are accepted for notices" do
      feed = start_feed()
      name = :"notice_sink_#{System.unique_integer([:positive])}"
      Process.register(self(), name)

      assert :ok = Feed.subscribe_notices(feed, to: self())
      assert :ok = Feed.subscribe_notices(feed, to: name)
      assert :sys.get_state(feed).notice_subscribers == MapSet.new([self(), name])
    end

    test "valid_subscriber/1 passes a pid and an atom name, refuses nil and booleans" do
      assert {:ok, self()} == Feed.valid_subscriber(self())
      assert {:ok, :some_name} == Feed.valid_subscriber(:some_name)

      for bad <- [nil, true, false, "x", 1, {:global, :a}] do
        assert {:error, {:invalid_subscriber, ^bad}} = Feed.valid_subscriber(bad)
      end
    end
  end

  describe "the facade answers, never raises, for a registered feed name shape" do
    test "coverage/1 and coverage_by_kind/1 read a {:global, _} feed" do
      name = {:global, :"cb_feed_#{System.unique_integer([:positive])}"}

      start_supervised!(
        {Feed, [name: name, alias_map_source: fn -> {:ok, %{}} end]},
        id: :global_feed
      )

      assert %{} == Coinbase.coverage(feed: name)
      assert %{} == Coinbase.coverage_by_kind(feed: name)
    end

    test "a {:global, _} name that nothing registered reads empty" do
      name = {:global, :"cb_missing_#{System.unique_integer([:positive])}"}

      assert %{} == Coinbase.coverage(feed: name)
      assert %{} == Coinbase.coverage_by_kind(feed: name)
    end

    test "a pid whose process is gone reads empty" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 5_000

      assert %{} == Coinbase.coverage(feed: pid)
    end
  end

  describe "the facade and the Fake refuse the same way" do
    test "the facade surfaces the feed's refusal" do
      feed = start_feed()

      assert {:error, {:invalid_subscriber, "consumer"}} =
               Coinbase.subscribe(["BTC-USD"], feed: feed, to: "consumer")

      assert {:error, {:invalid_subscriber, 42}} =
               Coinbase.subscribe_notices(feed: feed, to: 42)
    end

    test "Fake.subscribe/2 refuses a bad subscriber and sends nothing" do
      for bad <- @bad_subscribers do
        assert {:error, {:invalid_subscriber, ^bad}} =
                 Fake.subscribe(["BTC-USD"], to: bad)

        assert {:error, {:invalid_subscriber, ^bad}} = Fake.subscribe_notices(to: bad)
      end

      assert Fake.coverage() == %{}
      refute_receive {:dp_exchange, :coinbase, _payload}, 50
    end

    test "Fake refuses symbols before the subscriber, as the feed does" do
      assert {:error, {:invalid_symbols, [:eth]}} = Fake.subscribe([:eth], to: "consumer")
      assert {:error, {:invalid_symbols, nil}} = Fake.update_symbols(nil)
      assert {:error, {:invalid_symbols, [""]}} = Fake.unsubscribe([""])
    end

    test "Fake.subscribe_notices/1 accepts a valid pid and, like the feed, sends nothing" do
      assert :ok = Fake.subscribe_notices(to: self())
      refute_receive {:dp_exchange, :coinbase, %DpExchange.Core.Notice{}}, 50
    end
  end
end

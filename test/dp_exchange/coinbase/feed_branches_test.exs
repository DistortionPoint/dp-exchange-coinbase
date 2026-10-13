defmodule DpExchange.Coinbase.FeedBranchesTest do
  @moduledoc """
  Feed behaviour that had no test: the alias catalogue's refresh and its failure shapes, a
  stranded unsubscribe that is only partly released, a release that fails for a reason no
  retry fixes or because the socket died mid-send, shards of all three channels ordered and
  isolated together, and the feed's own refusal of a symbol list a raw caller sends it.

  Real feeds, real messages; the sockets are small processes that answer the way
  `WebSockex.send_frame/2` expects, because the feed only ever talks to a socket that way.
  """

  use DpExchange.Coinbase.FeedCase, async: true

  alias DpExchange.Coinbase.Feed
  alias DpExchange.Core.Types

  # NOT `start_feed/1`: it puts its own `alias_map_source` first, and `Keyword.get/2` takes
  # the first one, so a source passed through it is silently ignored.
  defp start_feed_with_source(source) do
    name = :"feed_#{System.unique_integer([:positive])}"
    start_supervised!({Feed, name: name, alias_map_source: source}, id: name)
  end

  # Answers every send `:ok` and tells the test what it was, with when it arrived.
  defp recording_socket(tag) do
    test = self()

    pid =
      spawn(fn ->
        Stream.repeatedly(fn ->
          receive do
            {:"$websockex_send", from, {:text, raw}} ->
              # Stamped BEFORE the reply, with a value strictly increasing node-wide: `Feed`
              # sends a frame and waits for this reply before sending the next, so the stamps
              # follow send order. A millisecond clock gave two frames one value and could not
              # order them.
              send(test, {:frame, tag, Jason.decode!(raw), System.unique_integer([:monotonic])})
              :gen.reply(from, :ok)
          end
        end)
        |> Stream.run()
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp idle_socket do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp kinds(feed), do: feed |> Feed.coverage_by_kind() |> Map.keys() |> Enum.sort()

  defp trade_for(symbol) do
    %Types.Trade{
      id: "1",
      symbol: symbol,
      side: :buy,
      price: Decimal.new("1"),
      quantity: Decimal.new("1"),
      timestamp: ~U[2026-10-02 12:00:00Z],
      provider: :coinbase
    }
  end

  describe "the alias catalogue's hourly refresh" do
    test "a refresh that fails keeps the map already loaded" do
      # An empty map would switch attribution off for every aliased product at once, for a
      # catalogue that was right an hour ago.
      calls = :counters.new(1, [])

      source = fn ->
        :counters.add(calls, 1, 1)

        if :counters.get(calls, 1) == 1,
          do: {:ok, %{"A-USD" => "B-USD"}},
          else: {:error, :simulated_refresh_failure}
      end

      feed = start_feed_with_source(source)

      send(feed, :fetch_alias_map)
      wait_until(fn -> :sys.get_state(feed).alias_map_status == :ok end)

      send(feed, :refresh_alias_map)
      wait_until(fn -> :counters.get(calls, 1) == 2 end)
      wait_until(fn -> :sys.get_state(feed).alias_map_fetch == nil end)

      state = :sys.get_state(feed)
      assert state.alias_map_status == :ok
      assert state.alias_map == %{"A-USD" => "B-USD"}
      assert state.alias_map_failure_reason == nil
    end
  end

  describe "an alias catalogue source that does not return" do
    test "a source that raises is a permanent failure carrying the exception's message" do
      feed = start_feed_with_source(fn -> raise "simulated catalogue crash" end)

      send(feed, :fetch_alias_map)
      wait_until(fn -> :sys.get_state(feed).alias_map_status == :unavailable end)

      assert :sys.get_state(feed).alias_map_failure_reason ==
               {:alias_map_fetch_raised, "simulated catalogue crash"}
    end

    test "a source that exits is a permanent failure carrying the exit reason" do
      feed = start_feed_with_source(fn -> exit(:simulated_catalogue_exit) end)

      send(feed, :fetch_alias_map)
      wait_until(fn -> :sys.get_state(feed).alias_map_status == :unavailable end)

      assert :sys.get_state(feed).alias_map_failure_reason ==
               {:alias_map_fetch_exited, :simulated_catalogue_exit}
    end

    test "a notice subscriber that is a name nobody holds is skipped, not an error" do
      feed = start_feed_with_source(fn -> {:error, :simulated_catalogue_failure} end)

      send(feed, :fetch_alias_map)
      wait_until(fn -> :sys.get_state(feed).alias_map_status == :unavailable end)

      nobody = :"nobody_#{System.unique_integer([:positive])}"

      # Registering replays the degraded-attribution notice to the newcomer, which here has
      # nowhere to go.
      assert :ok = Feed.subscribe_notices(feed, to: nobody)
      assert Process.alive?(feed)
    end
  end

  describe "the feed refuses a symbol list a raw caller sends it" do
    # The public wrappers refuse in the caller first; the feed is a named GenServer anyone can
    # call, and a bad list reaching `SymbolFormat` in here would crash it for everyone.
    test "subscribe, unsubscribe and update_symbols messages" do
      feed = start_feed()

      assert {:error, {:invalid_symbols, nil}} = GenServer.call(feed, {:subscribe, nil, self()})
      assert {:error, {:invalid_symbols, [" "]}} = GenServer.call(feed, {:unsubscribe, [" "]})
      assert {:error, {:invalid_symbols, :btc}} = GenServer.call(feed, {:update_symbols, :btc})
      assert Feed.coverage(feed) == %{}
    end
  end

  describe "a stranded unsubscribe that is released only in part" do
    test "what the send covered is cleared, the rest stays owed, and the shard is not retired" do
      socket = recording_socket(:ticker)
      key = {"ticker", 0}
      feed = start_feed()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | shards: %{key => %{socket: socket, symbols: []}},
            pending_unsubscribes: %{key => ["A-USD", "B-USD"]}
        }
      end)

      send(feed, {:channel_reconcile, key, socket, "ticker", ["A-USD"], [], nil})

      assert_receive {:frame, :ticker, %{"type" => "unsubscribe"} = frame, _at}, 5_000
      assert frame["product_ids"] == ["A-USD"]

      state = :sys.get_state(feed)
      # `B-USD` is still owed to the venue, so the emptied shard is kept to retry it on.
      assert state.pending_unsubscribes == %{key => ["B-USD"]}
      assert %{^key => %{symbols: []}} = state.shards
    end
  end

  describe "an unsubscribe that fails" do
    # Replies to every send with `reply` and reports it, so the test learns what was tried.
    defp replying_socket(reply) do
      test = self()

      pid =
        spawn(fn ->
          Stream.repeatedly(fn ->
            receive do
              {:"$websockex_send", from, {:text, raw}} ->
                :gen.reply(from, reply)
                send(test, {:sent, Jason.decode!(raw)["type"]})
            end
          end)
          |> Stream.run()
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      pid
    end

    test "for a reason no retry fixes is stranded at once, and nothing new is subscribed" do
      socket = replying_socket({:error, :refused_by_the_socket})
      key = {"ticker", 0}
      feed = start_feed(subscribe_retry_delay_ms: 5)

      :sys.replace_state(feed, fn state ->
        %{state | shards: %{key => %{socket: socket, symbols: ["B-USD"]}}}
      end)

      send(feed, {:channel_reconcile, key, socket, "ticker", ["A-USD"], ["B-USD"], nil})

      assert_receive {:sent, "unsubscribe"}, 5_000
      assert :sys.get_state(feed).pending_unsubscribes == %{key => ["A-USD"]}

      # Not retried (a retry would send another unsubscribe), and `B-USD` withheld while
      # `A-USD` may still be live at the venue.
      refute_receive {:sent, _type}, 300
    end

    test "because the socket died mid-send is retried, not stranded" do
      test = self()
      key = {"ticker", 0}

      socket =
        spawn(fn ->
          receive do
            {:"$websockex_send", _from, _frame} ->
              send(test, :about_to_die)
              exit(:simulated_socket_death)
          end
        end)

      feed = start_feed(subscribe_retry_delay_ms: 5)

      :sys.replace_state(feed, fn state ->
        %{state | shards: %{key => %{socket: socket, symbols: ["B-USD"]}}}
      end)

      send(feed, {:channel_reconcile, key, socket, "ticker", ["A-USD"], ["B-USD"], nil})

      assert_receive :about_to_die, 5_000
      wait_until(fn -> not Process.alive?(socket) end)

      # The retry is scheduled (and finds the socket gone, which ends it); a permanent
      # failure would have recorded `A-USD` as owed.
      assert :sys.get_state(feed).pending_unsubscribes == %{}
      assert Process.alive?(feed)
    end
  end

  describe "shards of all three channels together" do
    test "a resubscribe re-issues ticker ahead of market_trades" do
      # `ticker` keeps the front of any stagger sequence, so its boot-time coverage is what
      # a slow `market_trades` shard cannot delay.
      ticker = recording_socket(:ticker)
      trades = recording_socket(:trades)
      feed = start_feed(shard_spacing_ms: 150)

      :sys.replace_state(feed, fn state ->
        %{
          state
          | shards: %{
              {"market_trades", 0} => %{socket: trades, symbols: ["BTC-USD"]},
              {"ticker", 0} => %{socket: ticker, symbols: ["BTC-USD"]}
            }
        }
      end)

      send(feed, :resubscribe)

      assert_receive {:frame, :ticker, %{"channel" => "ticker"}, ticker_at}, 5_000
      assert_receive {:frame, :trades, %{"channel" => "market_trades"}, trades_at}, 5_000
      assert ticker_at < trades_at
    end

    test "a link drop narrows to that shard's own kind, whichever channel it carries" do
      ticker = idle_socket()
      book = idle_socket()
      trades = idle_socket()
      feed = start_feed()

      :sys.replace_state(feed, fn state ->
        %{
          state
          | shards: %{
              {"ticker", 0} => %{socket: ticker, symbols: ["BTC-USD"]},
              {"level2", 0} => %{socket: book, symbols: ["BTC-USD"]},
              {"market_trades", 0} => %{socket: trades, symbols: ["BTC-USD"]}
            }
        }
      end)

      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})
      send(feed, {:dp_exchange, :coinbase, order_book_for("BTC-USD")})
      send(feed, {:dp_exchange, :coinbase, trade_for("BTC-USD")})

      assert kinds(feed) == [:order_book, :quotes, :trades]

      send(feed, {:dp_exchange, :coinbase, :link_down, book})
      assert kinds(feed) == [:quotes, :trades]

      send(feed, {:dp_exchange, :coinbase, :link_down, trades})
      assert kinds(feed) == [:quotes]
    end
  end
end

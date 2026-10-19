defmodule DpExchange.Coinbase.DefaultArityTest do
  @moduledoc """
  The arities a consumer reaches by leaving the trailing options (or the feed) out.

  `def f(a, opts \\\\ [])` compiles one body and a separate head per omitted argument, and the
  facade is the package's whole public surface: a consumer writing `Coinbase.place_order(c, r)`
  never passes `[]`. Every call here is decided before any request (a refusal, or no feed
  running), so none needs a plug, a limiter or a network.

  No test in this package starts a feed under the default `DpExchange.Coinbase.Feed` name,
  which is what makes "no feed running" true for the calls that omit `:feed`.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase
  alias DpExchange.Coinbase.{Fake, Feed, Socket}

  @moduletag :capture_log

  @credentials %{
    api_key: "organizations/x/apiKeys/y",
    api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
  }
  @prime_credentials %{
    access_key: "prime-key",
    passphrase: "prime-passphrase",
    signing_key: "prime-signing-key"
  }
  @missing {:error, {:missing_credentials, :coinbase}}

  describe "the facade without its trailing options" do
    test "order writes and reads refuse a bad argument before any request" do
      assert {:error, {:invalid_order_request, :bad}} = Coinbase.place_order(@credentials, :bad)
      assert {:error, {:invalid_order_request, :bad}} = Coinbase.preview_order(@credentials, :bad)

      assert {:error, {:unsupported_order_field, :side}} =
               Coinbase.replace_order(@credentials, "abc", %{side: :sell})

      assert {:error, {:unsupported_order_field, :side}} =
               Coinbase.preview_replace(@credentials, "abc", %{side: :sell})

      assert {:error, {:invalid_symbol, ""}} = Coinbase.close_position(@credentials, "")
      assert {:error, {:invalid_order_id, ""}} = Coinbase.cancel_order(@credentials, "")
      assert {:error, {:invalid_order_id, ""}} = Coinbase.get_order(@credentials, "")
    end

    test "quantization/1 refuses a symbol that names no product" do
      assert {:error, {:invalid_symbol, ""}} = Coinbase.quantization("")
    end

    test "Prime staking reads and writes refuse a portfolio id that is not a path segment" do
      bad = "a/b"

      assert {:error, {:invalid_portfolio_id, ^bad}} =
               Coinbase.query_transaction_validators(@prime_credentials, bad)

      assert {:error, {:invalid_portfolio_id, ^bad}} =
               Coinbase.staking_status(@prime_credentials, bad, "w-1")

      assert {:error, {:invalid_portfolio_id, ^bad}} =
               Coinbase.unstake_status(@prime_credentials, bad, "w-1")

      assert {:error, {:invalid_portfolio_id, ^bad}} =
               Coinbase.claim_rewards(@prime_credentials, bad, "w-1")

      assert {:error, {:invalid_portfolio_id, ^bad}} =
               Coinbase.preview_unstake_wallet(
                 @prime_credentials,
                 bad,
                 "w-1",
                 "ETH",
                 Decimal.new("1")
               )
    end
  end

  describe "the facade's streaming calls without :feed, with no feed running" do
    test "each answers rather than exiting" do
      assert Coinbase.subscribe(["BTC-USD"]) == {:error, :feed_not_started}
      assert Coinbase.unsubscribe(["BTC-USD"]) == :ok
      assert Coinbase.update_symbols(["BTC-USD"]) == {:error, :feed_not_started}
      assert Coinbase.subscribe_notices() == {:error, :feed_not_started}
      assert Coinbase.coverage() == %{}
      assert Coinbase.coverage_by_kind() == %{}
    end
  end

  describe "the facade's feed calls when the feed misbehaves" do
    # A registered process that takes the first call and does what `fun` says with it.
    defp rogue_feed(fun) do
      name = :"rogue_feed_#{System.unique_integer([:positive])}"
      test_pid = self()

      pid =
        spawn(fn ->
          Process.register(self(), name)
          send(test_pid, {:registered, name})

          receive do
            {:"$gen_call", _from, _request} -> fun.()
          end
        end)

      on_exit(fn -> Process.exit(pid, :kill) end)
      assert_receive {:registered, ^name}, 5_000
      name
    end

    test "coverage reads that die mid-call are the empty answer, never a crash" do
      # `coverage/1` and `coverage_by_kind/1` return a map and have no room for an error;
      # "not observed" is the only honest answer when the feed cannot say.
      assert Coinbase.coverage(feed: rogue_feed(fn -> exit(:boom) end)) == %{}
      assert Coinbase.coverage_by_kind(feed: rogue_feed(fn -> exit(:boom) end)) == %{}
    end

    # The feed's whole call budget (15s) has to pass for the timeout to be observed: a
    # shorter wait would test a different exit. Margin is the budget itself.
    @tag timeout: 60_000
    test "a feed too busy to answer within its call budget is :feed_timeout" do
      name = rogue_feed(fn -> Process.sleep(:infinity) end)

      assert Coinbase.subscribe(["BTC-USD"], feed: name) == {:error, :feed_timeout}
    end
  end

  describe "Feed without a feed argument, with none registered under its own name" do
    test "unsubscribe/1 and update_symbols/1 refuse bad symbols in the caller" do
      assert {:error, {:invalid_symbols, nil}} = Feed.unsubscribe(nil)
      assert {:error, {:invalid_symbols, [" "]}} = Feed.update_symbols([" "])
    end

    test "coverage_by_kind/0 and subscribe_notices/0 address the default name" do
      assert {:noproc, _call} = catch_exit(Feed.coverage_by_kind())
      assert {:noproc, _call} = catch_exit(Feed.subscribe_notices())
    end
  end

  describe "Socket.subscribe/3 without a credential" do
    test "a socket that is gone is a returned error, not an exit" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}, 5_000

      assert {:error, {:send_exit, _reason}} = Socket.subscribe(dead, "ticker", ["BTC-USD"])
    end
  end

  describe "the fake without its trailing options" do
    test "private calls refuse as the real path does: no credential" do
      assert Fake.get_positions() == @missing
      assert Fake.list_portfolios() == @missing
      assert Fake.get_roles() == @missing
    end

    test "conversions name both accounts or nothing" do
      assert {:error, :from_and_to_required} = Fake.commit_conversion("trade-1")
      assert {:error, :from_and_to_required} = Fake.get_conversion("trade-1")
    end

    test "create_account/0 needs the name it is not given" do
      assert {:error, :name_required} = Fake.create_account()
    end

    test "notices register the caller and say nothing" do
      assert :ok = Fake.subscribe_notices()
      refute_received {:dp_exchange, :coinbase, _anything}
    end

    test "an unlisted symbol's book is :not_listed, not an invented one" do
      assert {:refused, :not_listed} = Fake.get_order_book("NOPE-USD")
    end

    test "what the venue does not serve is not supported, at every arity" do
      assert {:error, :not_supported} = Fake.get_deposit_address("BTC", "bitcoin")

      assert {:error, :not_supported} =
               Fake.estimate_withdrawal_fee("BTC", "bitcoin", Decimal.new("1"))

      assert {:error, :not_supported} = Fake.withdraw("BTC", "bitcoin", Decimal.new("1"), "addr")
    end
  end
end

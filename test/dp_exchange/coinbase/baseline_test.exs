defmodule DpExchange.Coinbase.BaselineTest do
  @moduledoc """
  The behavioural baseline carried over from the host's Coinbase tests (Phase 5.7).

  ## Why this is not a port of those 4,582 lines

  Read in full, most of that corpus does not encode behaviour. Measured across its eleven
  files: **62 assertions of the form `match?({:ok, _}, result) or match?({:error, _},
  result)`**, which is true of every possible return value, and 121 more that check only
  a shape — `is_list/1`, `Map.has_key?/2`. Ten of the eleven files have no HTTP seam, so
  their "unit" tests reach the live venue with placeholder credentials and pass on the
  error path.

  Porting that wholesale would import two things this package has already had to remove:
  assertions that cannot fail, and tier-1 tests that hit a third party's API.

  What the corpus *does* encode, and what is preserved here, is the **v3 message
  taxonomy** — the channels Coinbase actually sends, the per-channel nesting, and the
  handful of concrete values its tests assert against real payloads. That is the part a
  port would lose, and losing it is how a channel silently stops delivering.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Socket
  alias DpExchange.Core.{Notice, Types}

  @moduletag :capture_log

  defp state, do: %{subscriber: self(), credentials: nil, delivering: MapSet.new(), books: %{}}
  defp frame(payload), do: Socket.handle_frame({:text, Jason.encode!(payload)}, state())

  describe "the v3 nesting is per channel, and getting it wrong drops everything" do
    test "ticker rows live under events[].tickers" do
      assert {:ok, _state} =
               frame(%{
                 "channel" => "ticker",
                 "timestamp" => "2026-08-28T14:53:45.649112Z",
                 "events" => [
                   %{
                     "tickers" => [
                       %{
                         "product_id" => "BTC-USD",
                         "price" => "79478.7"
                       }
                     ]
                   }
                 ]
               })

      assert_received {:dp_exchange, :coinbase, %Types.Quote{symbol: "BTC-USD"}}
    end

    test "l2_data is decoded — v3 renames level2 on the RESPONSE side only" do
      # The subscribe says `level2`; the venue answers on `l2_data`. A parser keyed on
      # the subscribe name drops every book update, and a venue delivering nothing on one
      # channel while another works reads as a quiet market rather than a parsing bug.
      assert {:ok, _state} =
               frame(%{
                 "channel" => "l2_data",
                 "timestamp" => "2026-08-28T14:53:45.649112Z",
                 "events" => [
                   %{
                     "type" => "snapshot",
                     "product_id" => "BTC-USD",
                     "updates" => [
                       %{"side" => "bid", "price_level" => "77791.77", "new_quantity" => "1.0"}
                     ]
                   }
                 ]
               })

      assert_received {:dp_exchange, :coinbase, %Types.OrderBook{symbol: "BTC-USD"}}
    end

    test "every OTHER channel the venue sends is recognised, none silently ignored" do
      # Silence is the failure mode: an unrecognised channel that falls through looks
      # identical to a channel that stopped arriving. `l2_data` is excluded here — it is
      # subscribed and decoded now, not merely recognised; its own test covers it above.
      for channel <- ~w(market_trades candles user) do
        assert {:ok, _state} = frame(%{"channel" => channel, "events" => []})

        assert_received {:dp_exchange, :coinbase, %Notice{kind: :data_quality}},
                        "channel #{channel} was dropped without a word"
      end
    end

    test "subscription confirmations are not data and not coverage" do
      # A confirmation is intent. Coverage reports what arrived, and conflating the two
      # is how a venue reported 325 symbols confirmed while 174 were delivering.
      assert {:ok, _state} = frame(%{"channel" => "subscriptions", "events" => []})

      refute_received {:dp_exchange, :coinbase, %Types.Quote{}}
      refute_received {:dp_exchange, :coinbase, %Notice{}}
    end

    test "heartbeats are silent" do
      assert {:ok, _state} = frame(%{"channel" => "heartbeats", "events" => []})
      refute_received {:dp_exchange, :coinbase, _anything}
    end
  end

  describe "concrete values the host's tests pinned" do
    test "the provider tag is the atom, not the string the host used" do
      # The host asserted `parsed.provider == "coinbase"` sixteen times. This is a
      # deliberate delta: the contract types provider as `atom() | String.t()` and this
      # family uses the atom, so a consumer matching on it does not also have to match a
      # string. Recorded in reconciliation.md.
      assert {:ok, _state} =
               frame(%{
                 "channel" => "ticker",
                 "timestamp" => "2026-08-28T14:53:45Z",
                 "events" => [
                   %{
                     "tickers" => [
                       %{
                         "product_id" => "ETH-USD",
                         "price" => "2951.40"
                       }
                     ]
                   }
                 ]
               })

      assert_received {:dp_exchange, :coinbase, quote_struct}
      assert quote_struct.provider == :coinbase
      assert quote_struct.symbol == "ETH-USD"
    end

    test "the venue's timestamp is preserved to the microsecond" do
      # The host pinned `parsed.timestamp.year`. This pins the whole instant, because a
      # timestamp rounded to the second is a timestamp quietly altered.
      assert {:ok, _state} =
               frame(%{
                 "channel" => "ticker",
                 "timestamp" => "2026-08-28T14:53:45.649112Z",
                 "events" => [
                   %{
                     "tickers" => [
                       %{
                         "product_id" => "BTC-USD",
                         "price" => "1"
                       }
                     ]
                   }
                 ]
               })

      assert_received {:dp_exchange, :coinbase, quote_struct}
      assert quote_struct.timestamp == ~U[2026-08-28 14:53:45.649112Z]
    end
  end

  describe "deltas from the host, asserted rather than only described" do
    test "an unsupported timeframe is an error — the host's fallback is gone" do
      assert {:error, {:unsupported_timeframe, "12h"}} =
               DpExchange.Coinbase.get_historical_prices("BTC-USD", "12h")
    end

    test "there is no path that returns candles the venue did not send" do
      # The host kept `generate_fallback_candles/4` behind a node-wide flag. Nothing here
      # can fabricate: no flag, no table, no generator.
      #
      # Docs and comments are stripped first. The moduledoc names the thing while
      # explaining its absence, and a check that cannot tell code from the prose about it
      # forces a choice between deleting the explanation and muting the check.
      code =
        "lib/dp_exchange/coinbase/rest.ex"
        |> File.read!()
        |> String.replace(~r/@(module)?doc\s+"""..*?"""/s, "")
        |> String.replace(~r/^\s*#.*$/m, "")

      refute code =~ ~r/fallback_candles|base_price/
      refute code =~ ~r/mock_external_apis|test_overrides/
    end

    test "refusal and error are distinct, which the host conflated" do
      assert {:refused, :not_listed} = DpExchange.Coinbase.Fake.get_price("NOPE-USD")

      assert {:error, {:unsupported_timeframe, _tf}} =
               DpExchange.Coinbase.Fake.get_historical_prices("BTC-USD", "12h")
    end
  end
end

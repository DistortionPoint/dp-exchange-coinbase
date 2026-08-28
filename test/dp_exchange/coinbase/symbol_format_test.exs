defmodule DpExchange.Coinbase.SymbolFormatTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.SymbolFormat

  doctest SymbolFormat

  describe "the round trip holds" do
    test "for every pair over every declared quote" do
      quotes = DpExchange.Coinbase.capabilities().supported_quotes

      for base <- ~w(BTC ETH SOL DOGE), quote_asset <- quotes do
        pair = "#{base}-#{quote_asset}"

        assert pair ==
                 pair |> SymbolFormat.to_exchange_symbol() |> SymbolFormat.to_canonical_symbol()
      end
    end

    test "Coinbase's native form is already canonical, so the trip is identity" do
      assert "BTC-USD" == SymbolFormat.to_exchange_symbol("BTC-USD")
      assert "BTC-USD" == SymbolFormat.to_canonical_symbol("BTC-USD")
    end
  end

  describe "it normalises rather than leaking" do
    test "lowercase from the venue is uppercased" do
      # The defensive boundary: any un-canonical form Coinbase ever returns is normalised
      # here rather than reaching a catalogue that will not match it.
      assert "BTC-USD" == SymbolFormat.to_canonical_symbol("btc-usd")
    end

    test "a separatorless form passes through uppercased rather than being guessed at" do
      # This venue declares `sep: "-"`, so `CanonicalPair` splits on the dash and never
      # falls back to matching a quote suffix. A string with no dash is therefore NOT
      # split — it is returned uppercased.
      #
      # That is the right behaviour and the reason is worth keeping: a dropped symbol is
      # invisible, whereas a strange one is reviewable. Guessing a split for a venue whose
      # symbols always carry a separator would invent a pair from something that is
      # probably not a pair at all.
      assert "BTCUSDC" == SymbolFormat.to_canonical_symbol("BTCUSDC")
      assert "BTCUSD" == SymbolFormat.to_canonical_symbol("btcusd")
    end

    test "both directions are total — nothing raises and nothing is dropped" do
      for input <- ["", "NOTAPAIR", "---", "BTC-", "-USD", "btc"] do
        assert is_binary(SymbolFormat.to_canonical_symbol(input))
        assert is_binary(SymbolFormat.to_exchange_symbol(input))
      end
    end
  end

  describe "mapping/0" do
    test "is exposed so the conformance suite can drive CanonicalPair with it" do
      mapping = SymbolFormat.mapping()

      assert mapping.sep == "-"
      assert "USDC" in mapping.quotes
    end

    test "quotes are ordered longest-first, as the shared convention requires" do
      # Never consulted on this venue — a dashed mapping splits on the separator and
      # never falls back to suffix matching. Kept correct anyway: it costs nothing, and
      # it stops being cosmetic the moment someone reuses this mapping for a venue that
      # concatenates.
      quotes = SymbolFormat.mapping().quotes

      assert Enum.find_index(quotes, &(&1 == "USDC")) < Enum.find_index(quotes, &(&1 == "USD"))
      assert Enum.find_index(quotes, &(&1 == "USDT")) < Enum.find_index(quotes, &(&1 == "USD"))
    end
  end
end

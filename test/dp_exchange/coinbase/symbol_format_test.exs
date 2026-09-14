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

    test "a symbol with no quote part is not decorated with this venue's separator" do
      # This venue maps with `sep: "-"`, so `CanonicalPair.to_exchange/2` used to join
      # `base <> "-" <> ""` and hand back `"AAPL-"` for `"AAPL"`, and `"-"` for `""`.
      #
      # The totality test below already fed exactly these inputs — and asserted only
      # `is_binary/1`, which `"AAPL-"` satisfies perfectly. It exercised the bug every run
      # and said nothing about it.
      #
      # It matters because the fabricated string is plausible: it goes into a request URL,
      # the venue answers 404, and `classify/1` reports `{:refused, :not_listed}` — telling
      # a caller the VENUE said their symbol is not listed, when what happened is that this
      # package invented a symbol the venue was never asked about.
      assert "AAPL" == SymbolFormat.to_exchange_symbol("AAPL")
      assert "BTC" == SymbolFormat.to_exchange_symbol("BTC")
      assert "" == SymbolFormat.to_exchange_symbol("")

      # A dangling separator is not carried to the venue either.
      assert "BTC" == SymbolFormat.to_exchange_symbol("BTC-")

      # And a real pair is unaffected.
      assert "BTC-USD" == SymbolFormat.to_exchange_symbol("BTC-USD")
    end

    test "both directions are total — nothing raises and nothing is dropped" do
      for input <- ["", "NOTAPAIR", "---", "BTC-", "-USD", "btc"] do
        assert is_binary(SymbolFormat.to_canonical_symbol(input))
        assert is_binary(SymbolFormat.to_exchange_symbol(input))
      end
    end
  end
end

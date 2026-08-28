defmodule DpExchange.Coinbase.SymbolFormat do
  @moduledoc """
  Coinbase's symbol mapping.

  Its native `product_id` is already canonical `BASE-QUOTE` — `BTC-USD` — so the
  conversion is effectively identity. It is declared anyway, for two reasons.

  The contract is uniform: every venue implements both directions, so nothing above the
  facade needs to know that one venue's conversion happens to be free.

  And it is a **defensive boundary**. Any un-canonical form Coinbase ever returns gets
  normalised here rather than leaking upward — a lowercase `btc-usd`, or a separatorless
  form from an endpoint nobody has looked at lately. The cost of running the normaliser
  over an already-canonical string is nothing; the cost of one venue quietly emitting a
  form the rest of the system does not recognise is a symbol that matches no catalogue
  entry and collects nothing.

  ## The quote list is ordered longest-first, and here that is precaution, not need

  `USDC` precedes `USD`, as the shared convention requires. **On this venue the ordering
  never comes into play**, and it is worth being precise about why rather than repeating
  the general rule as though it bit here.

  `CanonicalPair` splits on the separator when a mapping declares one, and falls back to
  matching a quote suffix only for a separatorless mapping. Coinbase declares `sep: "-"`,
  so a string without a dash takes the `:nomatch` path and is returned uppercased — it is
  never split, and the quote list is never consulted.

  The ordering is kept correct anyway. It costs nothing, and it stops being merely
  cosmetic the moment someone reuses this mapping for a venue that concatenates.
  """

  @behaviour DpExchange.Core.SymbolNormalizer

  alias DpExchange.Core.CanonicalPair

  @mapping %{sep: "-", quotes: ~w(USDC USDT USD EUR GBP BTC ETH)}

  @doc "The mapping, exposed so the conformance suite can drive `CanonicalPair` with it."
  @spec mapping() :: CanonicalPair.mapping()
  def mapping, do: @mapping

  @impl true
  @spec to_canonical_symbol(String.t()) :: String.t()
  def to_canonical_symbol(native) when is_binary(native),
    do: CanonicalPair.to_canonical(@mapping, native)

  @impl true
  @spec to_exchange_symbol(String.t()) :: String.t()
  def to_exchange_symbol(canonical) when is_binary(canonical),
    do: CanonicalPair.to_exchange(@mapping, canonical)
end

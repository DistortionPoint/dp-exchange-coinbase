defmodule DpExchange.CoinbaseContractTest do
  @moduledoc """
  Core's conformance suite, run against this package. Shipped by `dp_exchange_core` and
  identical across every venue in the family — which is what stops six CLAUDE.md files
  drifting apart.
  """

  use DpExchange.Core.AdapterContract,
    venue: DpExchange.Coinbase,
    fake: DpExchange.Coinbase.Fake,
    symbol_format: DpExchange.Coinbase.SymbolFormat,
    sample_pairs: ~w(BTC-USD ETH-USD BTC-USDC),
    # Conformance group 41 (family reasons, 2026-10-14): a well-formed symbol the fake does
    # not list, and a credentials map whose first value carries a trailing newline.
    unlisted_symbol: "NOPE-USD",
    padded_credentials: %{
      api_key: "test-key\n",
      api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
    },
    # `lib/vendor/` is third-party code, a patched websockex fork (see
    # `DpExchange.Coinbase.Vendor.WebSockex`). The scanning assertions are written for this
    # family's own conventions, so they read `lib/dp_exchange` only, as Webull's do.
    package_root: "lib/dp_exchange",
    credentials: %{
      api_key: "test-key",
      api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
    },
    # This venue's edit needs both size and price (`Rest.editable_present/1`), so the suite's
    # generic price-only edit is refused for a reason that has nothing to do with the id
    # assertion 31 is checking.
    order_args: %{order_changes: %{quantity: Decimal.new("0.002"), price: Decimal.new("1")}}
end

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
    # `lib/vendor/` is third-party code, a patched websockex fork (see
    # `DpExchange.Coinbase.Vendor.WebSockex`). The scanning assertions are written for this
    # family's own conventions, so they read `lib/dp_exchange` only, as Webull's do.
    package_root: "lib/dp_exchange",
    credentials: %{
      api_key: "test-key",
      api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
    }
end

# DpExchangeCoinbase

> ## ⚠️ EXPERIMENTAL — read this before depending on it
>
> This package has **never run in production.** It is published early and openly so it
> can be used and reported on, not because it is finished.
>
> - **The API may change without a major version.** Pin three-part (`~> 0.1.0`).
> - **Verification is uneven, and the gaps are on the expensive side.** The conformance
>   suite passes against a fake, and against Coinbase's live public endpoints.
>   **Order placement and authenticated flows are thinly covered.** No test in this repo
>   spends money.
> - **Maturity is declared per endpoint.** Read `capabilities/0`, not this banner.
>
> [Report a divergence](https://github.com/DistortionPoint/dp-exchange-coinbase/issues).

Coinbase for the **DpExchange** family: market data, trading and streaming behind the
same facade every venue in the family exposes.

## What this package covers

87 callbacks, of which **46 are declared `:experimental`** and 41 `:unsupported`. None is `:proven` — that requires a consumer trading live, and this package has never run in production (D15).

Asset classes: **crypto**. Streamed kinds: **quotes** — everything else pulls only.

Of the 41 unsupported endpoints, **38 are the venue's own absence**, not this package's backlog — see `venue_does_not_serve/0` and `docs/reference/coinbase/negative-claims.md`, which records the source and date behind every one.

## Installation

```elixir
def deps do
  [
    {:dp_exchange_coinbase, "~> 0.1.0"}
  ]
end
```

## Usage

```elixir
# In your supervision tree. Nothing starts itself.
children = [{DpExchange.Coinbase, credentials: my_credentials()}]

{:ok, quote} = DpExchange.Coinbase.get_price("BTC-USD", [])

:ok = DpExchange.Coinbase.subscribe(["BTC-USD"], to: self())
```

`DpExchange.Coinbase` is the **entire public API**. Everything else — transport, signing,
session handling, supervision — is internal, and the conformance suite asserts it.

See [`dp_exchange_core`](https://hex.pm/packages/dp_exchange_core) for the contract, and
this package's `usage-rules.md` for what is specific to Coinbase.

## License

MIT. See [LICENSE](https://github.com/DistortionPoint/dp-exchange-coinbase/blob/main/LICENSE).

# Using `dp_exchange_coinbase`

> **EXPERIMENTAL.** Not run in production. Pin three-part. Maturity is per endpoint —
> read `capabilities/0`, not this banner.

Everything general is in
[`dp_exchange_core`'s usage rules](https://hexdocs.pm/dp_exchange_core/usage-rules.html).
This file is only what is **specific to Coinbase**.

## Start it, and it brings its own rate limiter

```elixir
children = [{DpExchange.Coinbase, credentials: my_credentials()}]
```

The venue supervises a limiter configured from the ceilings it declares. That is not a
convenience: `Core.HttpClient` fails closed when no limiter is reachable, so a venue
package that expected someone else to start one answers `{:error, "Rate limiter
unavailable"}` to everything.

Running two — two credentials, two scopes — needs distinct names:

```elixir
[{DpExchange.Coinbase, name: :cb_a, feed: :cb_a_feed, limiter: :cb_a_limiter},
 {DpExchange.Coinbase, name: :cb_b, feed: :cb_b_feed, limiter: :cb_b_limiter}]
```

## Credentials choose the endpoint; they do not gate it

Coinbase serves the same market data publicly and authenticated. Pass credentials and
this package uses the authenticated path, which has the higher ceiling. Pass none and it
uses the public one. The return is identical either way.

Declared as `credential_benefit: :higher_ceiling` — a boolean could only have said
"required" or "not", and neither is true here.

## Nine candle widths, and `12h` is not one of them

`1m 5m 15m 30m 1h 2h 4h 6h 1d`. The shared vocabulary models `12h`; **Coinbase does not
serve it**, and asking for it is an error rather than the nearest width.

That is not caution. A caller once received one-hour bars labelled four-hour, which the
backfill then stored tagged `4h` — every value real, every label wrong, and nothing
failed. Coinbase itself refuses an unknown width outright, measured 2026-08-28:

```
parsing field "granularity": "THREE_HOUR" is not a valid value
```

## 350 candles is a hard boundary, not a page size

Measured: 350 minutes of one-minute candles returns 349. **351 returns zero and an
error** — not the first 350.

This package refuses an over-wide range up front:

```elixir
{:error, {:range_too_wide, requested: 400, max: 350}}
```

Widening your window to "get more per call" gets you nothing, and nothing reads as *no
data for this period*. Page it yourself.

## Coinbase publishes no rate-limit headers

Measured: no `x-ratelimit-*`, no `retry-after`. The ceiling is not discoverable from a
response, so `capabilities/0` declares it and `measured_against` says where the numbers
came from — the granularities and the 350 boundary were probed against the live venue;
**the ceilings were not** and are inherited from a prior implementation.

If you have better numbers, that field is where to correct them.

## Refusal versus error

- `{:refused, :not_listed}` — Coinbase does not carry this symbol. Permanent. Stop asking.
- `{:error, {:unsupported_timeframe, tf}}` — a width it does not serve. Your mistake, not
  a transient one.
- `{:error, reason}` — everything else. Retry as your policy allows.

## Streaming

`subscribe/2` opens and manages a connection internally. You never see it, and
`coverage/1` reports what is **observed arriving** — a symbol you subscribed that has
delivered nothing is simply absent.

Public channels carry no token. Attaching one is actively harmful: Coinbase answers a
bogus token with an authentication failure, which is how a book channel once produced
nothing while the public ticker worked fine — a venue half-delivering looks like a quiet
market rather than a broken credential.

## Testing against this package

Use `DpExchange.Coinbase.Fake`, selected per process through `DpExchange.Core.Config`. It
is a real implementation of the facade that answers from memory, models Coinbase's
refusals — unlisted symbols, `12h`, the 350 boundary — and passes the same conformance
suite as the real adapter.

**Do not point tests at the live venue.** This package's own tier-2 tests do that, tagged
and excluded, run by hand. A venue that sees a package polling it on a timer will
rate-limit or block.

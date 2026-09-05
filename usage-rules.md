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

## Credentials choose the endpoint; they do not gate it — except one call

Coinbase serves almost all market data publicly and authenticated. Pass credentials and
this package uses the authenticated path, which has the higher ceiling. Pass none and it
uses the public one. The return is identical either way.

Declared as `credential_benefit: :higher_ceiling` — a boolean could only have said
"required" or "not", and neither is true for the package as a whole.

**`get_top_of_book/2` is the one exception.** The venue publishes no public form of
`/best_bid_ask` — confirmed live, `401` authenticated and `404` at the `/market/...` path
every other reader here has. Call it without credentials and it returns
`{:refused, :missing_credentials}` before sending anything, rather than surfacing the
venue's 401 as an opaque error.

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

### Frames are tagged with the symbol you subscribed, not whatever the venue renamed it to

Coinbase silently rewrites some product ids on delivery. Subscribing `ticker` to an
aliased `-USDC` pair (e.g. `XLM-USDC`) delivers every frame tagged with its `-USD`
counterpart instead — and the venue's own subscription acknowledgement echoes the
rewritten name back, not the one you sent. Measured live 2026-09-05 against
`wss://advanced-trade-ws.coinbase.com`; confirmed against the venue's own
`/market/products` catalogue, where 112 of the first 114 USDC products carried a
non-empty `alias` naming their `-USD` counterpart.

This package undoes that before a frame reaches you: every `Types.Quote` and
`Types.OrderBook` you receive is tagged with the symbol **you subscribed**, resolved
against the venue's own declared alias relationship — never the venue's rewritten name.
Subscribe to both names for a market the venue aliases and you get both, from the one
frame the venue actually delivers. `coverage/1` follows the same rule: it reports under
what you subscribed, never under what the venue renamed it to.

If the venue's product catalogue can't be fetched, attribution degrades rather than
guesses: frames deliver under whichever id the venue actually sent, and
`subscribe_notices/1` receives one `:data_quality` notice saying attribution is
degraded and why. There is no `-USDC`/`-USD` string-munging fallback — it would be wrong
for any pair the venue does not actually alias.

### `resubscribe_interval_ms` — re-issuing subscriptions is unconditional, and the cadence is diagnostic, not a knob to tune coverage with

A WebSockex reconnect resubscribes nothing on its own, so a dropped-and-restored socket
can come back up connected and silently subscribed to **nothing**. This package re-issues
every shard's current subscriptions on a timer to cover that, unconditionally.

```elixir
children = [{DpExchange.Coinbase, credentials: my_credentials(), resubscribe_interval_ms: 30_000}]
```

Default is **60,000 ms**, and it is a diagnostic knob, not a way to make coverage catch
up faster. A value shorter than one full re-issue cycle across your current shard count
is not honoured: this package derives the floor from the shard count that actually
exists — `(shards - 1) * 5_000ms + 8_000ms + 5_000ms` — and uses that instead, logging
the substitution, rather than wedging the feed with overlapping re-issue cycles queued
behind each other. That is a real, measured incident (DpCryptoManagement's issue #22):
it happened both from an explicit `resubscribe_interval_ms: 5_000` and from the 60s
*default* past twelve shards (1,101 symbols at 100/socket). There is no way to make this
package re-issue faster than that floor — only a log line explaining why it didn't.

## Testing against this package

Use `DpExchange.Coinbase.Fake`, selected per process through `DpExchange.Core.Config`. It
is a real implementation of the facade that answers from memory, models Coinbase's
refusals — unlisted symbols, `12h`, the 350 boundary — and passes the same conformance
suite as the real adapter.

**Do not point tests at the live venue.** This package's own tier-2 tests do that, tagged
and excluded, run by hand. A venue that sees a package polling it on a timer will
rate-limit or block.

## Two accounts, and only one of them margins a futures position

Advanced Trade's US derivatives sit in an account held with **Coinbase Financial Markets**;
spot sits in one held with **Coinbase Inc**. `get_futures_balance_summary/2` names both —
`cfm_usd_balance`, `cbi_usd_balance`, `total_usd_balance` — and **sizing a futures position
against the total is sizing against money that is not there.**

`get_positions/1` returns CFM positions. Its `:realised_pnl` is `nil` and that is not an
omission: the venue publishes `daily_realized_pnl`, which is what the position realised
*today*, and putting a daily number in a field that means the position's answers a different
question under the same name. `list_futures_positions/1` returns the venue's own row, where
that figure keeps its own name — along with `expiration_time`, which a future has and
`Types.Position` does not.

**A sweep is scheduled, not settled.** `schedule_futures_sweep/2` queues a move out of the
futures account; `list_futures_sweeps/2` reports the queue. **Omitting the amount sweeps
every available excess dollar** — the venue's default, not this package's.

`INTRADAY_MARGIN_SETTING_UNSPECIFIED` is the venue declining to say. It is **not**
`_STANDARD`, and this package will not map it to one.

## Prime is a different product, host and credential

`DpExchange.Coinbase.Prime` reaches Coinbase **Prime**'s nine custodial staking endpoints.
It talks to `api.prime.coinbase.com` and signs an HMAC under an access key, a passphrase and
a signing key — **the CDP key pair the rest of this package uses is not accepted there**, and
two of the three is refused locally rather than sent as a signature over the wrong string.

`stake/3` and `unstake/3` reach it, and **pick a scope only from what you said**: a
`:wallet_id` means the wallet, its absence means the portfolio, and `:portfolio_id` is always
required. A portfolio-scoped unstake redeems across *every* wallet in the portfolio.

These are **not** the CDP Staking API, whose seven endpoints return unsigned transactions for
you to sign and broadcast. If you hold one of those, nothing has been staked.

**Nothing in `Prime` has been run.** The paths come from the vendor's pages and the signing
scheme from its authentication documentation; this repository holds no Prime credential.

## Convert: two steps, and no expiry to rely on

`quote_conversion/4` holds a rate; `commit_conversion/2` accepts it. **Advanced Trade states
no expiry at all**, so `expires_at` is `nil` — which means "not stated", never "open-ended".
A lapsed quote can be filled at the *current* rate rather than refused, which is the
dangerous outcome because it looks like success and every number in it is real.

**Both accounts are re-asked on the commit and even on the read.** `opts[:from]` and
`opts[:to]` are required on `commit_conversion/2` and `get_conversion/2`, and this package
fills neither in from the quote: a conversion committed against accounts you did not name
happens between the wrong two balances.

## Portfolios are addresses, not values

"The account's BTC balance" is not a well-formed question here. `list_portfolios/1` names
them; `get_portfolio_breakdown/3` returns what is *inside* one, which is a much larger
answer. `create_account/1` and `rename_account/3` reach the portfolio endpoints, because
Advanced Trade has no notion of creating an *account*.

**Deleted portfolios stay in the listing.** The venue keeps them because old orders still
name their ids; filtering them out would make a historical id look like one that never
existed.

## Fees, volume, and a claim that was wrong

`get_fees/2` carries **both** `fee_tier` and `fee_tier_without_promotion` — they differ while
a promotion runs, and it can end between two calls. The tax's `INCLUSIVE`/`EXCLUSIVE` flag
survives too, because the same rate quoted either way is a different amount of money.

`get_trade_volume/2` was declared unsupported until 2026-09-01 on the claim that "Advanced
Trade does not aggregate" the account's own volume. **It does** — the transaction summary
carries `volume_breakdown` per volume type. The claim had been made from the *market* volume
endpoint's absence, which answers a different question. The two account totals ride alongside
the breakdown rather than being folded in: Advanced Trade volume is documented as
non-inclusive of Pro, so adding either to the breakdown double counts.

## Every negative here is audited

`docs/reference/coinbase/negative-claims.md` lists each one with the source and date
consulted. Three were wrong and are corrected; the table records what the pattern was, so it
is not repeated: **each was a true statement about one endpoint, restated as a claim about
the venue.**

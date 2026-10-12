# Using `dp_exchange_coinbase`

> **EXPERIMENTAL.** Not run in production. Pin three-part. Maturity is per endpoint —
> read `capabilities/0`, not this banner.

Everything general is in
[`dp_exchange_core`'s usage rules](https://hexdocs.pm/dp_exchange_core/usage-rules.html).
This file is only what is **specific to Coinbase**.


## A money-moving call is either keyed or sent once — never retried blind

`Core.HttpClient` retries a timeout or a 5xx three times by default, and that is safe only
when the venue can tell the second attempt from the first. This package makes that true one
of two ways, and which one it is depends on what the endpoint gives it:

- **Orders and Prime staking send an idempotency key**, generated when you do not supply
  one — `client_order_id` on Advanced Trade, `idempotency_key` on Prime, including
  `Prime.claim_rewards/4` — `StakingClaimRewardsRequest` requires one, so it is generated
  the same way the staking calls' bodies already are and retries the same way they do.
  Re-sending returns the original result instead of performing the action again, so the
  retries are kept. Supply your own (`request.client_order_id`, `opts[:idempotency_key]`,
  or your own key inside `opts[:body]` for `claim_rewards/4`) if you want to correlate or
  to make your OWN re-issued call idempotent — a generated key covers the retries this
  package makes, not a second call you make yourself.
- **Portfolio moves, futures sweeps, conversion commits, order edits and portfolio
  creates are sent once**: `transfer_internal/4`, `schedule_futures_sweep/2`,
  `commit_conversion/2`, `replace_order/4` and `create_account/1` (a portfolio create).
  None has a key the venue honours. Before 0.3.49 they were retried, so a timed-out move could move the funds
  twice. A transport error on one of these means **the outcome is unknown**: read the
  portfolio, sweep, conversion or order back before issuing it again.
- **BREAKING: `{:error, {:write_unconfirmed, key, reason}}` is the answer for an unconfirmed
  non-order write.** Returned by `transfer_internal/4`, `schedule_futures_sweep/2`,
  `cancel_futures_sweep/2`, `commit_conversion/2`, `create_account/1` / `rename_account/3` /
  `delete_portfolio/3`, `set_intraday_margin_setting/3`, and the Prime writes `stake/3`,
  `unstake/3` and `claim_rewards/4`, when the request MAY have reached the venue and success
  is not proven: a transport error or timeout after the send, a `5xx`, a `2xx` whose body is
  not an object or lacks what the result needs (a conversion commit with no `trade`, no id or
  a status this package does not know; a created portfolio with no uuid; a Prime stake with
  no `transaction_id`), or a `4xx` answered to an internal RETRY of a keyed Prime write.
  `key` is what was sent that you retry or reconcile by: the Prime `idempotency_key`
  (generated ones included), the trade id for a commit, the portfolio uuid for a delete, and
  `nil` where the venue gives the call no key (a move, a sweep, a create, a rename, a setting).
  Old -> new: those cases were a bare `{:error, {:exchange_error, :coinbase, _}}` or
  `{:error, :unexpected_response_shape}` (or, for a commit with an unreadable trade,
  `{:error, {:unknown_conversion_status, _}}` / `{:error, {:missing_required_field, :id}}`),
  all of which read as "nothing happened". A venue `4xx` answered to the first attempt
  (any status except 429, which is a plain `{:error, _}`) answers `{:refused, _}` (Prime
  writes keep their own refusal set). Validation, credentials, our own rate limiter refusing before a send and
  a signing failure stay plain `{:error, _}`.
- **`{:error, {:replace_accepted_unread, order_id, reason}}` from `replace_order/4`
  means the edit WAS applied.** The read-back of the order failed afterwards. Do not edit
  again; read the order with `get_order/3`. (It was `:edit_accepted_refetch_failed`.)
- **`{:error, {:order_unconfirmed, client_order_id, reason}}` from `place_order/3`,
  `close_position/3` and `replace_order/4` means the order MAY exist.** It is returned when
  the request may have reached the venue and success is not proven: a transport error or
  timeout after sending (including retries exhausted), a 5xx, a `2xx` that is not a map or
  carries no `success`, a `success: true` without a readable `order_id`
  (`{:order_unconfirmed, cid, {:missing_required_field, :order_id}}`; it was
  `{:ok, %Order{id: nil}}`), and `DUPLICATE_CLIENT_ORDER_ID` (an earlier attempt, possibly this
  call's own internal retry, was placed). `client_order_id` is the id actually sent,
  **including one this package generated**; for `replace_order/4` it is `nil` (an edit has
  none). Look the order up with `get_orders/2` before sending again, and send the SAME
  `client_order_id` to retry. Errors decided before sending (validation, credentials, our
  own rate limiter, a signing failure) stay plain `{:error, reason}`; **any `4xx` answered to
  the FIRST attempt** (400, 401, 403, 404, and now 409, 415, 422 and every other, as
  `{:refused, {:venue_error, status, message}}`) is the venue answering and is
  `{:refused, _}`, except **429**, which is throttling and a plain `{:error, _}` (these
  were `{:order_unconfirmed, ...}` before); a `4xx` or 429 answered to an internal RETRY is
  unconfirmed. Before this a retries-exhausted place
  returned a bare `{:error, "Request failed..."}` with no id, a success-less `2xx` returned
  `{:error, :unexpected_response_shape}`, and a duplicate-id answer was
  `{:refused, {:order_rejected, "DUPLICATE_CLIENT_ORDER_ID"}}`.
- **Transport failures keep Core's tag**: `{:error, {:exchange_error, :coinbase, message}}`.
  They used to arrive as the bare message string.
- **A `404` on an order, account, portfolio or conversion is `{:refused, :not_found}`.**
  `{:refused, :not_listed}` is for symbols only.
- **No credentials means no private call.** `nil` and `%{}` both mean none: a private
  endpoint answers `{:error, {:missing_credentials, :coinbase}}` locally, and a public
  market-data call carrying `%{}` takes the unsigned `/market` path.
- **A fill with `size_in_quote: true` fails `get_trade_history/2`** with
  `{:error, {:unsupported_fill_size_unit, :quote}}`: `Fill.quantity` is base currency and
  the venue does not say the size was converted.

## BREAKING — `Quote` and `OrderBook` no longer carry `:timestamp`

They carry **`:venue_time`** (the venue's own, `nil` where the venue publishes none) and
**`:observed_at`** (when this package read it, always present) — the shape
`Core.Types.TopOfBook` has always had. Introduced with `dp_exchange_core ~> 0.2.1`; this package now requires `~> 0.3.50`.

```elixir
# before
quote.timestamp

# after
quote.venue_time  # may be nil — the venue did not date this
quote.observed_at # always present
```

**Why it had to break.** `:timestamp` was documented as the venue's own, "never invented",
and two packages in this family could not keep that promise: the frames they decode carry no
venue time at all. With one field their only options were to lie or to drop real data, and
they lied. Now they can say `nil` and mean it.

**What to do with `nil`.** Whatever you would have done with a wrong answer, but knowingly.
The consumer who decided this design stores `venue_time` as their time-series point time
where it is present, and where it is `nil` stores `observed_at` **and records that they
did** — so a mis-bucketed value is attributable rather than invisible. That decision was not
expressible before, because there was no way to see which kind of time you had.

`Trade`, `Fill`, `Balance` and `OrderBookDelta` are **unchanged** — they keep a single
`:timestamp`, because every one of them is built from a venue-supplied time and fails closed
without it.


**When is `venue_time` `nil` on this venue? On a streamed `Quote`, always; and on a
`TopOfBook` from `get_top_of_book/2` when the pricebook has no readable `time`.** BREAKING
(MD7): a `Quote` from the `ticker` stream carried the message envelope's `timestamp`, which
the spec defines as "Server time the message was sent", as its `venue_time`; the `Ticker`
row states no trade time, and the `snapshot` event sent at every (re)subscribe is not a
trade at all, so the streamed `Quote.venue_time` is now `nil` (use `observed_at`). The REST
`get_price/2` still carries the latest trade's own `time`, and every `OrderBook` still carries
the trading engine's `event_time` and fails closed without one.
`get_top_of_book/2` reads `/best_bid_ask`, and a pricebook that arrives without a parseable
`time` yields `venue_time: nil` rather than either refusing the quote or stamping it with
our clock — the bid and the ask are real, `observed_at` still says when we looked, and that
is the honest freshness for a top-of-book read. Depth is the stricter case and is refused,
because a stale book read as current is a more expensive wrong number than a stale quote.

So: branch on `nil` if you stream quotes or use `get_top_of_book/2`.

This section used to say "It never is", full stop, and a consumer who believed it and wrote
no `nil` branch would have crashed on exactly that one shape. Other venues in the family
return `nil` far more widely, which is why the field is nullable in the contract.

Full reasoning and the options that were weighed:
[`dp_exchange_core` issue #31](https://github.com/DistortionPoint/dp-exchange-core/issues/31).

## Start it, and it brings its own rate limiter

```elixir
children = [{DpExchange.Coinbase, credentials: my_credentials()}]
```

The venue supervises a limiter configured from the ceilings it declares. That is not a
convenience: `Core.HttpClient` fails closed when no limiter is reachable, so a venue
package that expected someone else to start one answers `{:error, "Rate limiter
unavailable"}` to everything.

**Which of the two declared ceilings the limiter is configured from follows whether you
passed `credentials:` above** — see "Credentials choose the endpoint" below. Pass none
and the limiter runs at `public_ceiling`; pass a non-empty credential map and it runs at
`authenticated_ceiling` instead, matching whichever request path `Rest` actually takes for
this instance.

Running two — two credentials, two scopes — needs distinct names:

```elixir
[{DpExchange.Coinbase, name: :cb_a, feed: :cb_a_feed, limiter: :cb_a_limiter},
 {DpExchange.Coinbase, name: :cb_b, feed: :cb_b_feed, limiter: :cb_b_limiter}]
```

## A connect that never finishes ends at a deadline, and a malformed close frame is a reconnect

Two things this package's socket does that the `websockex` library it is built on does not.
Both come from a private, patched fork of websockex 0.5.1's process loop,
``DpExchange.Coinbase.Vendor.WebSockex``, carried from `dp_exchange_webull` on 2026-09-27.

- **The opening handshake has a deadline**: `socket_connect_timeout` plus
  `socket_recv_timeout`. Upstream bounds each read of the upgrade response separately, so
  a peer that trickled the response held a connect open indefinitely. A connect that
  misses the deadline now fails with `%WebSockex.ConnError{original: :timeout}`, the same
  error a plain read timeout gives. On a reconnect, that means backoff and another try, not
  a socket stuck connecting.
- **A close frame with an invalid status code disconnects.** Upstream raised on it and
  crashed the socket before its reconnect logic ran. It now produces an ordinary
  `:link_down` and reconnect.

**This package depends on `{:websockex, "== 0.5.1"}` exactly.** The fork calls that
release's internals. If your application pins a different websockex version, dependency
resolution will fail, so resolve to 0.5.1.

**The WebSocket verifies the venue's TLS certificate** (2026-09-27). websockex's own
default is not to (`verify: :verify_none`), and until then this package connected with
that default, accepting any certificate. It now uses the operating system's trust store and
HTTPS hostname rules. On a host with no system CA bundle the connection fails with a TLS
error rather than connecting unverified. Pass your own `:ssl_options` to override.

## A shard's socket crash costs one shard, never your whole subscription

Each `level2`/`ticker` shard runs on its own socket, and that socket is a **linked**
child of `Feed` — not a supervised sibling you can restart independently. As of this
version `Feed` traps exits, so a shard's socket dying abnormally no longer takes `Feed`
down with it: only that one shard's symbols drop out of `coverage/1` and
`coverage_by_kind/1` (only the `data_kind()` its channel carries — a `level2` crash
never touches a symbol's `ticker` coverage), you get a `:link_down` `Core.Notice`
naming which shard and why, and this package reopens that shard on its own, immediately,
without you calling `subscribe/2` again. A shard that crashes again within five minutes of
its last crash is reopened after a growing wait (1s, 2s, 4s, capped at 60s) rather than in
a tight loop; a shard that stayed up longer starts again at "immediately".

**What still costs you your whole subscription: `Feed` itself crashing** — a bug outside
the socket-crash path, or anything that kills the `Feed` pid directly.
`DpExchange.Coinbase.Supervisor` restarts `Feed` under `:one_for_one`, but from the
*static* `opts` your supervision tree started it with; every `subscribe/2`,
`update_symbols/2` and `subscribe_notices/1` call you made afterward is gone; `coverage/1`
reads empty until you call `subscribe/2` again. Nothing inside this package can replay
those calls — it never held onto the functions or the process that made them. If your
consumer needs to survive a `Feed` restart unattended, monitor the `Feed` pid (or the
`DpExchange.Coinbase` pid it sits under) yourself and re-issue `subscribe/2` on `:DOWN`.

**Your `api_key`/`api_secret` will not appear in the crash log.** `Feed` and `Socket`
both hold your credential for as long as they run, and a crash of either logs that
process's state via OTP's default crash report — which is where you *would* see it,
because a crash report prints unredacted `Logger` metadata otherwise. Both processes
wrap the pair in a struct before it ever reaches state, so the crash line reads
`credentials: #DpExchange.Coinbase.Credentials<...>` rather than the key pair itself.
This is not a claim about your own code: if you read `state.credentials` yourself via
`:sys.get_state/1` or similar, you get the same struct — call `Map.from_struct/1` on it
to get the plain map back.

## Credentials choose the endpoint; they do not gate it — except one call

Coinbase serves almost all market data publicly and authenticated. Pass credentials and
this package uses the authenticated path, which has the higher ceiling. Pass none and it
uses the public one. The return is identical either way.

Declared as `credential_benefit: :higher_ceiling` — a boolean could only have said
"required" or "not", and neither is true for the package as a whole.

**`get_top_of_book/2` is the one exception.** The venue publishes no public form of
`/best_bid_ask` — confirmed live, `401` authenticated and `404` at the `/market/...` path
every other reader here has. Call it without credentials and it returns
`{:error, {:missing_credentials, :coinbase}}` before sending anything, rather than
surfacing the venue's 401 as an opaque error. Not `{:refused, _}`: the credential never
left this process, so nothing at Coinbase ever saw a request to decline.

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

An empty or inverted window (`start` at or after `end`) is refused too, as
`{:error, {:invalid_range, start: start, end: end}}`. The venue's answer to one is
unmeasured, and an empty list would read as *no data*. So is a `range` that is not a
keyword list, or a `:start` / `:end` that is not a `DateTime` (`nil` means absent): the
same `{:invalid_range, _}`, never a raise in your process.

**The forming bar, the range and `:limit` (BREAKING).** `get_historical_prices/4` no longer
returns the bar still forming (`opened_at + width > now`; the end defaults to now, so it used
to be the last element): pass `include_partial: true` to get it, as the venue sent it (it may
still change; `Candle` has no flag for that). `range[:start]` is **inclusive** and
`range[:end]` **exclusive** on `opened_at`, filtered client-side because the venue's own
treatment of the bounds is unmeasured (only a bound you passed is filtered on). `:limit`
(1..350, the venue's `limit`) is now sent; it used to be ignored. Anything else is
`{:error, {:invalid_option, :limit, v}}`, and a non-boolean `:include_partial` is
`{:error, {:invalid_option, :include_partial, v}}`. A candle open/high/low/close of zero or
less refuses the reply (`{:error, {:non_positive_price, field, value}}`).

`get_order_book/2` checks its options the same way before any request. BREAKING (MD5): the
depth option is **`:depth`** (levels per side), sent as the venue's `limit`; `:limit` is
`{:error, {:unsupported_option, :limit}}`. `:depth` must be a positive integer within `int32`
(`{:error, {:invalid_option, :depth, v}}`; it was `{:invalid_limit, v}`, and `0` was
allowed), and `:aggregation_price_increment` a finite positive number
(`{:error, {:invalid_aggregation_price_increment, v}}`). It is sent in plain notation. A
level with size `0` is dropped from the book (it is no liquidity), and a level with a price
of zero or less or a negative size refuses the whole book, on REST and on the stream alike.

`get_trades/2` sends `opts[:since]` as the ticker's `start` and `opts[:end]` as its `end`
(a `DateTime` each; anything else is `{:error, {:invalid_option, key, v}}`), where it used to
send only `limit`. A `:since` read that returns exactly `limit` rows may have a hole and is
`{:error, :history_truncated}`. A trade (or quote) price of zero or less refuses the reply
(`{:error, {:non_positive_price, :price, value}}`; an unreadable one keeps
`{:invalid_decimal, field, value}`).

## Coinbase publishes no rate-limit headers

Measured: no `x-ratelimit-*`, no `retry-after`. The ceiling is not discoverable from a
response, so `capabilities/0` declares it and `measured_against` says where the numbers
came from — the granularities and the 350 boundary were probed against the live venue;
**the ceilings were not** and are inherited from a prior implementation.

If you have better numbers, that field is where to correct them.

## Refusal versus error

- `{:refused, :not_listed}` — Coinbase does not carry this symbol. Permanent. Stop asking.
- `{:refused, {:venue_error, status, message}}` — a `400`, `401` or `403`: the venue
  received the request and declined it, in its own words. Permanent **for the request as
  sent** — a caller whose key was rotated signs again with the new one, which is a
  different request rather than a retry of this one. The message is cut at 2,048 characters.
- `{:error, {:unsupported_timeframe, tf}}` — a width it does not serve. Your mistake, not
  a transient one.
- `{:error, {:missing_credentials, :coinbase}}` — this call needs a credential and was not
  given one, detected here before anything was sent. Never `{:refused, _}`: the venue
  received no request to decline.
- `{:error, reason}` — everything else. Retry as your policy allows.

### The 4xx statuses are read from the status, not from the message text

Worth stating because the previous behaviour was wrong in both directions and a consumer
may have built around it. This package used to recover the HTTP status by searching the
flattened error string for `"404"`, which meant:

- a 4xx whose **body** happened to contain `"404"` — an order id, a price, a vendor
  code — came back `{:refused, :not_listed}`: permanent, never retried, for something that
  may well have been transient; and
- a `400`, `401` or `403` contains no `"404"` anywhere, so a bad request or a **rejected
  credential** fell through to a bare `{:error, message}` and read as possibly-transient —
  a rotated key retried instead of refused.

Both are fixed; the status is now matched exactly, as the other four venue packages in
this family already did. **If you were matching `{:error, message}` for authentication
failures, they now arrive as `{:refused, {:venue_error, 401, _}}`.**

## Signing failures stop here, rather than being sent unsigned

A credential that cannot produce a signature — a malformed `api_secret`, or a map missing
`:api_key` / `:api_secret` — refuses **locally**, before anything is sent:
`{:error, :invalid_base64}`, `{:error, {:unsupported_key_size, n}}`,
`{:error, :unsupported_key_format}`, or `{:error, {:missing_credentials, :coinbase}}`.

A **blank or whitespace-only** `api_key` or `api_secret` is `{:missing_credentials,
:coinbase}` as well (it used to sign `kid: ""`, or answer `{:unsupported_key_size, 0}`). A
value with **leading or trailing whitespace**, such as a `.env` value with its newline, is
refused `{:error, {:invalid_credentials, :coinbase}}` rather than trimmed and signed; the
value is never echoed. The Fake refuses identically (it shares `Auth.check_credentials/1`),
and `get_price/2` in the Fake refuses a malformed `credentials:` the way the real call does,
while still taking none (`nil` or `%{}`) as the public path.

Only Ed25519 keys sign: `api_secret` is the Base64 of a 32-byte seed or a 64-byte
seed-plus-public-key. A PEM block (the form an ECDSA key takes) answers
`:unsupported_key_format`, which is the key type being refused rather than an encoding
fault. It is not converted.

This package used to drop the `Authorization` header and send the request anyway. On a
public market-data `GET` that is harmless — Coinbase serves those anonymously. On a
**write** there is no public path, so `place_order/3` and every other POST went to the
venue unauthenticated and came back an opaque `401` that reads like a problem with your
account rather than with the key you passed. **An unsigned token is worse than none.**

## Streaming

`subscribe/2` opens and manages a connection internally. You never see it, and
`coverage/1` reports what is **observed arriving** — a symbol you subscribed that has
delivered nothing is simply absent.

Public channels carry no token. Attaching one is actively harmful: Coinbase answers a
bogus token with an authentication failure, which is how a book channel once produced
nothing while the public ticker worked fine — a venue half-delivering looks like a quiet
market rather than a broken credential.

### Neither `:order_book` nor `:quotes` requires a credential to stream

`capabilities/0` says so: `streamable` is `[:quotes, :order_book, :trades]` and
`authenticated_streamable` is `[]`. Without credentials this package still subscribes both
`ticker` and `level2` — `SubscribeLevel2`'s own JWT is documented "Optional here;
recommended for connection reliability.", not required, unlike `SubscribeUser`'s.

This used to declare `authenticated_streamable: [:order_book]` and skip `level2` entirely
for a credential-less caller, on the reasoning that the venue would refuse an unauthenticated
book subscribe outright. It does not. A credential still buys `level2` something —
`credential_benefit: :higher_ceiling` and the venue's own "connection reliability" note both
apply — so pass one when you have it even if you only want the book.

### Frames are tagged with the symbol you subscribed, not whatever the venue renamed it to

Coinbase silently rewrites some product ids on delivery. Subscribing `ticker` to an
aliased `-USDC` pair (e.g. `XLM-USDC`) delivers every frame tagged with its `-USD`
counterpart instead — and the venue's own subscription acknowledgement echoes the
rewritten name back, not the one you sent. Measured live 2026-09-05 against
`wss://advanced-trade-ws.coinbase.com`; confirmed against the venue's own
`/market/products` catalogue, where 112 of the first 114 USDC products carried a
non-empty `alias` naming their `-USD` counterpart.

This package undoes that before a frame reaches you: every `Types.Quote`,
`Types.OrderBook` and `Types.OrderBookDelta` you receive is tagged with the symbol **you
subscribed**, resolved against the venue's own declared alias relationship — never the
venue's rewritten name. Subscribe to both names for a market the venue aliases and you
get both, from the one frame the venue actually delivers. `coverage/1` follows the same
rule: it reports under what you subscribed, never under what the venue renamed it to.

If the venue's product catalogue can't be fetched, attribution degrades rather than
guesses: frames deliver under whichever id the venue actually sent, and
`subscribe_notices/1` receives one `:data_quality` notice saying attribution is
degraded and why. There is no `-USDC`/`-USD` string-munging fallback — it would be wrong
for any pair the venue does not actually alias.


### Choose your channels — `level2` is opt-out

If you route order-book depth over REST, or simply do not read books, say so at start:

```elixir
children = [{DpExchange.Coinbase, credentials: creds, channels: [:quotes]}]
```

The vocabulary is `capabilities().streamable`'s data kinds — `:quotes`, `:order_book` and
`:trades` — not this venue's channel names. Omit the option and you get `:quotes` and
`:order_book`, exactly as before; `:trades` is opt-in.

**What it saves is not small.** `level2` shards at 30 pairs per socket, so a 406-pair scope
opens **14 `level2` sockets** on top of its 5 `ticker` shards. A consumer reading only
quotes measured **1,577,001 `OrderBookDelta` frames decoded and delivered in one boot**, all
discarded. Ignoring them on receipt saves nothing — the sockets are open and the frames are
parsed before they reach you.

One thing the option deliberately does not do:

- **It refuses an empty list**, loudly, at `init/1`. A feed subscribing to nothing reports
  permanent zero coverage, which is indistinguishable from a venue outage. If you want no
  stream, do not start a feed.

**`level2` no longer requires a credential to be attempted.** `SubscribeLevel2`'s JWT is
documented "Optional here; recommended for connection reliability."
(`docs/reference/coinbase/openapi/at-async.json`) — a credential-less feed still opens
`level2` shards and subscribes unauthenticated; it is `user` (order fills) that genuinely
needs one. A credential still buys you something on `level2`: the venue's own words say it
helps "connection reliability", so pass one when you have it even if you only want the
book.

A kind this venue does not stream (`:candles`, say) also fails at `init/1` rather than being
silently dropped.

### `:trades` — the public trade tape, opt-in, and its history is NOT replayed

```elixir
children = [{DpExchange.Coinbase, channels: [:quotes, :order_book, :trades]}]
```

`:trades` subscribes Coinbase's public `market_trades` channel (no credential) and delivers
each print as a `DpExchange.Core.Types.Trade`. It is **not** in the default, which stays
`[:quotes, :order_book]`: ask for it by name, and expect one more stream per symbol.

- **`side` is the taker's** — who removed liquidity — as the contract defines it. The venue
  reports the *maker's* side ("The maker's side of the trade.") and this package flips it, so
  a venue `BUY` arrives as `:sell`. `side` is `nil` for a value that is neither `BUY` nor
  `SELL`; check it. `broken` is always `false`: the channel has no bust flag.
- **The `snapshot` the venue sends first is dropped.** Every subscribe, resubscribe and
  reconnect begins with a `snapshot` of recent history. Delivering it would repeat the same
  prints on every reconnect and double count any consumer that sums quantities, so only
  `update` events are delivered. **The consequence: prints made while a connection was down
  are lost, and nothing backfills them.** Treat `:link_up` after a `:link_down` as a gap in
  your tape and repair it with `get_trades/2` if you need it complete.
- **`coverage_by_kind/1` reports `:trades` only once an `update` has arrived** for the symbol.
  The dropped snapshot is deliberately not coverage, so a quiet pair reads as not yet
  delivering rather than delivering.
- **An unreadable trade is a `:data_quality` notice, not a dropped row or a filled-in one**
  (missing id, non-numeric price or size, unparseable time).
- `market_trades` shares `ticker`'s 100-pairs-per-socket sharding. That figure is **not
  measured** for this channel, and the venue publishes no ceiling for it. The frame shape and
  the side direction were observed live on 2026-10-02 (BTC-USD, about 10 seconds).
- The fake takes the same option per call: `Fake.subscribe(symbols, channels: [:quotes,
  :trades])` pushes one `Trade` per symbol and reports `:trades` in `coverage_by_kind/1`.

### `level2` delivers deltas, not a maintained book — BREAKING as of 0.2.0

**Before 0.2.0**, subscribing `level2` delivered a full `Types.OrderBook` on every frame,
including a single-row `update` — this package held the book itself and rebuilt it on
your behalf. That was market state duplicated inside a socket process for no reason a
consumer could see, and it was expensive enough to threaten this package's own job: at
the book size DpCryptoManagement measured live for `BTC-USD` (~22,800 bid / ~21,100 ask
levels), rebuilding it cost 65–110 ms on the same single-threaded process responsible for
sending your subscribe frames, capping throughput and starving `ticker`.

**As of 0.2.0**, this package holds no book, and you receive exactly what the venue sent:

* A `snapshot` frame (once per subscribe, or resubscribe) delivers a `Types.OrderBook` —
  the venue's whole book at that moment, `bids` and `asks` sorted best-price-first, as
  the contract always promised.
* An `update` frame delivers a `Types.OrderBookDelta` — the venue's own changed rows, in
  the venue's own order, both sides interleaved exactly as the frame carried them.
  `levels` is a flat `[{side, price, quantity}]` list rather than split into
  `bid_levels`/`ask_levels`, because one delta frame can change both sides at once and a
  per-side split would either drop the venue's ordering or invent one it never sent.
* **A `quantity` of zero means that price level ceased to exist — not a price of zero.**
  This package carries that through unresolved; it does not drop the row, and it does not
  fold it into anything held here. If you want a maintained book, you build and hold it
  yourself from the stream of deltas — that is now genuinely your job, not a trap this
  package used to spring on whoever forgot to check.

**A gap can open without a reconnect, and you are told when it does.** The venue numbers
every message on a connection and says its servers can drop messages even though the
transport is TCP. This package checks that numbering. A jump raises a `:data_quality`
notice with `details.reason: :sequence_gap` and the number of messages lost. `details.symbols`
lists every symbol the connection delivers, **under the names you subscribed**: a symbol the
venue renamed (see "Frames are tagged with the symbol you subscribed" above) is listed as you
asked for it, not as the venue tagged it, and one you no longer want is left out. The
numbering is per connection, so any of those could be the one that lost a message. Treat it
exactly as `:link_up` below: the book you built from deltas is no longer reliable, so
re-read it. This package does it for you: on a gap it re-issues the `level2` subscription of
the connection that gapped (at most once per five seconds per shard), and the venue answers a
subscribe with a fresh snapshot. A frame whose sequence number is not above the last one
applied is dropped, never applied. A `level2` snapshot level with size `0` is dropped; a delta
keeps its zero, which means "remove this price".

**A `:data_quality` fault is reported once per connection, not once per frame.** The same
channel, product and kind of reason on the same connection raises one notice; every frame
carrying it is still dropped. After a reconnect a fault that persists is reported again.

**A level2 event with an unreadable row is not delivered at all.** The event raises **one**
`:data_quality` notice (it names the first unreadable row; `details.bad_rows` counts them),
and the snapshot or delta it came in is dropped whole. Delivering the rest would hand you a
book missing a level, or a delta leaving a removed level standing. A
message older than one already delivered is dropped, as the venue advises,
with `details.reason: :out_of_order` (at most one such notice a second per connection;
`details.suppressed` counts the late messages withheld since the last one). If several such
messages arrive in a row, counting up
one at a time, the baseline this package held was wrong, not the messages. It adopts the
venue's numbering, says so once with `details.reason: :sequence_reset`, and delivers
again. Treat that like a gap: re-read the book.

**Reconnect reconciliation is now your problem, and here is what to reconcile with.** A
dropped-and-restored connection does not promise the deltas after it are contiguous with
the deltas before it. `subscribe_notices/1`'s `:link_down` and `:link_up` bracket where a
gap may have opened; neither that notice nor anything else reconstructs a missing delta.
The correct response to `:link_up` is to re-pull `get_order_book/2` (unaffected by any of
this) or accept the venue's own fresh `snapshot` on resubscribe — not to keep applying
deltas across the gap and hope they still line up. Coinbase's `level2` channel does not
publish a book sequence number, so `:sequence` on both types is always `nil` here; where a
venue does publish one, it is the other half of this reconciliation.

### `resubscribe_interval_ms` — re-issuing subscriptions is unconditional, and the cadence is diagnostic, not a knob to tune coverage with

A WebSockex reconnect resubscribes nothing on its own, so a dropped-and-restored socket
can come back up connected and silently subscribed to **nothing**. This package re-issues
that shard's subscriptions **the moment its socket reconnects**. Only the shard that
dropped is re-issued, so there is no minute of silence waiting for the next timer tick. On
top of that it re-issues every shard's current subscriptions on a timer, unconditionally,
for what a reconnect report cannot cover: a channel the venue quietly stops serving on a
connection that never dropped.

**Nothing is sent to a shard while its socket is reconnecting.** A reconnecting socket is
asleep in its backoff and answers no frame, and each frame sent to one used to block this
package for five seconds. During a venue outage, with every shard down at once, that
stalled it long enough for your own calls to time out. Frames for such a shard are now
skipped, and nothing is lost by it, because the reconnect re-issues the shard's whole
membership.

```elixir
children = [{DpExchange.Coinbase, credentials: my_credentials(), resubscribe_interval_ms: 30_000}]
```

Default is **60,000 ms**, and it is a diagnostic knob, not a way to make coverage catch
up faster. A value shorter than one full re-issue cycle across your current shard count
is not honoured: this package derives the floor from the shard count that actually
exists — `(shards - 1) * shard_spacing_ms + 5_000ms` — and uses that instead, logging the
substitution, rather than wedging the feed with overlapping re-issue cycles queued behind
each other. That is a real, measured incident (DpCryptoManagement's issue #22): it
happened both from an explicit `resubscribe_interval_ms: 5_000` and from the 60s
*default* past thirteen shards, when `shard_spacing_ms` defaulted to 5,000ms. At the current
1,000ms default the 60s default is extended from **57 shards** upward. There is no way to
make this package re-issue faster than that floor — only a log line explaining why it
didn't.

**Shard count counts `level2` and `ticker` separately, and `level2` needs more of them than
`ticker` does** — see the next section. Fifty-seven shards is reachable from `level2` alone
once your universe passes 1,680 symbols at the default 30 per socket (`ceil(1_681 / 30)`),
and sooner once `ticker` and `market_trades` shards are counted beside it.

**A shard whose socket never opened at all is retried on this same cadence, and it says
so.** A transient connect failure on a shard beyond the first (a brief DNS blip, a refused
connection) used to have no automatic recovery — nothing re-asked the venue for it until
you called `subscribe/2` or `update_symbols/2` again yourself, which may never happen if
your scope is stable after boot. It is now retried on every unconditional tick alongside
already-open shards' own resubscribes, and `subscribe_notices/1` receives a
`:coverage_change` notice the moment the attempt fails — the same kind a channel that
never subscribed already produces — so you learn about it rather than inferring it from a
symbol that quietly never joined `coverage/1`.

### `level2` shards far more finely than `ticker`, and ramps in more slowly because of it

`level2` has a per-session product ceiling `ticker` does not; Coinbase names the failure
(`"too many L2 streams requested in a single session"`) but documents no number, and this
package cannot bisect a live authenticated session to find one itself — see this file's
own "Do not point tests at the live venue" rule, which applies to this package's own
development as much as to yours.

**The ceiling is now measured, not merely bounded from below.** A consumer holding real
credentials — this repo structurally never does — bisected it live on 2026-09-06:
`n = 6/12/25/30` accepted, `n = 31/35/50/100` refused, the boundary confirmed by
interleaving two runs back to back and by a contamination check ruling out the refusals
being an artefact of rapid probing rather than a genuine per-session ceiling. `30` is the
largest value with positive evidence of acceptance; `31` is the smallest with positive
evidence of refusal. No Coinbase document states this number even now — it is measured
venue behaviour, not a documented figure.

So `level2` groups symbols at **30 per socket by default**, independent of and smaller
than `ticker`'s 100 — and, as of this version, that `30` is a supervision option you can
change, not only a constant you have to wait on a release to see moved. A universe that
needs 5 `ticker` sockets needs 14 `level2` sockets for the
same 406-symbol scope (19 total), and every one of them — either channel — is staggered
onto the same connect sequence `shard_spacing_ms` already describes below, with every
`ticker` shard ordered ahead of every `level2` shard so `ticker`'s own boot-time coverage
is unaffected. For a 406-symbol universe at the current `1_000`ms default, that means
`level2` coverage ramps in over roughly 18 seconds rather than seconds — materially slower
than `ticker`, and an accepted cost against the alternative: `order_book` coverage that
never moved off a handful of symbols at all before this package sized the two channels
apart.

A symbol whose `level2` subscribe the venue refuses is never marked covered for
`:order_book` — `coverage/1` and `coverage_by_kind/1` report only what actually arrived,
never what was merely asked for — and a refusal reaches `subscribe_notices/1` as a
`:rate_limited` `Core.Notice` every time the venue sends one. The venue has also been
observed answering a refusal while still delivering books for part of the same oversized
request — an unexplained, dated venue characteristic recorded in
`docs/reference/coinbase/level2-session-limit.md` — and `coverage/1` /
`coverage_by_kind/1` need no special handling for it: both report only symbols that
actually delivered a payload, entirely independent of whatever notice accompanied them.

**A `level2` shard whose membership changes reconciles on its EXISTING socket, unsubscribing
departing symbols before subscribing arriving ones.** If your universe changes over time —
symbols added, removed, or rotated — an already-open `level2` shard never gets a new
connection just because it gained a symbol; it unsubscribes whatever it is losing, then
subscribes whatever it is gaining, on the same session, in that order, every time. The
order is load-bearing, not incidental: DpCryptoManagement measured live (2026-09-07) that
releasing a batch before requesting the next keeps a session's concurrent count within its
own ceiling and gets accepted, while requesting before releasing gets refused — so shrinking
always happens before growing, keeping this shard's own concurrent product count at or under
`level2_pairs_per_socket` at every instant of a reconcile, not only at rest. A shard that
only loses symbols, or only gains, takes the identical path with the unused half simply
empty. This is an internal mechanism, not a new call you make, but a transient send failure
on the unsubscribe half can mean a very brief coverage gap for the newly-added symbols while
it retries, reported the same way any other failed subscribe is: `subscribe_notices/1`
receives a `:coverage_change` notice, and `coverage/1` simply does not show them covered
yet.

**A departure that could not be confirmed sent is retried on the unconditional
60-second cycle, not silently forgotten.** If a shard's own unsubscribe keeps failing
until this package gives up on it (rare — a socket has to keep refusing to accept the
frame at all, not merely refuse the request), those symbols are recorded internally as
still owed a release and retried automatically on the same unconditional resubscribe
cadence `resubscribe_interval_ms` already governs, always ordered ahead of that shard's
own resubscribe on the same tick. You do not manage this yourself; it exists so a
stranded release cannot quietly consume a shard's budget forever. `subscribe_notices/1`
reports the give-up the same way any other failed subscribe is reported, and reports
nothing further once the retry succeeds.

### `level2_pairs_per_socket` — a supervision option, so a venue-side change doesn't need a release

```elixir
children = [{DpExchange.Coinbase, credentials: my_credentials(), level2_pairs_per_socket: 25}]
```

Default is **30** — DpCryptoManagement's own measured ceiling, live-bisected against the
real venue on **2026-09-06** (see above). Pass a larger or smaller value and every
`level2` shard chunks to it from boot instead.

**Below 1, or not an integer, is refused at start** — `Feed.start_link/1` (and therefore
your own supervision tree's `start_link/1`) fails with an `ArgumentError` rather than
silently running with a value that could never have sized a shard.

**Above 30 is honoured, not capped — with a loud warning, not a silent one.** This
package cannot verify Coinbase's real ceiling itself (see above — that would be tier-3,
authenticated, live probing, which this repo never runs), so it does not get to assume a
value you set above today's measurement is wrong. It logs the measured ceiling, the date
and source, and the concrete risk before proceeding — stated as what has actually been
observed, not more than that. Setting this above `30` means every ordinary `level2`
subscribe this package sends for that shard is, by itself, a single subscribe over the
venue's real limit. DpCryptoManagement measured exactly that shape, 2026-09-07 (issue #22
continuing): one socket, `n = 30` accepted, then `n = 60` and `n = 120` both **REFUSED**
— `rate_limited`, `books=0`, nothing delivering, in both ascending and largest-first
order. The refusal is **wholesale**, not truncated to the first 30 — the whole shard's
coverage is lost — and **the socket survives**: no disconnect, `Process.alive?/1` true
after a 40-second drain, both orderings. That is the same behaviour cumulative overage
already showed (two smaller subscribes, refused but alive) — the two shapes this package
used to distinguish between now read as one. It also makes the risk *harder* to notice
than the original 2026-08-26 incident implied, not easier: a closed socket announces
itself through a disconnect and a reconnect; a refused subscribe on a socket that stays
alive announces nothing — no error beyond the `:rate_limited` `Core.Notice`, liveness
looks perfect, and the shard simply never starts delivering. `coverage/1` and
`coverage_by_kind/1` are what reveal it, because they report only symbols that actually
delivered a payload. The 2026-08-26 incident itself (a refusal that *did* close the
socket) stays on record — the 2026-09-07 measurement could not reproduce it, and neither
this package nor DpCryptoManagement resolves why; it is left unexplained, not overturned.
See `docs/reference/coinbase/level2-session-limit.md` for the full, dated account. If you
are setting this above 30 because you have your own evidence the venue's limit moved,
that is exactly what this option is for.

**The default is not shrunk for headroom, on purpose.** `30` is the actual boundary — `30`
accepted, `31` refused, confirmed by interleaving and a contamination check — not merely
"the largest value that hasn't failed yet" the way this package's superseded `6` was.
Sitting exactly at a boundary that precise is a deliberate choice, not an oversight: see
`feed.ex`'s own moduledoc, "`level2_pairs_per_socket` — a supervision option," for the
full reasoning. The risk this package used to flag as still-open here — whether the
unconditional 60-second resubscribe could feed a *cumulative*, attempt-shaped ceiling — was
answered 2026-09-07 (see "the ceiling is concurrent, not cumulative" in `feed.ex`'s own
moduledoc): repeats do not accumulate, at any shard size. If you want margin below 30 for
your own reasons regardless, this option is exactly how you take it — pass a smaller value
yourself.

**`ticker`'s own shard size (100) has no equivalent option**, on purpose: it has no known
per-session ceiling to tune against, measured or suspected. This option exists because
`level2`'s ceiling is a real, located venue fact a consumer already hit in production, not
because "every constant should also be an option."

### `shard_spacing_ms` — the delay between opening successive shards

```elixir
children = [{DpExchange.Coinbase, credentials: my_credentials(), shard_spacing_ms: 1_000}]
```

Every new socket this package opens — either channel — takes the next tick of this
spacing, so several shards do not connect in the same instant: opening more than one
connection at once is a connect burst Coinbase answers with resets (see this file's
`level2` sections above and `feed.ex`'s own moduledoc for the measured incidents behind
that). The same spacing now also staggers the subscription changes sent when one
`update_symbols/2` call touches several already-open shards at once, not only when
opening a brand-new one.

Default is **1,000ms** — one connection per second, an 8x margin under the documented
125ms connect-rate floor below. This used to be **5,000ms**, inherited unexamined from the
reference fix this package replaced, the same way `ticker`'s 100-per-socket shard size
still is; `1,000ms` is chosen instead, reasoned entirely from Coinbase's own documented
rate-limits page (no live probe run against this venue) — see `feed.ex`'s own moduledoc,
`"shard_spacing_ms — a supervision option"`, for the full reasoning, including why the
choice sits well short of the documented floor rather than at it: partly headroom against
jitter and shared load, and partly precaution against an *undocumented* concurrency
ceiling of the kind that crash-looped a sibling venue package (Webull) the same week this
was decided. **This is a behaviour change for any consumer that has not set
`shard_spacing_ms` explicitly**: boot-to-full-coverage for the 406-symbol scope above
drops from roughly 90 seconds to roughly 18 seconds. Pass `shard_spacing_ms: 5_000`
yourself if you want the old, more conservative pacing back.

**Below `0`, or not an integer, is refused at start** — the same shape as
`level2_pairs_per_socket`. `0` itself is honoured, not refused: it schedules every shard
in the same instant, which is extreme but not mathematically nonsense the way a negative
delay is.

**Below the documented connect-rate floor is honoured, not capped — with a loud warning.**
Coinbase's own Advanced Trade rate-limits page states WebSocket connections are limited to
8 per second per IP, which converts directly into a floor of `125`ms
(`ceil(1_000 / 8)`) on this package's own connects. This package cannot verify whether a
faster pace is safe for your own network position, so a value below that floor is used as
given rather than refused — but it logs the documented floor, its source, and the concrete
risk first: connects tighter than the venue's own stated per-IP rate risk the same
connect-burst resets this option exists to avoid.

**One number governs four call sites — the initial connect stagger, `retry_missing_shards/1`'s
reopen stagger, the unconditional resubscribe walk, and the derived floor under
`resubscribe_interval_ms`** — considered separately and kept as one value rather than
split; see `feed.ex`'s own moduledoc, `"one spacing, several jobs"`, for why none of them
pulls the value in a different direction from the others.

## Testing against this package

Use `DpExchange.Coinbase.Fake`, selected per process through `DpExchange.Core.Config`. It
is a real implementation of the facade that answers from memory, models Coinbase's
refusals — unlisted symbols, `12h`, the 350 boundary — and passes the same conformance
suite as the real adapter.

**The fake remembers the orders it placed, per process.** `place_order/3` issues a new id
each time; `get_order/3` and `get_orders/2` return that order with its own symbol, side,
size and price, `cancel_order/3` marks it cancelled so the next read says `:cancelled`, and
an id the fake never issued answers as the venue does (`{:refused, :not_found}` on a read,
`{:refused, {:cancel_rejected, "UNKNOWN_CANCEL_ORDER"}}` on a cancel). A caller-supplied
`client_order_id` sent twice returns the ORIGINAL order, as the idempotent venue does, not
a second one; the side comes back as the atom, not the string you sent. Before anything is
placed, `fake-order-1` is a canned open BTC-USD order.

**`get_top_of_book/2` errors without `opts[:credentials]`, in the fake too** — the one
call this venue genuinely requires them for (see above). A test calling it with none gets
`{:error, {:missing_credentials, :coinbase}}` against both the fake and the real client,
on purpose: a fake that answered `:ok` regardless would pass a suite that then refuses in
production.

**Every private call refuses without a usable credential, in the fake too.** Balances,
accounts, fees, fills, orders (place, preview, edit, cancel, read, list, close), payment
methods, portfolios, conversions and transfers return
`{:error, {:missing_credentials, :coinbase}}` for `nil`, `%{}` or a map without a binary
`:api_key` and `:api_secret` — after the same local argument checks the real function runs
first (an order missing its symbol or a limit price, an edit missing a field, a conversion
missing `:from`/`:to`). Pass `credentials: ...` in `opts` where the call has no credential
argument. The fake also narrows `get_orders/2` by `:status`/`:symbol` and
`get_trade_history/2` by `:symbol`, `:order_id`, `:start` and `:end`, and an unknown order or
account is `{:refused, :not_found}` (the venue's 404); `:not_listed` is for symbols only.

**Do not point tests at the live venue.** This package's own tier-2 tests do that, tagged
and excluded, run by hand. A venue that sees a package polling it on a timer will
rate-limit or block.

## Two accounts, and only one of them margins a futures position

Advanced Trade's US derivatives sit in an account held with **Coinbase Financial Markets**;
spot sits in one held with **Coinbase Inc**. `get_futures_balance_summary/2` names both —
`cfm_usd_balance`, `cbi_usd_balance`, `total_usd_balance` — and **sizing a futures position
against the total is sizing against money that is not there.**

**BREAKING: `get_positions/1` refuses a row it cannot read as a whole `Types.Position`.** A
row whose `side` is not `LONG` or `SHORT` (the venue's `UNKNOWN` included) is
`{:error, {:unknown_position_side, value}}`, and one whose `number_of_contracts` is absent,
unreadable or negative is `{:error, {:invalid_position_quantity, value}}`. A row with
exactly zero contracts is a flat or closed position and is skipped. They used to
come back as `side: nil` / `quantity: nil` positions, which `Core.Types.Position` does not
allow (`:long | :short`, positive size). `list_futures_positions/1` still returns the venue's
rows untouched. The futures endpoints take no portfolio, so `portfolio:` on
`get_positions/1`, `list_futures_positions/1` or `get_futures_position/2` is
`{:error, {:unsupported_option, :portfolio}}`.

`get_positions/1` returns CFM positions. Its `:realised_pnl` is `nil` and that is not an
omission: the venue publishes `daily_realized_pnl`, which is what the position realised
*today*, and putting a daily number in a field that means the position's answers a different
question under the same name. `list_futures_positions/1` returns the venue's own row, where
that figure keeps its own name — along with `expiration_time`, which a future has and
`Types.Position` does not.

**A sweep is scheduled, not settled.** `schedule_futures_sweep/2` queues a move out of the
futures account; `list_futures_sweeps/2` reports the queue. **Omitting the amount sweeps
every available excess dollar** — the venue's default, not this package's. Only an
*absent* `:usd_amount` means that: a present one must be a finite positive number
(`{:error, {:invalid_amount, value}}` otherwise), so `""`, `0` or a typo cannot turn into
"sweep everything" at the venue. A `200` saying `success: false` on either
`schedule_futures_sweep/2` or `cancel_futures_sweep/2` is `{:refused, :sweep_not_scheduled}`
or `{:refused, :sweep_not_cancelled}`, never `{:ok, _}`.

**Perpetual orders carry `:leverage` and `:margin_type` when you name them.**
`place_order/3` and `preview_order/3` send `leverage` and `margin_type` (`:cross`,
`:isolated` or the venue's `"CROSS"`/`"ISOLATED"`) only when the request has them; absent,
the venue's defaults (1.0, CROSS) apply. A value outside the schema is
`{:error, {:invalid_leverage, v}}` or `{:error, {:invalid_margin_type, v}}`. They used to be
dropped silently.

`INTRADAY_MARGIN_SETTING_UNSPECIFIED` is the venue declining to say. It is **not**
`_STANDARD`, and this package will not map it to one.

## Prime is a different product, host and credential

Coinbase **Prime** is nine custodial staking endpoints. It talks to
`api.prime.coinbase.com` and signs an HMAC under an access key, a passphrase and a
signing key — **the CDP key pair the rest of this package uses is not accepted there**,
and two of the three is refused locally rather than sent as a signature over the wrong
string. `DpExchange.Coinbase.Prime.credentials()` is that triple's type.

**All nine reach through the facade.** `stake/3` and `unstake/3` are the two that also
answer a `Core.Venue` callback, and they **pick a scope only from what you said**: a
`:wallet_id` means the wallet, its absence means the portfolio, and `:portfolio_id` is
always required. A portfolio-scoped unstake redeems across *every* wallet in the
portfolio.

**The two scopes send different bodies, because the venue documents different schemas for
them.** Portfolio-scoped calls send a flat `{idempotency_key, currency_symbol, amount}`;
`opts[:extra]` merges into that same top level. Wallet-scoped calls send `{idempotency_key,
inputs: {amount, ...}}` — no `currency` field at all, because a wallet already names one
asset on the venue's side — and `opts[:extra]` merges into `inputs`, not the top level.
`opts[:metadata]`, where the venue defines that field, is sent as its own sibling key
either way. `opts[:extra]` fills in fields this package does not know; it **cannot replace**
`amount`, `currency_symbol`, `idempotency_key` or `transaction_ids`, the ones it validated.

**What is refused before anything is signed.** `:portfolio_id` and `:wallet_id` are path
segments and must be strings of letters, digits, `_` and `-`; anything else (including `""`
and `nil` for a wallet) answers `{:error, {:invalid_portfolio_id, value}}` or
`{:error, {:invalid_wallet_id, value}}`. A given `:idempotency_key` must be a UUID in the
canonical 8-4-4-4-12 hex form, as the spec requires (`{:error, {:invalid_idempotency_key,
value}}` otherwise): the venue answers a repeated key with the first response, so `""` made
every later stake a copy of the first.

**BREAKING: `stake/3` and `unstake/3` return a `Core.Types.StakingTransaction`**, as the Core
callback says, not Prime's raw map. `id` is Prime's `transaction_id`, `amount` what you asked
for, `type` is `:stake` or `:unstake`, `asset` is upper-cased. An unstake carries
`amount_remaining` equal to the requested amount (the acceptance reports no progress; nothing
is reported paid, and `unstake_status/4` is what moves it) and a stake leaves it `nil`. The
raw map is still what `Prime.stake_portfolio/5`, `Prime.stake_wallet/6` and the other
`Prime` functions return. The Fake returns the same struct with a unique id per placement (a
reused `:idempotency_key` answers with the original) and refuses what the real path refuses,
in the same order: the asset in both scopes, the amount and its 64-place bound, a UUID key, a
map `:extra`, then the Prime credentials.

**BREAKING: a wallet-scoped `stake/3` / `unstake/3` verifies the asset against the wallet
first.** The wallet bodies carry no currency, so the wallet decides what is staked, and an
`asset` that disagreed was silently ignored (naming `"ETH"` for a `SOL` wallet staked the
SOL). The package now reads `GET /portfolios/{pid}/wallets/{wid}` (`Wallet.symbol`) and
compares, case-insensitively: a mismatch is `{:error, {:wallet_asset_mismatch, asked,
held}}`, a wallet whose symbol cannot be read is `{:error, {:wallet_asset_unverified,
:unexpected_response_shape}}`, and a failed read comes back as it came (`{:refused, _}` for
a `4xx`, `{:error, _}` otherwise). Nothing is written in any of those cases. This costs one
extra signed `GET` per wallet-scoped write; `Prime.preview_unstake_wallet/6` does not check
(it moves nothing). The Fake has no wallet inventory, so it accepts the asset it is given.

**An unconfirmed staking write is `{:error, {:write_unconfirmed, idempotency_key, reason}}`.**
Every staking write sends an `idempotency_key` (yours, or one generated for the call) and
retries internally only because of it. The key in the error is the one that was sent, so
retrying with it cannot stake twice. See the `write_unconfirmed` entry at the top of this
file for what counts as unconfirmed; a `4xx` that answers one of the call's own retries is
also unconfirmed rather than a refusal.

**An order request key is read or refused by name.** `place_order/3` and `preview_order/3`
accept the contract's keys plus `quote_size`, `stop_price`, `stop_direction`, `post_only`,
`end_time`, `client_order_id`, `leverage`, `margin_type`, `retail_portfolio_id`,
`sor_preference` and (place only) `preview_id`. Any other key, including `reduce_only` and
the schema's unbuilt `attached_order_configuration`, is
`{:error, {:unsupported_order_field, key}}`, never silently dropped.

**`:order_type` and `:time_in_force` are required, and a field the type does not use is
refused.** No default: a request with no `:order_type` is `{:error, {:missing_field,
:order_type}}` (it used to be a limit order), none with no `:time_in_force` is
`{:error, {:missing_field, :time_in_force}}` (it used to be GTC, and a market order with no
tif was refused for a tif never named). An unknown type is `{:unsupported_order_type, type}`;
a pair the venue has no key for is `{:unsupported_order_combination, type, tif}`. `:price`
or `:stop_price` on a market order, `:stop_price` on a limit order, `:quote_size` on a
stop-limit order, and `:post_only: true` / `:end_time` / `:stop_direction` where the leaf has
no such field are
`{:error, {:unexpected_field, key}}` (they were silently dropped, or for `post_only` and
`end_time` refused as `{:unsupported_order_field, key, {type, tif}}`). A GTD order needs
`:end_time` (`{:missing_field, :end_time}`, checked with the time in force, before sizing and
every price field; an unreadable one is `{:invalid_end_time, v}`). A missing limit price is
`{:missing_field, :price}` and a missing stop price `{:missing_field, :stop_price}` (were
`:missing_limit_price` and `:missing_stop_price`). An absent `:symbol` is
`{:invalid_symbol, nil}` (it was `{:missing_field, :symbol}`). `post_only` is sent on the
limit GTC and GTD leaves; `post_only: false` elsewhere means absent and is accepted. Market
and limit orders are sized by exactly one of `:quantity` or `:quote_size`: neither is
`{:missing_field, :quantity}` (was the bare `:missing_order_size` on a market order) and both
is `{:unexpected_field, :quote_size}` (was the bare `:ambiguous_order_size`); a quote-sized
order's `Order.quantity` is `nil`.

**Amounts are refused unless finite and positive, and a float is refused.** `{:error,
{:invalid_quantity | :invalid_quote_size | :invalid_price | :invalid_stop_price, value}}`
(was `{:invalid_order_amount, field, value}`); a close's `:size` is `{:invalid_quantity, v}`.
Pass a `Decimal`, an integer or a numeric string. The checks run in a fixed order: request is
a map, unknown keys, symbol, side, type, time-in-force and the pair (a GTD order's
`end_time` included), sizing, fields the leaf does not carry, price fields, the leaf's
required fields, `post_only` values, `client_order_id` (non-blank), margin fields, then
credentials, then the wire.

**Order ids are checked first.** `get_order/3`, `cancel_order/3` and `replace_order/4` answer
`{:error, {:invalid_order_id, value}}` for `nil`, a non-string or a blank/whitespace-only id
(was `{:invalid_id, :order_id, value}`; `"  "` used to be sent percent-encoded), before
credentials and the wire.

The other five are Coinbase-specific — no generic callback fits them, so they
are plain functions on `DpExchange.Coinbase` instead:

- `query_transaction_validators/3` — the validators a portfolio-scoped staking
  transaction would touch. A read, despite being a POST: Prime takes the query in the
  body. **`opts[:transaction_ids]` is required** — the venue's own field is required and
  documents no "every transaction" meaning for its absence, so a caller who omits it is
  refused locally (`{:error, :missing_transaction_ids}`) rather than sent with an invented
  empty list. `opts[:cursor]`, `opts[:limit]`, `opts[:sort_direction]` go through
  `opts[:extra]`.
- `staking_status/4` — one wallet's staking state. **Not** what `get_staking_balances/1`
  would answer even if this venue served it: that is every staked position, one per
  asset; this is one wallet's own state.
- `unstake_status/4` — how far a wallet-scoped redemption has got. `unstake/3` returns
  before the asset has unbonded; this is what says whether it is done.
- `claim_rewards/4` — **moves funds.** Claims a wallet's accrued rewards. A write, not a
  report — it does not say what accrued, only moves what has.
- `preview_unstake_wallet/6` — what a wallet-scoped unstake would do, without doing it.
  Moves nothing.

These are **not** the CDP Staking API, whose seven endpoints return unsigned transactions
for you to sign and broadcast. If you hold one of those, nothing has been staked.

**Nothing here has been run.** The paths come from the vendor's pages and the signing
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

## A slow subscriber gets dropped, and told — it does not get an unbounded mailbox

If your process falls far enough behind that its mailbox reaches **10,000 queued
messages**, this package stops sending it events and emits a `Core.Notice`:

```elixir
%Core.Notice{
  kind: :degraded,
  severity: :warning,
  message: "subscriber #PID<0.123.0> is 10000 messages behind, past the 10000 bound — ...",
  details: %{subscriber: "#PID<0.123.0>", queue_len: 10_000, bound: 10_000, dropping: :newest}
}
```

and a second one, `severity: :info`, once you have drained below **half** the bound (5,000 by
default). Not merely back under it: a mailbox hovering at the bound used to flip on every
message, with a notice each time, into the same full mailbox. Now one stall costs one pair.
**Those two notices bracket exactly
the window you have to reconcile** from the pull endpoints — that is what the pair is for,
and why the recovery notice exists at all rather than just the alarm.

Three things are worth knowing about the shape of this:

- **The newest is dropped, not the oldest.** A sender cannot remove a message from your
  mailbox; only you can. So what happens is that nothing further is added while you are over
  the bound. It is also the better trade: a quote that arrives while you are ten thousand
  messages behind is stale by the time you would read it, and the frames it would have
  displaced are no fresher.
- **Only you are affected.** Another subscriber keeping up keeps receiving everything. One
  slow consumer is never allowed to become an outage for the others.
- **`coverage/1` does not change.** It reports what the *venue* delivered to this package,
  not what this package forwarded to you. A symbol whose frames are being dropped for your
  backlog is still arriving, and reporting it as `:not_covered` would point you at the venue
  when the backlog is yours.

Notices themselves are never dropped, whatever your queue looks like — the notice telling
you that you are being dropped must not be the first casualty of it.

Raise or lower the bound at start:

```elixir
{DpExchange.Coinbase, max_queue_len: 50_000}
```

Any positive integer. It must be an integer — a string or a float raises at `init/1` rather
than quietly falling back to the default, because a back-pressure setting you believe you
configured and did not is worse than not having configured one.

**If you are seeing these notices, the fix is on your side.** Consume in a process that does
nothing else, or hand the payload straight to a queue or an ETS table and do the work
elsewhere. The bound is not a tuning knob for throughput; it is the line past which this
package stops writing into memory you are not reading.

## Telemetry: attach one handler, see every venue

This package emits the `:telemetry` events `DpExchange.Core.Telemetry` documents. Attach to
the names, not to anything venue-specific:

```elixir
:telemetry.attach_many(
  "dp-exchange-metrics",
  DpExchange.Core.Telemetry.event_prefixes(),
  &MyApp.Metrics.handle/4,
  nil
)
```

`:provider` in the metadata is how you tell venues apart — one handler covers the whole
family.

**These names were documented long before anything emitted them.** If you attached a handler
before this version and saw nothing, that was not your venue being quiet:
`:telemetry.attach/4` against a name nobody emits succeeds, so an empty panel was
indistinguishable from no traffic. Every one of them fires now.

Four things to know before you build on them:

- **Telemetry is the metrics channel; `Core.Notice` is the action channel.** Telemetry is
  aggregate and lossy by design. Alarm on notices. Graph telemetry. Alarming on a gauge
  documented as droppable is how a missed sample becomes a page at 3am.
- **`:stop` fires for every outcome**, success or error. That is deliberate: a latency panel
  built on successes alone shows a venue getting *faster* exactly as it starts failing,
  because the slow calls are the ones dropping out of the sample. `:exception` is a separate
  event from a `:stop` carrying an error — an error result is the venue answering badly, an
  exception is this package failing to ask.
- **`retry_after_ms` is always milliseconds**, including where the venue's own header is in
  seconds. A panel summing a mixture of the two is wrong by a factor of a thousand without
  ever looking wrong.
- **`:bytes` may be absent from `[:dp_exchange, :link, :event]`**, and absent is not zero. A
  polling route has no frame, so there is no byte count that means what a socket's does.
  Treat a missing `:bytes` as "this route cannot measure that", not as no data.

`:endpoint` metadata is the request URL with the query string removed. Deliberate: telemetry
metadata reaches logs, aggregators and third-party exporters, and the query string is the one
part of a URL that can carry a token.

## Every capability claim is dated, and says what it was measured against

`capabilities/0` carries two provenance fields, and they are there to be read:

```elixir
caps = DpExchange.Coinbase.capabilities()
caps.measured_at       # ~D[...] — when someone last checked
caps.measured_against  # what they checked: which documents, which endpoints, live or not
```

**`measured_against` is the one that matters when you are deciding how much to trust a
claim.** It distinguishes a figure measured live against the venue's API from one read off a
documentation page and never probed — and this package's own declarations contain both
kinds, stated per claim rather than as one blanket sentence.

A claim read from documentation is not worse, it is *different*: it is what the vendor says
it will do, which is the right basis for a ceiling you must not exceed and a weaker basis for
behaviour you are about to depend on. If your decision turns on the difference, read the
field rather than assuming.

`measured_at` going stale is a real thing that happens — venues change, and a declaration is
a claim about a real venue. `script/check_doc_sources.sh` reports the age on its weekly run
so it does not quietly get old, but nothing forces it: if you are relying on a capability in
a way you cannot afford to have wrong, check the date and, where it matters, verify against
the venue yourself.

## The list endpoints follow the venue's cursor, and say so when they cannot finish

`get_balances/2`, `get_trade_history/2` and `get_orders/2` follow Coinbase's `cursor` /
`has_next` envelope to the end rather than returning the first page. A truncated list of any
of the three is the shape this family most wants to avoid — every value in it is real, so
nothing looks wrong, and what is missing is simply never seen.

Each walk is bounded. A venue that keeps saying `has_next` answers
`{:error, :history_truncated}` (every walk, the product catalogue included; it was
`:too_many_account_pages`, `:too_many_fill_pages`, `:too_many_order_pages` and
`:too_many_product_pages`) rather than looping inside your call, and a page that
offers back the cursor it was just fetched with is `{:error, :pagination_cursor_repeated}`
at once (the same page again; also on the product catalogue). Those are errors
about **this package's limit**, not statements about your account: retry with a narrower
filter (`:symbol` or `:status` on orders; `:symbol`, `:order_id` or `:start`/`:end` on fills)
rather than treating them as "no data". `get_orders/2` has no date option: the venue's
`start_date`/`end_date` are not sent.

`:limit` is the venue's **page size**, not a cap: the walk collects every page, so take what
you want from the list. On `get_balances/2` and `get_accounts/2` it must be an integer in
`1..250` (the venue's "max 250"); on orders and fills any positive integer.

`get_orders/2` returned one page until 0.3.36. If you built your own cursor loop on top of
it, it now returns the whole set and your loop will see a single page with nothing after it.

**BREAKING: `portfolio:` is honoured, not ignored.** `get_balances/2`, `get_accounts/2`,
`get_orders/2` and `get_trade_history/2` send `opts[:portfolio]` as the spec's
`retail_portfolio_id` query parameter (they used to drop it, answering for whichever
portfolio the key defaults to). A non-string or blank value is
`{:error, {:invalid_option, :portfolio, value}}`; `get_accounts(uuid: _, portfolio: _)` is
`{:error, {:unsupported_option, :portfolio}}` (the single-account read has no such
parameter). **The spec marks `retail_portfolio_id` deprecated and "only applicable for legacy
keys; CDP keys default to the key's permissioned portfolio"** — what the venue does with it
for a CDP key is unmeasured, which is why it is sent as given and never swapped for the
key's own. The Fake scopes by it too (its data belongs to its one default portfolio;
another holds nothing).

## A malformed argument to a private call is refused by name, before anything is sent

None of these raises in your process, and the fake runs the same check in the same order
(injected outcome, then the argument check, then the credential):

- **An id that becomes a path segment** — a payment method, portfolio, trade, futures
  product, order or account uuid — must be a non-empty string:
  `{:error, {:invalid_id, name, value}}` (`name` is `:payment_method_id`, `:portfolio_uuid`,
  `:trade_id`, `:product_id`, `:order_id` or `:uuid`). `nil`, a number or a map used to raise
  `FunctionClauseError` on `get_payment_method/3`, `get_portfolio_breakdown/3`,
  `delete_portfolio/3`, `rename_account/3`, `commit_conversion/2`, `get_conversion/2` and
  `get_futures_position/3`.
- **Enum filters are sent exactly as the venue spells them.** `get_fees/2` and
  `get_trade_volume/2` take `:product_type`, `:contract_expiry_type`, `:product_venue`;
  `list_portfolios/1` takes `:portfolio_type`; `get_current_margin_window/2` takes
  `:margin_profile_type`. A word outside the spec's enum, or a non-string, is
  `{:error, {:invalid_option, key, value}}`.
- **Fill filters.** `get_trade_history/2` needs `:order_id` to be a non-empty string or list
  of them (`{:invalid_order_id, v}`) and `:start` / `:end` to be `DateTime`s
  (`{:invalid_time, :start | :end, v}`), with `:start` before `:end`
  (`{:invalid_range, start: s, end: e}`). Strings used to be forwarded as given.
- **Conversions and transfers.** `quote_conversion/4` needs a finite positive `Decimal`, and
  `from`/`to` must be non-empty strings; `opts[:from]`/`opts[:to]` on commit and read, and
  on `transfer_internal/4`, may not be `""`. `transfer_internal/4` also needs a non-empty
  asset (`{:invalid_asset, v}`), and the same portfolio on both sides moves nothing and is
  `{:error, {:invalid_transfer, :same_account}}`. The amount is a finite positive `Decimal`
  (a float, integer or string is `{:invalid_amount, v}`). The callback's two option lists are
  merged as `Keyword.merge(request_opts, opts)`, so the third argument (`opts`) wins over the
  fourth (`request_opts`) on a repeated key. A portfolio name (`create_account/1`, `rename_account/3`)
  may not be `""` (`{:error, :name_required}`).
- **`Prime.query_transaction_validators/3`** takes at most 100 transaction ids, each a
  non-empty string (`{:error, {:invalid_transaction_ids, ids}}`) — the spec's stated limit.
- **`replace_order/4`'s refusal reason.** The venue's edit error carries both
  `edit_failure_reason` and `preview_failure_reason`, each starting at an `UNKNOWN_*` "not
  set". `{:refused, {:edit_rejected, reason}}` carries the first one that is set, else the
  edit reason.

## Error shapes that mean "do not act on this answer"

Returned by calls that previously answered `{:ok, _}` carrying a value you could not act on.
A consumer matching only `{:ok, _}` needs no change; one that enumerates error reasons
should know them.

`{:error, :unexpected_response_shape}` from `get_balances/2` — a balance row the venue did
not attribute to an asset refuses the whole reply. An amount you cannot name an asset for
cannot be sized, booked or reconciled against, and dropping the row silently would read as
"you hold none of that asset", a different and more dangerous claim than "this response could
not be read". **Not retryable on its own.**

A `Balance`'s own `balance` field may still be `nil`, and that is a different statement: the
venue named the asset and did not state a quantity for it. Read that as unknown, never as
zero.

## Every negative here is audited

`docs/reference/coinbase/negative-claims.md` lists each one with the source and date
consulted. Three were wrong and are corrected; the table records what the pattern was, so it
is not repeated: **each was a true statement about one endpoint, restated as a claim about
the venue.**

## Streaming calls answer; they never exit your process

`subscribe/2`, `unsubscribe/2`, `update_symbols/2` and `subscribe_notices/1` return
`{:error, :feed_not_started}` when this venue's feed is not running (`unsubscribe/2`
answers `:ok`: there is nothing to stop). They return `{:error, :feed_timeout}` when the
feed is too busy to answer within its call budget, and `{:error, {:feed_exited, reason}}`
when it dies while answering. `coverage/1` and `coverage_by_kind/1` answer an empty map in
all three cases, which means "not observed". Treat `:feed_timeout` as transient and retry.
Treat the other two as a feed your supervision tree has to bring back.

**A symbol list that cannot be sent is refused, and nothing changes.** `subscribe/2`,
`unsubscribe/2` and `update_symbols/2` take a proper list of strings that are not blank
after trimming. Anything else (an atom, `nil`, `""`, `" "`, an improper list, or an argument
that is not a list) answers `{:error, {:invalid_symbols, invalid}}` before the feed's state is
touched, **in the caller and before `:feed_not_started`**, so a malformed argument answers the
same whether or not the feed runs (`unsubscribe(nil)` with no feed is a refusal, not `:ok`).
The Fake registers for notices without sending any `:link_up` (the real feed sends none on
registration), skips a `to:` atom that names no process, and omits empty kinds from
`coverage_by_kind/1`, `:quotes` included. It used to raise
inside the feed, which is shared by every caller of the instance: the supervisor restarted
it from its static options and every symbol every caller had subscribed was gone.

**A subscriber that cannot be sent to is refused the same way.** `to:` on `subscribe/2` and
`subscribe_notices/1` must be a pid or a registered name (an atom other than `nil`, `true`
or `false`; `nil` means the caller). A string, an integer, `{:global, _}` or `{:via, _, _}`
answers `{:error, {:invalid_subscriber, to}}` and nothing is recorded; `subscribe/2` checks
the symbols first. `DpExchange.Coinbase.Fake` refuses identically. The `feed:` option, by
contrast, may be any `GenServer.server()`, including `{:global, _}` and `{:via, _, _}`.

## `:websocket_url` in application config replaces the default socket endpoint

`config :dp_exchange_coinbase, websocket_url: "wss://your-proxy.example/..."` sends every socket
this package opens, unless a call passes its own `:url`, to that address instead of the
venue. Unset, the venue is the default. It exists so a test suite never dials the live venue
by accident, and it is equally usable for a proxy.

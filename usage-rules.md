# Using `dp_exchange_coinbase`

> **EXPERIMENTAL.** Not run in production. Pin three-part. Maturity is per endpoint —
> read `capabilities/0`, not this banner.

Everything general is in
[`dp_exchange_core`'s usage rules](https://hexdocs.pm/dp_exchange_core/usage-rules.html).
This file is only what is **specific to Coinbase**.


## BREAKING — `Quote` and `OrderBook` no longer carry `:timestamp`

They carry **`:venue_time`** (the venue's own, `nil` where the venue publishes none) and
**`:observed_at`** (when this package read it, always present) — the shape
`Core.Types.TopOfBook` has always had. Requires `dp_exchange_core ~> 0.2.1`.

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

## A shard's socket crash costs one shard, never your whole subscription

Each `level2`/`ticker` shard runs on its own socket, and that socket is a **linked**
child of `Feed` — not a supervised sibling you can restart independently. As of this
version `Feed` traps exits, so a shard's socket dying abnormally no longer takes `Feed`
down with it: only that one shard's symbols drop out of `coverage/1` and
`coverage_by_kind/1` (only the `data_kind()` its channel carries — a `level2` crash
never touches a symbol's `ticker` coverage), you get a `:link_down` `Core.Notice`
naming which shard and why, and this package reopens that shard on its own, immediately,
without you calling `subscribe/2` again.

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
  different request rather than a retry of this one.
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
`{:error, :invalid_base64}`, `{:error, {:unsupported_key_size, n}}`, or
`{:error, {:missing_credentials, :coinbase}}`.

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

### `:order_book` needs a credential; `:quotes` does not

`capabilities/0` now says so: `streamable` is `[:quotes, :order_book]` and
`authenticated_streamable` is `[:order_book]`. Without credentials this package subscribes
`ticker` alone, so you get quotes and **no book**.

That second field was left empty until now, which reads as "nothing here needs a
credential". A host deciding whether it had to obtain one before it could stream book data
was told no, and would have discovered otherwise from a book stream that simply never
arrived — ask `capabilities/0` rather than waiting to find out from `coverage/1`.

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

The vocabulary is `capabilities().streamable`'s data kinds — `:quotes` and `:order_book` —
not this venue's channel names. Omit the option and you get both, exactly as before.

**What it saves is not small.** `level2` shards at 30 pairs per socket, so a 406-pair scope
opens **14 `level2` sockets** on top of its 5 `ticker` shards. A consumer reading only
quotes measured **1,577,001 `OrderBookDelta` frames decoded and delivered in one boot**, all
discarded. Ignoring them on receipt saves nothing — the sockets are open and the frames are
parsed before they reach you.

Two things the option deliberately does not do:

- **It never widens past your credentials.** `level2` is authenticated here, so a
  credential-less feed carries `ticker` alone whatever you ask for. Requesting the book
  without a credential does not produce a doomed subscribe.
- **It refuses an empty list**, loudly, at `init/1`. A feed subscribing to nothing reports
  permanent zero coverage, which is indistinguishable from a venue outage. If you want no
  stream, do not start a feed.

A kind this venue does not stream (`:candles`, say) also fails at `init/1` rather than being
silently dropped.

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
every shard's current subscriptions on a timer to cover that, unconditionally.

```elixir
children = [{DpExchange.Coinbase, credentials: my_credentials(), resubscribe_interval_ms: 30_000}]
```

Default is **60,000 ms**, and it is a diagnostic knob, not a way to make coverage catch
up faster. A value shorter than one full re-issue cycle across your current shard count
is not honoured: this package derives the floor from the shard count that actually
exists — `(shards - 1) * 5_000ms + 5_000ms` — and uses that instead, logging the
substitution, rather than wedging the feed with overlapping re-issue cycles queued behind
each other. That is a real, measured incident (DpCryptoManagement's issue #22): it
happened both from an explicit `resubscribe_interval_ms: 5_000` and from the 60s
*default* past thirteen shards. There is no way to make this package re-issue faster than
that floor — only a log line explaining why it didn't.

**Shard count now counts `level2` and `ticker` separately, and `level2` needs more of
them than `ticker` does** — see the next section. Thirteen shards is reachable from
`level2` alone once your universe passes 360 symbols; it no longer takes 1,101 symbols the
way it did when both channels shared one 100-per-socket grouping.

**A shard whose socket never opened at all is retried on this same cadence, and it says
so.** A transient connect failure on a shard beyond the first (a brief DNS blip, a refused
connection) used to have no automatic recovery — nothing re-asked the venue for it until
you called `subscribe/3` or `update_symbols/2` again yourself, which may never happen if
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
that). The same spacing now also staggers `reconcile_shard/7`'s frames when one
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

**`get_top_of_book/2` errors without `opts[:credentials]`, in the fake too** — the one
call this venue genuinely requires them for (see above). A test calling it with none gets
`{:error, {:missing_credentials, :coinbase}}` against both the fake and the real client,
on purpose: a fake that answered `:ok` regardless would pass a suite that then refuses in
production.

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

Coinbase **Prime** is nine custodial staking endpoints. It talks to
`api.prime.coinbase.com` and signs an HMAC under an access key, a passphrase and a
signing key — **the CDP key pair the rest of this package uses is not accepted there**,
and two of the three is refused locally rather than sent as a signature over the wrong
string. `DpExchange.Coinbase.Prime.credentials()` is that triple's type.

**All nine reach through the facade.** `stake/3` and `unstake/3` are the two that also
answer a `Core.Venue` callback, and they **pick a scope only from what you said**: a
`:wallet_id` means the wallet, its absence means the portfolio, and `:portfolio_id` is
always required. A portfolio-scoped unstake redeems across *every* wallet in the
portfolio. The other five are Coinbase-specific — no generic callback fits them, so they
are plain functions on `DpExchange.Coinbase` instead:

- `query_transaction_validators/3` — the validators a portfolio-scoped staking
  transaction would touch. A read, despite being a POST: Prime takes the query in the
  body.
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

## Every negative here is audited

`docs/reference/coinbase/negative-claims.md` lists each one with the source and date
consulted. Three were wrong and are corrected; the table records what the pattern was, so it
is not repeated: **each was a true statement about one endpoint, restated as a claim about
the venue.**

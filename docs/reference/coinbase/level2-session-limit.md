# `level2`'s per-session product ceiling — measured, not documented

**No Coinbase document states a per-session `level2` product ceiling.** Re-checked
2026-09-06 against the Advanced Trade channels reference, the connection overview, and
the Advanced Trade rate-limits page (which states an `8`-per-second-per-IP
connect/message rate — a connect-rate ceiling, not a subscription count). The older
Exchange product's own separate rate-limits page states a different, inapplicable number
(10 duplicate subscriptions to the *same* product-channel pair, not the count of distinct
products), and this package speaks Advanced Trade, not Exchange. Everything below is
**measured venue behaviour**, never a documented figure, and every entry says who measured
it, when, and how — an unlabelled number is worse than a missing one.

## Who can measure this, and why this repo cannot

`level2` sits on Coinbase's authenticated channels. This repo's own testing strategy draws
a hard line at tier 3 (authenticated, live): it "needs credentials this repo must never
hold." Bisecting a real session's `level2` subscription size against the live venue is
exactly tier 3, for any endpoint, `level2` included — this package cannot run the
measurement below itself, on its own infrastructure, ever.

**DpCryptoManagement** — a consumer of this package, holding its own real credentials —
ran it instead, and reported the result back as tier-3 evidence (issue #22). That is a
different thing from this package probing itself, which is why every claim below is
attributed to them and dated, not folded in as this package's own finding.

## The ceiling: 30 products per `level2` session

**Measured 2026-09-06, DpCryptoManagement, issue #22.**

| requested (`n`) | 6 | 12 | 25 | 30 | 31 | 35 | 50 | 100 |
|---|---|---|---|---|---|---|---|---|
| verdict | accepted | accepted | accepted | accepted | **REFUSED** | **REFUSED** | **REFUSED** | **REFUSED** |

`30` is the largest value with positive evidence of acceptance; `31` is the smallest with
positive evidence of refusal — the boundary is actually located, not merely bounded far
below a known failure the way this package's own earlier, interim figure (`6`) was.

### Method

One fresh `Socket.start_link/1` per attempt, **never reused** — cumulative session state
was explicitly the thing under test (see "Cumulative vs. concurrent" below for why that
matters and what it does and does not prove). 3 seconds to establish the connection, then
`subscribe(socket, "level2", symbols, creds)`, then 20 seconds draining the mailbox
*continuously* while tallying. Every symbol came from the consumer's real, live
406-symbol production scope, so silence during the drain means refusal rather than an
idle order book. Verdict `refused` on a `rate_limited` notice from the venue, `accepted`
on `OrderBook`/`OrderBookDelta` payloads actually arriving.

The boundary was confirmed by interleaving two full runs back to back:
`n=30 accepted, n=31 REFUSED, n=30 accepted, n=31 REFUSED`.

### Contamination check

Immediately after a run where `n=31`–`34` refused, `n=6` and `n=30` were re-run and both
accepted. This is what rules out the refusals being saturation from the probing itself
(e.g. the venue penalising an IP or credential for rapid repeated connects) rather than a
genuine, stable, per-session ceiling: if probing itself were the cause, a freshly-opened
small session immediately afterward would be expected to suffer too, and it did not.

## Cumulative vs. concurrent — what this measurement does and does not prove

The harness above used a fresh socket for every single attempt **specifically** because,
in the consumer's own words, "cumulative session state is the thing under test." That
control makes the `30` above a reliable answer to "how many `level2` products can one
session hold *concurrently*." It cannot, by the same design, say whether Coinbase's
ceiling is scoped to concurrently-held products or to every **distinct** product a session
has ever been asked to carry, whether or not all of them are still wanted now — every
attempt in the bisection above only ever asked a brand-new session for one thing, once.

This package's own long-lived `level2` sockets are exactly the case that distinction
matters for: `dp_exchange_coinbase`'s `Feed` module keeps a socket open indefinitely and
reconciles its subscriptions as a consumer's wanted symbols change, rather than opening a
fresh socket per change. Whether that could cross a *cumulative* ceiling without ever
holding more than 30 products at once was checked directly against the code (not
guessed) — see `lib/dp_exchange/coinbase/feed.ex`'s moduledoc, "cumulative vs.
concurrent" section, for the full account. Two things came out of that check:

1. **Proven from this package's own code, not from live venue behaviour:** an
   already-open `level2` shard whose membership grows — which ordinary universe churn
   causes far more often than a caller literally asking to add one symbol, because a
   `MapSet`'s enumeration order is a function of its current key set and reshuffles
   several unrelated members' shard assignment on almost any change — used to have its
   *added* symbols subscribed onto its *existing* socket. That could grow one socket's
   lifetime distinct-product count past 30 even though its concurrent membership never
   exceeded it. This was real regardless of what Coinbase's actual ceiling semantics turn
   out to be, and is now fixed: such a shard gets a freshly opened socket instead, so no
   `level2` socket this package opens is ever asked, over its whole lifetime, to carry
   more distinct products than one shard's worth — `@default_level2_pairs_per_socket`,
   `30`, or whatever a consumer overrides it to via the `level2_pairs_per_socket`
   supervision option (added after this investigation; see `feed.ex`'s own moduledoc).

2. **Still genuinely open, and not fixed here:** the unconditional 60-second resubscribe
   this package runs to recover from a silent WebSockex reconnect re-issues a shard's
   *unchanged* symbols to its *already-subscribed* socket, forever, for as long as that
   socket lives. If Coinbase's ceiling counts subscribe *attempts* rather than distinct
   products, this timer feeds that counter on every tick regardless of shard size. This
   package cannot settle that without exactly the tier-3 access DpCryptoManagement has
   just shown it can supply. It was an open question before this investigation (see
   `Feed`'s `@default_resubscribe_interval_ms` comment) and remains one.

### Probes that would settle the open question

Both are structured the same way as the bisection above, run by a consumer with real
credentials — this repo cannot run either:

- **Attempt-counting.** One socket, a small fixed `level2` set well under 30 (e.g. 5
  symbols), held constant, with a short resubscribe interval so the same identical
  subscribe is re-issued on that one socket dozens of times within a few minutes. A
  refusal despite concurrent membership never exceeding 5 would mean attempts count
  cumulatively; none after well over 30 re-issues would be strong evidence only distinct
  concurrent products do.
- **Cumulative distinct-count.** One socket, 25 `level2` symbols, then several rounds of
  "remove 5, add 5 new ones" — concurrent membership never exceeds 25, but the number of
  *distinct* products the session has ever carried passes 30 by the second round. A
  refusal here would confirm the cumulative-distinct hypothesis the fix above was written
  against; acceptance through several rounds would show the fix cost nothing but bought a
  safety margin that was not, in fact, load-bearing.

## A refusal is not always a clean gate — observed, not explained

DpCryptoManagement's bisection reports "accepted" or "refused" per `n`, but two of their
runs saw something neither they nor this package has an account of:

- In one run, `n = 31`–`34` refused with `books = 0` — a clean refusal, no data.
- In the **same run**, `n = 35`–`50` refused, but 1,300–2,000 books were delivered
  *alongside* the `rate_limited` notice — a partially honoured, oversized subscription.
- A later, separate run saw `n = 31` refuse *with* 1,655 books delivered — the smallest
  over-the-boundary value, in a different run, also showing partial delivery.

**This does not move the boundary.** Every `n ≥ 31` refused and every `n ≤ 30` did not, in
both runs — the ceiling above stands. It means "refused" can apparently be a spectrum
rather than a single gate, and this is recorded here as an **observed, unexplained venue
characteristic** — dated and attributed, not rationalised into a theory neither party has
evidence for.

**This package should never itself trigger this at the default.** Every `level2`
subscribe `Feed` sends carries at most `state.level2_pairs_per_socket` symbols, by
construction (`@default_level2_pairs_per_socket`, `30`, unless a consumer overrides it via
the `level2_pairs_per_socket` supervision option added after this investigation), and the
cumulative-growth fix above now bounds each socket's lifetime subscription count the same
way. A consumer who overrides the option above `30` can trigger exactly this refusal
shape on purpose — that risk is disclosed loudly at start (see `feed.ex`'s own moduledoc)
rather than hidden, but it is no longer unconditionally true that "nothing in this
package's own behaviour asks the venue for 31 or more products at once." Should the venue
nonetheless answer a
`rate_limited` notice while some of that same shard's symbols are genuinely delivering —
the exact shape observed above — `coverage/1` and `coverage_by_kind/1` need no special
case to stay honest: both are built entirely from symbols that actually delivered a
`Types.Quote`, `Types.OrderBook` or `Types.OrderBookDelta` payload, and a `Core.Notice`
never touches that bookkeeping. A symbol that delivered a book is covered for
`:order_book` whether or not its shard's subscribe was also, separately, answered with a
refusal; a symbol that delivered nothing stays `:not_covered` regardless. See
`lib/dp_exchange/coinbase/feed.ex`'s moduledoc, "a refusal is not always a clean gate" —
the two facts (delivery, refusal) were never coupled in this package's own bookkeeping in
the first place.

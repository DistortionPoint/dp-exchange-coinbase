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
session hold *concurrently*." It could not, by the same design, say whether Coinbase's
ceiling is scoped to concurrently-held products or to every **distinct** product a session
has ever been asked to carry, whether or not all of them are still wanted now — every
attempt in the bisection above only ever asked a brand-new session for one thing, once.

This package's own long-lived `level2` sockets were exactly the case that distinction
mattered for: `dp_exchange_coinbase`'s `Feed` module keeps a socket open indefinitely and
reconciles its subscriptions as a consumer's wanted symbols change, rather than opening a
fresh socket per change. Whether that could cross a *cumulative* ceiling without ever
holding more than 30 products at once was checked directly against the code (not
guessed) at the time — see `lib/dp_exchange/coinbase/feed.ex`'s moduledoc, "the ceiling is
concurrent, not cumulative" section, for the full account, including the interim fix this
measurement below superseded.

## RESOLVED, 2026-09-07: the ceiling is concurrent, not cumulative

**Three probes, DpCryptoManagement, issue #22 continuing.** Each ran on ONE socket, using
raw `Socket.subscribe/4` **directly — deliberately not `Feed` or `update_symbols/2`** —
specifically so the result is evidence about the VENUE's own accounting, not about this
package's own dedup or bookkeeping. All three drained continuously against real products
from the consumer's live scope.

1. **Repeats do not accumulate.** The same 30 products, re-sent roughly 60 seconds apart,
   14 times: all accepted. The socket stayed alive throughout, roughly 13 minutes.
   `books=30` on the first attempt and `books=0` on every repeat — the venue recognised
   those products were already subscribed and replayed no snapshot, rather than refusing
   the repeat. This also directly answers the "attempt-counting" probe recorded below as
   an open question: it is the same shape (one socket, a fixed set, a 60-second-scale
   resubscribe cadence, dozens of minutes) and it settles that this package's own
   unconditional 60-second resubscribe timer does not itself feed an attempt-counted
   ceiling, at any shard size, for as long as 14 repeats over 13 minutes is representative.
2. **A concurrent overage refuses, but does not close the socket.** A different 30
   products, on the SAME socket, without unsubscribing the first batch first:
   `cumulative=60` — REFUSED, `"too many L2 streams requested in a single session"`. But
   the socket stayed alive, and the first batch kept delivering (27 of 30 still ticking
   during the refusal) — only the second, unreleased batch was rejected.
3. **`unsubscribe` releases budget the venue actually honours.** Four batches of 30
   products each, always unsubscribing the previous batch before requesting the next: all
   four accepted, a fresh snapshot every time — 120 distinct products moved through one
   socket's lifetime, never more than 30 live at any moment.

**Conclusion: the ceiling is 30 CONCURRENT products per session, not 30 over a session's
lifetime.** A long-lived socket does not degrade as its membership churns, provided it
releases what it is giving up before it asks for what it is gaining (probe 3; probe 2 read
the other way round). The interim, cumulative-hedge fix this package shipped after the
2026-09-06 bisection — replacing a growing `level2` shard's socket outright rather than
mutating it — is no longer necessary: `Feed` now reconciles every shard, either channel, on
its EXISTING socket, unsubscribing departing symbols before subscribing arriving ones, on
the SAME connection, in that order, always. See `lib/dp_exchange/coinbase/feed.ex`'s
moduledoc, "unsubscribe before subscribe," for the mechanism, the guarantee it actually
rests on (frame order on one TCP connection, not a venue acknowledgement this protocol does
not offer for `unsubscribe`), and the one gap it still leaves open (a permanently stranded
unsubscribe after exhausted retries).

**One axis genuinely remained open before this measurement and is now closed: attempt
counting (probe 1).** The other axis this package previously flagged as open — cumulative
distinct-count — is also closed, by probes 2 and 3 together: the venue's ceiling is
concurrent, not cumulative, so nothing about a session's lifetime distinct-product count
matters on its own. Nothing currently proposed remains open on either axis.

## A refusal is not always a clean gate — observed, not explained

DpCryptoManagement's original 2026-09-06 bisection reports "accepted" or "refused" per
`n`, but two of their runs saw something neither they nor this package has an account of:

- In one run, `n = 31`–`34` refused with `books = 0` — a clean refusal, no data.
- In the **same run**, `n = 35`–`50` refused, but 1,300–2,000 books were delivered
  *alongside* the `rate_limited` notice — a partially honoured, oversized subscription.
- A later, separate run saw `n = 31` refuse *with* 1,655 books delivered — the smallest
  over-the-boundary value, in a different run, also showing partial delivery.

**This does not move the boundary.** Every `n ≥ 31` refused and every `n ≤ 30` did not, in
both runs — the ceiling above stands. It means "refused" can apparently be a spectrum
rather than a single gate, and this is recorded here as an **observed, unexplained venue
characteristic** — dated and attributed, not rationalised into a theory neither party has
evidence for. These refusals were themselves all on a SINGLE, oversized subscribe (one
`Socket.subscribe/4` call for `n` symbols, `n > 30`) — the same shape as the 2026-08-26
incident below, not the cumulative-overage shape probes 2 and 3 above exercised; see the
open correction two sections down for why those two shapes are not assumed to behave
alike.

**This package should never itself trigger this at the default.** Every `level2`
subscribe `Feed` sends carries at most `state.level2_pairs_per_socket` symbols, by
construction (`@default_level2_pairs_per_socket`, `30`, unless a consumer overrides it via
the `level2_pairs_per_socket` supervision option), and the unsubscribe-before-subscribe
reconcile above keeps every socket's concurrent count within that same bound at every
instant, whether or not the venue's ceiling turned out to be cumulative. A consumer who
overrides the option above `30` can trigger exactly this refusal shape on purpose — that
risk is disclosed loudly at start (see `feed.ex`'s own moduledoc) rather than hidden, but
it is no longer unconditionally true that "nothing in this package's own behaviour asks the
venue for 31 or more products at once." Should the venue nonetheless answer a
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

## OPEN: does a single oversized subscribe still close the socket, or was that specific to the 2026-08-26 incident?

**Do not resolve this either direction from what is on record.** Two observations exist,
from two different investigations, and they describe two different SHAPES of overage —
this section states both and leaves the conflict open rather than picking a side.

- **2026-08-26 (the original incident that first shipped `@pairs_per_socket` sharding for
  `level2`):** a `level2` subscribe over the venue's per-session limit was refused with
  `"too many L2 streams requested in a single session"`, and the socket **closed** —
  measured against a real ~400-symbol universe: 355 of 405 pairs went stale and 1,480
  refusals were logged in one window. This was a total data gap for the whole shard, not
  degraded coverage.
- **2026-09-07 (probe 2 above):** a refusal from **cumulative overage across two separate,
  smaller subscribes** on one socket did **not** close the socket — the first batch kept
  delivering, and only the second, unreleased batch was rejected.

These may be different venue behaviours (a single request that itself exceeds the limit
closes the connection; a request that merely pushes the session's running total over the
limit does not) or the same behaviour seen from two angles that have not yet been reconciled
by a matched pair of probes. **The consumer has offered to test the single-oversized case
specifically** — until that runs, this package's own `level2_pairs_per_socket` warning
text states the worse of the two observed outcomes (whole-shard coverage loss) as the risk
to plan for, without asserting it is certain to recur. See
`lib/dp_exchange/coinbase/feed.ex`'s `validate_level2_pairs_per_socket!/1` and its
moduledoc section on the option for the current wording.

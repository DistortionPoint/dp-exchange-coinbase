# `@default_shard_spacing_ms` may be far more conservative than the venue requires

**Status**: Implemented — closed 2026-09-09.

Originated as a non-blocking discovery, found while making `shard_spacing_ms` a
supervision option (`feed.ex`, `"shard_spacing_ms — a supervision option"` moduledoc
section). Not acted on at the time — deliberately, so a test-speed change would not also
retune a production constant nobody had yet derived a better value for. This document
records the deliberate, scoped follow-up that closes it.

## The observation

`@default_shard_spacing_ms` was `5_000`ms. Like `@pairs_per_socket` (100), it was
**inherited** from the reference fix this package replaced, not derived from anything
measured against this venue — the moduledoc said as much for `@pairs_per_socket` but,
until the original discovery, said nothing about where `5_000` itself came from, because
nothing had looked.

Coinbase's own Advanced Trade rate-limits page (re-read 2026-09-06, the same pass that
produced `@default_level2_pairs_per_socket`) states: "WebSocket connections ... are ...
limited to 8 per second per IP." This module opens one new socket per `shard_spacing_ms`
tick, so that figure converts directly into a floor: `ceil(1_000 / 8)` = `125`ms.

`5_000`ms was roughly **forty times** more conservative than that documented floor.

## Every call site was traced before choosing a value

Four places in `feed.ex` read `shard_spacing_ms`, not one:

1. The initial connect stagger (`reshard/1`'s `rest` list) — opens brand-new sockets.
2. `retry_missing_shards/1`'s reopen stagger for a shard whose socket never opened —
   also opens brand-new sockets.
3. `handle_info(:resubscribe, _)`'s unconditional 60-second re-issue walk — staggers
   frames onto ALREADY-open sockets, no new connection.
4. `next_resubscribe_delay/1` — not an independent job at all, a derived floor that has
   to track whatever (3) actually uses or resubscribe cycles overlap and stack frames.

(1) and (2) are a direct fit for the documented connect-rate floor. (3) is not directly a
connect-rate concern, but two reasons keep it on the same number rather than a faster one
of its own: Coinbase's own rate-limits page states its 8/second/IP ceiling covers connects
*and* messages together (`docs/reference/coinbase/level2-session-limit.md`'s own
paraphrase, "an `8`-per-second-per-IP connect/message rate"), and independently,
`Socket.subscribe/4` blocks the `Feed` `GenServer` for as long as its target socket takes
to acknowledge, so spacing resubscribe frames apart protects `coverage/1` and every other
call to `Feed` from stalling behind a burst of blocking sends regardless of what the venue
does with them. Nothing about (3) or (4) argues for resubscribing *faster* than the connect
pace (1)/(2) already settle on, so the four never pull the value in different directions.
**One number continues to do all four jobs** — see `feed.ex`'s own moduledoc, "one
spacing, several jobs," for the full reasoning kept alongside the code.

## What closes this

**`@default_shard_spacing_ms` is now `1_000`ms — chosen, not inherited.**

- **`1_000`ms is one connection per second — an 8x margin under the documented `125`ms
  floor, not the floor itself.** This document's own original closing criteria explicitly
  ruled out adopting the floor: no margin for scheduler jitter, GC pauses, or a consumer's
  own concurrent load sharing the same IP. `500`ms (a 4x margin) was considered and set
  aside in favour of the larger margin below.
- **Chosen more conservatively than headroom against the documented rate alone would
  require, because of a real, recent incident on a *different* venue in this family:**
  Webull's shards crash-looped this same week once abandoned sessions accumulated against
  an undocumented five-connection ceiling. Coinbase's own rate-limits page documents a
  RATE, not a concurrency cap, and documents no concurrency cap at all — but "no documented
  cap" is not "no cap," and a tighter stagger increases how many of this module's own
  connects are opening, and therefore how many are mid-handshake, in any short window — the
  same axis that bit Webull. `Socket`'s own live measurement method
  (`docs/reference/coinbase/level2-session-limit.md`) took on the order of a few seconds to
  establish one connection; at `1_000`ms spacing, only a handful of this module's own
  connects are ever simultaneously mid-handshake for the 406-symbol, 19-shard scope this
  package's own moduledoc discusses, against roughly two dozen that would be in flight at
  once at the bare `125`ms floor. This is a documented-rate-plus-precaution choice, not a
  measurement of Coinbase's own concurrency behaviour — this repo has neither measured nor
  been told Coinbase has any such ceiling; the precaution is carried over from a sibling
  venue's incident, not from anything Coinbase-specific.
- **Reasoned from the documented rate-limits page alone, per this document's own original
  closing criteria** — no live probe was run. `shard_spacing_ms` governs unauthenticated
  connects, which this repo's tier-2 rule permits probing by hand, but a pure connect-rate
  number that already converts to an exact floor left nothing ambiguous to resolve by
  probing, so none was run.
- **For the 406-symbol scope this package's own moduledoc already discusses (19 shards, 5
  `ticker` + 14 `level2`), boot-to-full-`level2`-coverage drops from 90 seconds at the old
  default to 18 seconds at this one** — a fivefold improvement, deliberately short of the
  roughly-twentyfold the bare floor would give.

  (The 90-second figure corrects an approximation in the moduledoc's own earlier draft,
  which computed the span as `(14 - 1) * shard_spacing_ms` — counting only `level2`'s own
  shard count and omitting the 5 `ticker` shards staggered ahead of `level2` in the same
  sequence. The true span is `(shard_count - 1) * shard_spacing_ms` over all 19 touched
  shards — `18 * shard_spacing_ms` — verified against `reshard/1`'s actual position math
  and against a live run of a temporary, throwaway test exercising a real 406-symbol
  `Feed.subscribe/3` call with credentials present. At the old `5_000`ms default that is
  `90_000`ms, not the `65_000`ms the old approximation implied.)

This is a behaviour change for every consumer that has not set `shard_spacing_ms`
explicitly: `Feed` now reaches full coverage noticeably faster after boot and after any
event that reopens shards. A consumer who wants the old, more conservative pacing back can
still ask for it: `shard_spacing_ms: 5_000`.

## What did not change

- `shard_spacing_ms`'s existence as a supervision option — that shipped before this
  document existed.
- `@shard_spacing_floor_ms` (`125`ms) and `validate_shard_spacing_ms!/1`'s warn-not-refuse
  behaviour below it.
- The number of call sites reading `state.shard_spacing_ms` — still one field, four
  readers, reasoned about together in `feed.ex`'s moduledoc's "one spacing, several jobs."

## Where the reasoning lives going forward

- `lib/dp_exchange/coinbase/feed.ex` moduledoc, `"shard_spacing_ms` — a supervision
  option"` and `"one spacing, several jobs"` — the durable record, read by anyone
  changing this code.
- `usage-rules.md`, `"shard_spacing_ms` — the delay between opening successive shards"` —
  the consumer-facing statement of the new default and what it rests on.
- `CHANGELOG.md` — the value change, dated, with the same reasoning summarised.

This document is now closed; do not re-open it to make further adjustments to
`@default_shard_spacing_ms`. A future change to this constant (a live measurement, a
venue-side rate-limit change, a further reduction) is a new, dated design document, the
same way this one was for the change it records.

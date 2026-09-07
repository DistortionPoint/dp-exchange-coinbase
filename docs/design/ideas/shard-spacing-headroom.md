# `@default_shard_spacing_ms` may be far more conservative than the venue requires

Non-blocking discovery, found while making `shard_spacing_ms` a supervision option
(`feed.ex`, `"shard_spacing_ms` — a supervision option"` moduledoc section). Not acted on
here — see that section for why a test-speed change is the wrong place to also retune a
production constant nobody has deliberately measured a better value for.

## The observation

`@default_shard_spacing_ms` is `5_000`ms. Like `@pairs_per_socket` (100), it is
**inherited** from the reference fix this package replaced, not derived from anything
measured against this venue — the moduledoc says as much for `@pairs_per_socket` but,
until this discovery, said nothing about where `5_000` itself came from, because nothing
had looked.

Coinbase's own Advanced Trade rate-limits page (re-read 2026-09-06, the same pass that
produced `@default_level2_pairs_per_socket`) states: "WebSocket connections ... are ...
limited to 8 per second per IP." This module opens one new socket per `shard_spacing_ms`
tick, so that figure converts directly into a floor: `ceil(1_000 / 8)` = `125`ms.

`5_000`ms is roughly **forty times** more conservative than that documented floor.

## Why this is not acted on now

1. This package's own standard is "declare what you measured, not what you assume." The
   floor above is a documented venue fact, not a measurement of what actually happens if
   `shard_spacing_ms` is tightened — nobody has run this package against the real venue
   at, say, `500`ms or `1_000`ms and confirmed it survives without connect resets or some
   other venue-side reaction the rate-limits page does not describe (a per-endpoint burst
   allowance, a soft ceiling below the documented one, IP reputation, or nothing at all).
2. The change that surfaced this was a test-speed fix. Retuning a production constant
   inside that change — even with a principled floor to point at — is exactly the
   drive-by this repo's own `FrameSender` moduledoc warns against for a different
   constant: a decision like this belongs in its own design doc, with its own reasoning
   and, ideally, its own live measurement, not folded into an unrelated change's diff.

## What would close this

A deliberate, scoped change: pick a candidate value with real headroom above the 125ms
floor (not the floor itself), and — following this repo's own testing-tier rules — either
reason about it from the documented rate-limits page alone, or have a consumer with tier-3
standing (see `feed.ex`'s "why 30" section for what that means) observe several shards
opening at the tighter spacing against the live venue before adopting it as the new
default. Either way, it is `@default_shard_spacing_ms`'s value that would change, not
`shard_spacing_ms`'s existence as an option — that part is already done.

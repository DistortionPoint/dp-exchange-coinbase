defmodule DpExchange.Coinbase.Feed do
  @moduledoc """
  This venue's subscription lifecycle — internal. The facade's `subscribe/2`,
  `unsubscribe/2`, `update_symbols/2` and `coverage/1` are served from here.

  ## What a consumer can and cannot learn

  A consumer learns *what is arriving*, through `coverage/1`. It cannot learn how: this
  module owns the sockets, the sharding and the pacing, and none of that reaches the
  facade.

  ## Coverage is observed, never intended

  A symbol enters the coverage map when **a payload for it arrives**, never when it is
  subscribed. That distinction is the strongest guarantee in the contract and it exists
  because a venue once reported 325 symbols subscribed and confirmed while 174 were
  delivering. Reporting the subscription would have said 325.

  A symbol that has been subscribed and has delivered nothing is simply absent, which the
  facade documents as `:not_covered`.

  ## Sharded — this used to run on one connection, and that stopped being true

  This venue's whole scope used to run on a single socket, and that was measured: once
  its self-killing heartbeat was fixed it subscribed 401 of 401 pairs on one connection,
  and sharding it anyway opened fourteen connections for no gain.

  **That stopped being true on 2026-08-26.** Coinbase started answering a `level2`
  subscribe over its per-session limit with `"too many L2 streams requested in a single
  session"`, closing the socket — a total data gap, not degraded coverage: measured
  2026-08-27 against a real ~400-symbol universe, 355 of 405 pairs went stale and 1,480
  refusals were logged in one window. The measurement about one socket being enough was
  honest when it was taken; it stopped being true the moment the venue's own limit did.

  `@pairs_per_socket` is **100** — carried over from the reference fix this replaces
  rather than re-derived, the number came from a real production incident, not this
  package's own probing. It sizes `ticker`'s own sockets, and only `ticker`'s: the next
  section is why `level2` stopped sharing it.

  ## `level2` gets its own, smaller sockets — the two channels stopped sharing a shard

  **This stopped being true again, on a different axis, measured against
  DpCryptoManagement's own 406-symbol production universe (issue #22 continuing, not
  reopening — `ticker`'s starvation above is a separate, already-fixed incident in the
  same file).** At `@pairs_per_socket` (100), `shards/1` splits 406 symbols into
  `[100, 100, 100, 100, 6]` — four full shards and a six-symbol remainder. Every `level2`
  subscribe on the four full shards was refused with `"too many L2 streams requested in a
  single session"`; the six-symbol shard's was not. 5,099 refusals were logged across
  sixteen otherwise-healthy boots, and `coverage_by_kind/1` answered `order_book: 6`
  throughout — exactly the tail shard's own symbol count, which is the arithmetic that
  pins the cause on the shard size: `ticker` has no such ceiling and answered
  `quotes: 406` on the same boots, so nothing else about those boots — the connection, the
  alias fix, the resubscribe cadence — explains a number that lines up precisely with one
  shard's population and no other.

  **No Coinbase document states the real ceiling.** Re-read 2026-09-06 specifically
  looking for a per-session `level2` stream count: the Advanced Trade channels reference,
  the connection overview, and the Advanced Trade rate-limits page ("WebSocket
  connections and unauthenticated messages are each limited to 8 per second per IP" — a
  connect-rate ceiling, not a per-session subscription count) all say nothing about how
  many products one session may carry on `level2`. The older Exchange product's own
  separate rate-limits page states a different number entirely — 10 subscriptions per
  *product* per channel, meaning duplicate subscriptions to the same product, not the
  count of distinct products — and this package speaks Advanced Trade (`Socket`'s
  `@endpoint`), not Exchange, so that number would not transfer even if it were on point.
  The prior investigation that first shipped `@pairs_per_socket` found the docs silent on
  this; they still are. This does not stop being true just because the number below is now
  measured — it is measured *behaviour*, never a documented figure.

  **This package still cannot narrow it by probing the venue itself.** `level2` is on
  `@authenticated_channels`, and this repo's own testing strategy draws the line at
  exactly that boundary: tier 2 (live public endpoints, by hand) is fair game, tier 3
  (authenticated) "needs credentials this repo must never hold." Bisecting a real
  session's `level2` subscription size against the live venue with a real credential is
  precisely tier 3, and remains a line this repo does not cross for any endpoint,
  `level2` included. What changed is that a *consumer* — who holds the credential this
  repo structurally cannot — did the bisection, in production, and reported the result
  back as tier-3 evidence. That is a different thing from this package probing itself,
  and the distinction is why the number below is attributed to them rather than to any
  measurement this repo ran.

  **`@level2_pairs_per_socket` is `30`.** Measured 2026-09-06 by DpCryptoManagement
  (issue #22) against the live venue with real credentials, not by this package and not
  from documentation:

  | requested (`n`) | 6 | 12 | 25 | 30 | 31 | 35 | 50 | 100 |
  |---|---|---|---|---|---|---|---|---|
  | verdict | accepted | accepted | accepted | accepted | REFUSED | REFUSED | REFUSED | REFUSED |

  **Method, because a measured number is only worth its method.** One fresh
  `Socket.start_link/1` per attempt, never reused — cumulative session state was
  explicitly the thing under test, which is exactly the question this file's own
  "cumulative vs. concurrent" section below could not otherwise answer. 3s to establish
  the connection; `subscribe(socket, "level2", symbols, creds)`; then 20 seconds draining
  the mailbox *continuously* while tallying. Every symbol came from the consumer's real,
  live 406-symbol scope, so silence means refusal rather than an idle book. Verdict
  `refused` on a `rate_limited` notice, `accepted` on `OrderBook`/`OrderBookDelta`
  payloads. The boundary was confirmed by interleaving two full runs back to back:
  `n=30 accepted, n=31 REFUSED, n=30 accepted, n=31 REFUSED`. A contamination check ran
  too — immediately after a run where `n=31`–`34` refused, `n=6` and `n=30` were re-run
  and both accepted, which is what rules out the refusals being saturation from the
  probing itself rather than a genuine per-session ceiling.

  Same evidentiary standard as the `6` this replaces, just with the boundary actually
  located rather than merely bounded far below a known failure: `30` is the largest value
  with positive evidence of acceptance, `31` the smallest with positive evidence of
  refusal. Nothing between them needed to be guessed this time, unlike `6` versus the old
  `100`.

  **The two channels no longer share a shard slice.** `ticker` keeps `@pairs_per_socket`
  (100) — it has no known ceiling, and shrinking it to match `level2` would multiply
  connection count for the channel that was never the problem, for no benefit `ticker`
  needs. `level2` is chunked separately, at `@level2_pairs_per_socket`, and every chunk of
  either channel opens its own dedicated, single-channel socket: there is no longer a
  shard that carries both. For the 406-symbol universe above that is 5 `ticker` sockets
  (unchanged) plus 14 `level2` sockets (`ceil(406 / 30)`) — 19 total against 73 under the
  `6`-sized grouping this replaces, and 5 before `level2` needed its own grouping at all.
  `Socket`'s own moduledoc records why more sockets than the original single-socket design
  is affordable now in a way it would not have been before 2026-09-06: removing
  in-package `level2` book maintenance cut per-frame decode cost roughly tenfold
  (65–110 ms to 6.6 ms, at the `BTC-USD` book size DpCryptoManagement measured live) —
  decode cost, not socket count, was the resource actually in short supply.

  **Connects are staggered across both groups on one sequence, `ticker` first.** Every new
  socket this module opens — whichever channel it carries — takes the next tick of
  `shard_spacing_ms` (`5_000`ms by default — see that option's own section below), in an
  order that places every touched `ticker` shard ahead of every touched `level2` shard.
  This is what keeps `ticker`'s own boot-time coverage exactly as fast as the section above
  describes: a 406-symbol subscribe still resolves its synchronous reply and its remaining
  `ticker` shards inside the same handful of seconds as before this fix, with `level2`'s 14
  shards ramping in behind them. For that universe the last `level2` shard's tick lands
  roughly 70 seconds after boot (`(14 - 1) * shard_spacing_ms`, at the default) —
  materially slower than `ticker`'s own coverage, and an accepted,
  stated cost, now roughly a fifth of what the `6`-sized grouping cost (about six
  minutes): `order_book` coverage was permanently `6 / 406` before `level2` got its own
  grouping at all, climbing by 5,099 refusals and counting; ramping to `406 / 406` in
  around a minute is strictly better than a ceiling that never moves, and nothing about
  `level2` streaming is boot-latency-sensitive the way `ticker`'s starvation was.

  **`level2` no longer needs to go first on a shared socket, because there is no longer a
  shared socket.** What used to be this section — "`level2` before `ticker`, spaced by
  `@channel_spacing_ms`" — existed only because a subscribe burst on one channel could
  stall the other's `send_frame` on the *same* connection. With every socket now carrying
  exactly one channel, that specific hazard cannot occur, and `@channel_spacing_ms` is
  gone. A subscribe can still hit `:send_timeout` against its own socket's own burst — a
  `level2` socket decoding its own thirty-symbol snapshot, say — so the retry chain below
  is unchanged in kind; `@subscribe_retry_delay_ms` keeps its previous value (`8_000`ms)
  but is no longer *borrowed* from a channel-spacing constant, because that constant no
  longer exists to borrow it from — see its own comment.

  **An adaptive, self-shrinking shard size was considered and rejected — for now.** The
  venue's own refusal could in principle drive `@level2_pairs_per_socket` down further at
  runtime, so a wrong constant could never be silently wrong forever — the option the
  architect's own brief for this fix raised directly. It was not built: correctly
  reconciling a shard *resize*, as opposed to the shard *membership change* `reshard/1`
  already handles, needs this module to tell a live, still-subscribed shard's bookkeeping
  apart from a stale one whose symbols the venue already dropped when it refused and
  closed the connection — and getting that race wrong risks silently under- or
  double-subscribing a shard, which is a worse failure mode than the loud, honest one this
  module otherwise insists on everywhere else. Given `30` is not a guess but the boundary
  itself, now located rather than merely approached from below, a correct runtime resize's
  complexity did not clear its bar against a fixed, evidence-grounded constant plus the
  safety net that already exists: `Socket`'s own `error_kind/1` already classifies "too
  many" as `:rate_limited` and reports it as a `Core.Notice` on every occurrence (see
  `Socket`'s moduledoc), and `coverage_by_kind/1` already never marks a symbol covered for
  `:order_book` on intent alone — both pre-existing, verified unchanged by this fix, not
  new mechanism built for it. If `30` is ever also refused, a consumer with
  `subscribe_notices/1` wired up hears about it exactly as loudly as every other refusal
  in this file, and lowering the constant is a one-line, reviewable change rather than a
  runtime decision this module made silently on its own.

  ## `level2_pairs_per_socket` — a supervision option, not only a constant

  What was rejected above is a *runtime, self-adjusting* resize — this module deciding on
  its own, mid-flight, to shrink the shard size because the venue refused one. What ships
  here instead is a *static, consumer-set* one: `30` is still the compiled-in default, but
  a caller of `DpExchange.Coinbase` (or `Feed.start_link/1` directly) can pass
  `level2_pairs_per_socket: n` and have every `level2` shard chunk to `n` from boot,
  through `DpExchange.Coinbase.Supervisor`'s ordinary opts pass-through — no Supervisor
  code change was needed, because `Feed` already reads its other diagnostic knobs
  (`resubscribe_interval_ms`, `subscribe_retry_delay_ms`) the identical way.

  This exists because the measured `30` is a fact about the venue on 2026-09-06, not a
  fact about this package, and venue facts change. A hardcoded constant means a venue-side
  change costs every consumer a package release and a redeploy; an option means a consumer
  absorbs it the same day — DpCryptoManagement asked for exactly this
  (`DistortionPoint/dp-exchange-core` issue #22) once they had already done the
  measurement that justified it.

  **Validated, not silently coerced — but only on the axis that is unconditionally
  nonsense.** A non-integer or a value below `1` cannot chunk anything and is refused at
  `init/1` (an `ArgumentError`, which fails `Feed.start_link/1` and therefore
  `DpExchange.Coinbase.Supervisor.start_link/1`) rather than coerced into something that
  happens to run. A value *above* the measured `30`, by contrast, is honoured, not
  capped — deliberately.
  Capping at `30` would quietly defeat the option's own stated purpose: a consumer setting
  it above today's measurement is doing so *because* they believe the venue's own ceiling
  has moved, which this package has no way to verify itself (see "why 30" above — this
  repo cannot bisect an authenticated session live). Refusing to even try would leave the
  option unable to do the one thing it was built for. What it gets instead is a loud
  `Logger.warning` at start naming the measured ceiling, its date and source, and the
  concrete risk — stated as what has actually been observed, not more than that.

  **What "the concrete risk" is, precisely, is now settled — DpCryptoManagement re-ran
  exactly this case.** Setting this option above `30` means every ordinary `level2`
  subscribe this package sends for that shard is, by itself, a SINGLE subscribe over the
  venue's real limit. **DpCryptoManagement measured that shape directly, 2026-09-07**
  (issue #22 continuing): one socket, `Socket.subscribe/4` for `n = 30` (accepted,
  `books=30`, `deltas=4258`, all 30 symbols delivering), then `n = 60` and `n = 120`
  (both **REFUSED** — `rate_limited`, `"too many L2 streams requested in a single
  session"` — `books=0`, `deltas=0`, nothing delivering), tried in both ascending and
  largest-first order. The refusal is **wholesale**, not a partial grant: `n = 60` and
  `n = 120` both delivered nothing at all, not the first 30, in either ordering — the
  shard's entire coverage is lost. And **the socket survives**: no `:DOWN` on a monitor,
  `Process.alive?/1` true after a 40-second drain, both orderings. Cumulative overage (two
  smaller subscribes releasing nothing in between — see "the ceiling is concurrent, not
  cumulative" below) and a single oversized subscribe now read as the SAME behaviour:
  refused wholesale, socket alive. See
  `docs/reference/coinbase/level2-session-limit.md` for the full, dated account.

  **That makes this risk harder to notice than the warning used to say, not easier.** A
  socket that closes, the way the 2026-08-26 incident below describes, at least announces
  itself — a `:link_down` notice, a reconnect, a liveness gap a consumer can watch for. A
  refusal on a socket that stays alive announces nothing of the kind: the venue's refusal
  still reaches `subscribe_notices/1` as a `:rate_limited` `Core.Notice` (`Socket`'s own
  `error_kind/1` already classifies "too many" this way), but liveness itself looks
  perfect and the oversized shard simply never starts delivering. `coverage/1` and
  `coverage_by_kind/1` are the only things that reveal it — both report only symbols that
  actually delivered a payload, so a shard that never delivers never counts as covered,
  but nothing about the socket itself signals the loss the way a disconnect would.

  **The 2026-08-26 incident record stays — it is not overturned, it is unexplained.** That
  incident (see "level2 gets its own, smaller sockets" above, measured 2026-08-27)
  reported the refusal closing the socket: 355 of 405 pairs stale, 1,480 refusals logged
  in one window. The 2026-09-07 measurement above could not reproduce that outcome, under
  either ordering. Neither this file nor DpCryptoManagement's own report resolves why:
  either the venue's behaviour changed between the two dates, or the 2026-08-26 incident
  had a second, unidentified cause. Both readings stay on record, dated and attributed,
  rather than one being asserted over the other.

  **The default stays at `30`, without injected headroom, and that was a deliberate
  choice, not an oversight.** `30` is not "the largest value that has not yet failed"
  (which `6` genuinely was, before this investigation) — it is the actual, located
  boundary: `30` accepted, `31` refused, confirmed by interleaving and a contamination
  check (see "why 30" above). Shrinking the *default* below a boundary that precise, on
  this package's own initiative, would misrepresent what was measured — the whole point
  of "declare what you measured, not what you assume." It would also buy nothing against
  the one risk that is still genuinely open: the unconditional 60-second resubscribe
  re-issuing unchanged symbols on an already-open socket forever (see "cumulative vs.
  concurrent" below) is an *attempt*-shaped risk, not a *concurrent-membership*-shaped
  one — a smaller shard does not reduce how many times that timer re-issues the same
  request, so headroom on shard size does not address it. A consumer who nonetheless wants
  margin against the concurrent ceiling — for reasons specific to their own scope or risk
  tolerance — has exactly the lever to take it themselves: pass a smaller
  `level2_pairs_per_socket`, e.g. `25`, and this package honours it precisely.

  **`ticker` gets no equivalent option, on purpose, for now.** `@pairs_per_socket` (100)
  is also a constant, also inherited rather than re-derived (see above), and also never
  probed against this venue — the same three facts that motivated `level2`'s option. What
  is different is that `level2`'s option answers a *known, located* venue ceiling a
  consumer already hit in production; `ticker` has no known ceiling of any kind to tune
  against, measured or suspected. An option with nothing to point it at is surface for a
  problem that has not been demonstrated to exist — consistency-for-its-own-sake is not
  this family's standard, evidence is. If `ticker` ever develops a measured ceiling the
  way `level2` did, the fix is the same one this section documents, applied to
  `@pairs_per_socket` instead: nothing about this design is `level2`-specific.

  ## The ceiling is concurrent, not cumulative — resolved, not merely bounded

  **2026-09-07 update.** This section used to be titled "Cumulative vs. concurrent — the
  ceiling this package cannot rule out by itself." The question it posed is answered below.
  The reasoning that got this package here is kept rather than deleted, because the fix it
  produced — and the cheaper one that replaced it — both depend on understanding why it was
  written; see "When a moduledoc records an incident" in this package's own `CLAUDE.md`.

  The 2026-09-06 bisection above (`n=6..100`) used a fresh `Socket.start_link/1` for every
  attempt **on purpose**, "because cumulative session state is the thing under test." That
  control bought the consumer's measurement precision it would not otherwise have — but it
  also meant that result could only prove the ceiling on *concurrently held* `level2`
  products. It could not, by its own design, say whether Coinbase's real ceiling counts
  concurrent subscriptions or **cumulative** ones — every distinct product a session was
  ever asked to carry, whether or not all of them were still wanted now. This module's own
  long-lived sockets were exactly the case that distinction mattered for.

  **The code was checked, not guessed, while the answer was still unknown.**
  `reconcile_shard/7` — reached from `reshard/1` whenever `subscribe/3`, `unsubscribe/2` or
  `update_symbols/2` changed a shard `Feed` already had a socket open for — computed
  `added = wanted -- current` and sent exactly those newly-added symbols to
  `Socket.subscribe/4` on the same already-open socket, never a fresh one.
  `wanted_symbols` per shard is always `≤ @level2_pairs_per_socket` by construction, so no
  single subscribe call this module ever sent asked one socket for more than the shard
  ceiling *at that instant* — but nothing stopped the same socket's own subscription
  HISTORY from growing past it over time, one `added` batch at a time. This was never a
  rare edge case: `MapSet.to_list/1`'s enumeration order is a function of the *current* key
  set, not of insertion history — proven directly against a 406-member synthetic set, where
  adding one member moves 8 symbols to a different chunk index and removing one moves 3 —
  so ordinary universe churn, not only a caller explicitly asking to add a symbol,
  routinely hands an already-open shard products it has never carried before.

  **Commit `9139881` hedged rather than guessed.** With the answer unknown and `30`
  offering none of the headroom the old, deliberately-pessimistic `6` had, growing an
  already-open `level2` shard replaced its socket outright — a fresh connection, subscribed
  with the shard's whole target set, only then discarding the old one — so no `level2`
  socket this package opened was ever asked, over its whole lifetime, to carry more
  distinct products than one shard's worth. That made "should never be over the ceiling"
  true unconditionally, concurrently *and* cumulatively, regardless of which of Coinbase's
  two possible countings turned out to be real. It was also, by construction, more
  expensive than necessary if the answer turned out to be the convenient one: a full
  reconnect, a fresh snapshot for every symbol on the shard including the ones that never
  changed, and a coverage gap while the new socket came up — every reshard that grew a
  shard by even one symbol paid for a whole shard's worth of resubscribe.

  **DpCryptoManagement answered the question directly, 2026-09-07, issue #22 continuing.**
  Three probes, **each on ONE socket, using raw `Socket.subscribe/4` — deliberately not
  `Feed` or `update_symbols/2`** — so the result is evidence about the VENUE's own
  accounting, not about this package's own dedup or bookkeeping. All three drained
  continuously against real products from the consumer's live scope:

  1. **The same 30 products, re-sent roughly 60 seconds apart, 14 times: all accepted.**
     The socket stayed alive throughout, roughly 13 minutes. `books=30` on the first
     attempt and `books=0` on every repeat — the venue recognised those products were
     already subscribed and replayed no snapshot, rather than refusing the repeat.
     **Repeats do not accumulate.** This is also, precisely, the "attempt-counting" probe
     the open question below used to call for: it directly answers whether the
     unconditional 60-second resubscribe this coordinator runs forever could itself feed
     an attempt-counted ceiling. It does not, at any shard size, for as long as 14 repeats
     over 13 minutes is representative of a longer-running socket.
  2. **A different 30 products, on the SAME socket, without unsubscribing the first batch
     first: `cumulative=60` — REFUSED**, `"too many L2 streams requested in a single
     session"`. **But the socket stayed alive, and the first batch kept delivering** (27
     of 30 still ticking during the refusal) — only the second, unreleased batch was
     rejected.
  3. **Four batches of 30 products each, always unsubscribing the previous batch before
     requesting the next: all four accepted**, a fresh snapshot every time — 120 distinct
     products moved through one socket's lifetime, never more than 30 live at any moment.

  **So the ceiling is 30 CONCURRENT products per session, not 30 over a session's
  lifetime.** `unsubscribe` releases budget the venue actually honours (probe 3); a
  long-lived socket does not degrade as its membership churns, provided it releases what
  it is giving up before it asks for what it is gaining (probe 2, read the other way
  round). The cumulative-hedge `9139881` shipped is no longer necessary, and — see the next
  section — it was strictly more expensive than the alternative this measurement unlocks.

  ## Unsubscribe before subscribe — what replaced socket replacement

  Socket replacement bought a guarantee this package no longer needs to buy that way.
  `reconcile_shard/7`'s `"level2"` clause is gone; every shard, either channel, now
  reconciles on its EXISTING socket through one function, `reconcile_shard_in_place/7` —
  the mechanism `ticker` already used, since it never had a ceiling to protect against in
  the first place. For a shard whose membership changes, `removed` is unsubscribed and
  `added` is subscribed on that one socket — **and `removed` is unsubscribed FIRST, every
  time, never the other way round, and the subscribe never goes out until the unsubscribe
  has.**

  **The ordering is load-bearing, and it is the whole point.** Probe 3 above works BECAUSE
  the departing batch's slots were freed before the arriving batch was requested; probe 2
  is the identical operation in the other order — request before release — and it was
  refused. A `level2` shard already carrying its full `level2_pairs_per_socket` that issued
  a bare additive subscribe would hit exactly probe 2's shape, and per that probe the
  refusal is QUIET from a consumer's own vantage point: the socket lives, the shard's
  existing symbols keep flowing, and only the newly-requested ones silently never arrive.
  That is precisely the failure this fix exists not to introduce, so shrinking always
  happens before growing: the transient concurrent count during any reconcile is bounded by
  `max(length(current), length(wanted))`, and both are already bounded by shard
  construction — never more than `level2_pairs_per_socket`, including mid-reconcile, not
  only at rest.

  **What guarantee this package actually has, and how it was established — read from
  `Socket`, not assumed.** `Socket.subscribe/4` and `Socket.unsubscribe/3` both go through
  `FrameSender.send/3`, which calls `WebSockex.send_frame/2` — a *synchronous* `:gen.call`
  into the WebSockex connection process that returns only once that ONE process has handed
  the frame to the underlying TCP socket (or reports why it could not — see `FrameSender`'s
  own moduledoc). Because `attempt_channel_reconcile/6` (and the synchronous clause of
  `reconcile_shard_in_place/7`) never calls `Socket.subscribe/4` until `Socket.unsubscribe/3`
  for the SAME message has returned `:ok`, the unsubscribe frame is written to this one TCP
  connection strictly before the subscribe frame is. TCP delivers bytes on one connection in
  the order they were written, and Coinbase's own session, so far as this package or
  DpCryptoManagement has ever observed, processes one connection's frames in the order it
  receives them — nothing in any probe above, or in the original bisection, has ever shown
  the venue reordering two frames sent on the same socket. Given that, sending the frames in
  this order is what makes the venue very likely to *process* the unsubscribe before the
  subscribe too, even though this package cannot observe that processing directly.

  **That is the honest limit of what this package can confirm, and it is worth stating
  plainly rather than folding into the paragraph above.** `Socket.unsubscribe/3`'s `:ok`
  means "the frame was handed to this connection's own send," never "the venue has finished
  releasing this shard's departing slots" — Coinbase's `l2_data` protocol gives this package
  no acknowledgement frame for an unsubscribe to wait on (contrast `"channel" =>
  "subscriptions"`, which acknowledges a *subscribe*, and which `dispatch/2` deliberately
  does not treat as coverage — see this moduledoc's own opening section — let alone waits on
  here). So this package relies on frame ORDER on one connection, not on a confirmed
  venue-side STATE transition, to keep a reconcile inside the shard's own cap. Given probe
  3's own success — four rounds of exactly this pattern, no waiting for any acknowledgement
  between the unsubscribe and the next subscribe, all four accepted — ordering alone,
  without an acknowledgement this protocol does not offer, is what this package actually
  has, and it is what DpCryptoManagement's own probe already relied on to get the result it
  got.

  **A transient send failure on the unsubscribe half withholds the subscribe half entirely,
  rather than risk the alternative.** `attempt_channel_reconcile/6` retries a failed
  unsubscribe with the same bounded backoff a channel subscribe already gets
  (`handle_unsubscribe_failure/8`); the subscribe for `added` is never attempted until the
  unsubscribe has actually gone out, or the retries are exhausted and the added symbols are
  withheld for this cycle (reported through `subscribe_notices/1`, the same as any other
  subscribe that never took — see "a timed-out subscribe used to be thrown away" below).
  Silently proceeding to subscribe anyway — on the theory that the earlier unsubscribe
  frame probably still made it out despite the reported failure, which `FrameSender`'s own
  moduledoc says is often true — would reintroduce exactly the risk this whole fix exists
  to close, on the one path where this package cannot check.

  **This used to leave one gap open: a permanently stranded unsubscribe. It does not any
  more — see "a stranded unsubscribe is not silently forgotten" below**, which was closed
  after this file first shipped this section, on a coordinator's own trace rather than a
  self-report: `reconcile_shard_in_place/7` recorded `state.shards[key].symbols = wanted`
  unconditionally, on both its sync and deferred clauses, regardless of whether the
  unsubscribe underneath it ever actually succeeded. `removed`'s symbols vanished from
  this module's own bookkeeping the moment retries gave up, even though they were never
  released at the venue — a real, permanent budget leak, closed by
  `state.pending_unsubscribes` and the mechanism the next section documents.

  **The reshuffle hazard that made this real in the first place is unchanged, and still
  handled — just more cheaply now.** `reshard/1` still recomputes chunks on every
  `subscribe/3`, `unsubscribe/2` and `update_symbols/2`, and a `MapSet`'s enumeration order
  still shifts on almost any membership change (moving 8 of 406 symbols on one add, 3 on
  one removal — the same proof as before, unchanged by this fix). What changed is what
  happens when that reshuffle hands an already-open shard symbols it has never carried
  before: it no longer costs a reconnect, a fresh snapshot for the shard's entire unchanged
  membership, and a coverage gap while a brand-new socket comes up — it costs exactly two
  frames, in order, on the connection that was already open.

  *(This section used to end with two open probes recommended for a future consumer to
  run — "attempt-counting" and "cumulative distinct-count." Probe 1 above IS the
  attempt-counting probe; it is no longer open. Nothing on the cumulative-vs-concurrent
  axis this section is about remains open. What was, for a time, a genuinely open gap on a
  DIFFERENT axis — a permanently stranded unsubscribe — is the next section's subject, and
  it is closed too.)*

  ## A stranded unsubscribe is not silently forgotten

  **Traced, not merely reviewed.** The withheld-`added` recovery two sections up was
  checked by following what `reconcile_shard_in_place/7` actually records, not by trusting
  the summary of it: the WITHHELD side (`added`) does recover — the 60-second cycle
  re-issues `state.shards[key].symbols`, which already equals `wanted`, so those symbols
  get subscribed on the next tick regardless of whether this reconcile's own unsubscribe
  ever succeeded. The STRANDED side (`removed`) did not — nothing re-issued an unsubscribe
  for it, and this module's own bookkeeping had already stopped tracking it as owed. Left
  alone, a shard that hit this even once would degrade into exactly the failure this whole
  file exists to prevent: the venue's live count for that session sitting at
  `old ∪ wanted` rather than `wanted`, eventually exceeding the shard's own cap, at which
  point every later subscribe for that shard is refused — quietly, per DpCryptoManagement's
  own probe 2: socket alive, existing symbols still flowing, new ones silently absent. The
  recovery path for `added` makes this WORSE in a sense, not better, because it keeps
  re-issuing subscribes into a budget the stranded slots guarantee cannot fit.

  **`state.pending_unsubscribes` — `%{{channel, index} => [symbol, ...]}` — is that
  record.** `strand_unsubscribe/7` writes to it whenever a reconcile gives up on releasing
  some `removed` symbols, on EITHER the synchronous clause (no retry chain of its own — one
  attempt, then straight to stranding, the same "no retry in the primary path" shape
  `open_shard/5`'s sync clause already has) or the deferred one's bounded retry chain
  exhausting (`handle_unsubscribe_failure/8`). `handle_info(:resubscribe, _)` reads it back
  on the SAME unconditional cadence `retry_missing_shards/1` already uses to recover a
  shard whose socket never opened at all — the governing principle is that function's own
  comment, word for word: a shard with "NO automatic recovery path at all, ever" is "a
  silent, permanent coverage gap indistinguishable from a quiet market, on a venue this
  coordinator's OWN moduledoc says must never go unretried." A stranded unsubscribe is the
  identical defect in a different place, and gets the identical fix.

  **Ordering still applies, and it is reached through the SAME machinery, not a parallel
  one.** Each resubscribe tick now sends `{:channel_reconcile, key, socket, channel,
  pending, symbols, credentials}` per shard — `pending` (a shard's own
  `state.pending_unsubscribes` entry, `[]` in the ordinary case) as `removed`, and
  `symbols` (the shard's WHOLE current membership, not a delta — matching exactly what an
  unconditional resubscribe already re-issued before this fix) as `added`. This is the
  identical `attempt_channel_reconcile/6` an ordinary `subscribe/3`, `unsubscribe/2` or
  `update_symbols/2` reconcile already runs, so the retried unsubscribe precedes that
  shard's resubscribe on the same tick for the same reason it precedes one anywhere else in
  this file — not a second, separately-reasoned code path that could drift from the first.
  For the ordinary case (`pending == []`) this costs nothing beyond what a plain
  `Socket.subscribe/4` already cost: `unsubscribe_step/3` short-circuits an empty list
  without sending anything.

  **What clears an entry: a successful send of exactly those symbols, per symbol, not per
  shard.** `clear_pending_unsubscribe/3` computes `pending -- removed` rather than deleting
  the whole key, because a shard can be carrying a stranded release from one reconcile
  while an unrelated, still-outstanding one from an earlier reconcile also sits there —
  only the symbols THIS successful send actually covered are removed. `strand_unsubscribe/7`
  is symmetric: it merges (`Enum.uniq(&1 ++ removed)`), never overwrites, so a later,
  unrelated stranding does not erase an earlier one still waiting on its own retry.

  **What clears an entry the other way: the shard itself going away.**
  `drop_unwanted_shards/3` now drops a shard's `pending_unsubscribes` entry in the same
  breath it drops the shard from `state.shards` — necessary, not cosmetic:
  `handle_info(:resubscribe, _)` walks `Map.keys(state.shards)` specifically, so a key
  absent from `state.shards` is a key nothing ever revisits. Without this, a shard that
  vanished (every symbol unsubscribed, or churned away entirely) while still carrying a
  stranded release would leave that bookkeeping orphaned — retried by nothing — forever.
  This answers "can `state.pending_unsubscribes` grow without bound": bounded by however
  many currently-OPEN shards carry an unresolved stranding, not by this module's all-time
  history of failures, because a dropped shard's own entry is dropped with it.

  **A stranded symbol re-added to the same shard while still pending is not a hazard,
  because `added` is always the shard's WHOLE current set, never a delta.** Ordinary churn
  can plausibly move a symbol out (stranding its release) and back in before the next tick
  retries it. Whatever the retried `unsubscribe` does to that symbol, the SAME reconcile's
  `subscribe` — for the shard's full, current membership — puts it right back if it is
  still wanted, in the same message, in order. At worst this costs one redundant
  unsubscribe/resubscribe pair for that one symbol; it never leaves the shard short a
  symbol it currently wants.

  **What is not built, and the honest reason: correlating a stranding to a socket
  RECONNECT specifically.** A socket that dies and reconnects gets a fresh session with the
  venue — every stranded slot on the OLD session is released along with it, whether this
  module notices or not. But `Socket` deliberately holds no shard-correlating identity in
  its `:link_up`/`:link_down` notices (see this module's own `handle_info({:dp_exchange,
  :coinbase, %Notice{}}, _)` — every socket's notices arrive through the identical,
  unattributed shape, matching `Socket`'s own moduledoc: "`Socket` holds no book to key by
  anything"), and WebSockex's own reconnect keeps the same pid, so pid identity cannot
  substitute either. Building that correlation would mean widening `Socket`'s own contract
  — real, cross-module surface — for a case whose cost, left as is, is bounded and low: a
  stale `pending_unsubscribes` entry retried against a fresh session sends one
  `unsubscribe` for a symbol the venue no longer has subscribed, which this family's stated
  idempotency assumption (`FrameSender`'s own moduledoc: "subscribes are idempotent on
  every venue in this family, so a duplicate is harmless") extends to as a working
  assumption for `unsubscribe` too, though NOT independently measured against an
  unsubscribed symbol specifically — an honestly-labelled gap, not a silent one. And
  because that stale unsubscribe is immediately followed, in the SAME reconcile, by a
  subscribe of the shard's whole current membership, a stale entry costs at most one wasted
  frame and self-corrects the same tick — it cannot leave the shard under-subscribed. There
  is also a practical reason the stale case rarely persists at all: whatever made the
  earlier sends fail (a busy, backed-up socket) is usually exactly what a reconnect clears,
  so the very next retry after a reconnect is likely to simply succeed and clear the entry
  normally, not because the reconnect was detected, but because reconnecting tends to
  un-wedge the condition that caused the stranding in the first place.

  **What `transient_frame_failure?/1`'s real reach turns out to be, stated plainly rather
  than assumed generous.** Every reason `Socket.unsubscribe/3` can return comes from
  `FrameSender` alone — `:send_timeout` or `{:send_exit, reason}` — and both are classified
  transient. `Socket.unsubscribe/3` has no analogue of a subscribe's
  `{:credentials_required, channel}`: it builds no JWT and checks no credentials, per its
  own definition (contrast `Socket.subscribe/4`'s `subscription_message/3`). So the
  non-transient `cond` branch in `handle_unsubscribe_failure/8` does not fire against the
  real venue today — "permanently stranded" is reached, in practice, only by EXHAUSTING the
  bounded retry chain against a socket that keeps answering `:send_timeout` or
  `{:send_exit, _}` without ever dying outright (`Process.alive?/1` staying `true`
  throughout — a socket that is genuinely dead short-circuits every reconcile path before
  it reaches this branch at all, matching every other dead-socket guard in this module).
  The non-transient branch is kept anyway, wired to the identical stranding-and-retry
  behaviour as an exhausted chain, for the same "do not assume a shape that happens to hold
  today" reason `handle_subscribe_failure/6` keeps its own — but it is not what this
  mechanism was actually built to close in production; the retry-exhaustion branch is.

  ## A refusal is not always a clean gate — observed, not explained

  DpCryptoManagement's bisection above answers "accepted or refused" per `n`, but two of
  their runs saw something this package has no account of: at `n = 31`–`34` in one run,
  `books = 0` (a clean refusal); at `n = 35`–`50` in the same run, 1,300–2,000 books
  delivered *alongside* the `rate_limited` notice — a partially honoured oversized
  subscription. A later run saw `n = 31` refuse *with* 1,655 books delivered. None of this
  moves the boundary — every `n ≥ 31` refused and every `n ≤ 30` did not, in both runs —
  but it means "refused" can apparently be a spectrum rather than a gate. See
  `docs/reference/coinbase/level2-session-limit.md` for the full, dated account; it is
  recorded there as an observed venue characteristic with no explanation attached, not
  rationalised into one.

  **At `@level2_pairs_per_socket` = 30 this package should never itself trigger a
  partial refusal, and that reasoning was checked, not assumed:** every subscribe this
  module sends for a `level2` shard carries at most 30 symbols — `wanted_symbols` per
  shard is `≤ @level2_pairs_per_socket` by construction — and the unsubscribe-before-
  subscribe reconcile above (see "unsubscribe before subscribe") keeps every socket's
  CONCURRENT count within that same bound at every instant of a reconcile, not only at
  rest, regardless of which of Coinbase's two possible countings turns out to be real.
  Nothing in this package's own behaviour asks for 31 or more at once. (These partial
  refusals were themselves observed on SINGLE, oversized subscribes — the same shape as
  the 2026-08-26 incident and the `level2_pairs_per_socket` option's own warning below,
  neither of which this package's own behaviour triggers either — not on the cumulative
  overage the 2026-09-07 probes above exercised. The two shapes are now known, 2026-09-07,
  to behave alike on whether the socket survives a refusal — both do, see the option's own
  warning above — but that does not extend to the partial-delivery spectrum this section
  is about: the 2026-09-07 single-oversized re-test saw clean refusals, `books=0`, at
  every size it tried, not the partial delivery this section describes, so the spectrum
  observed here stays its own, separate, unexplained venue characteristic.) Should the
  venue nonetheless
  answer a `rate_limited` notice while some of that same shard's symbols are genuinely
  delivering — the exact shape DpCryptoManagement observed — `coverage/1` and
  `coverage_by_kind/1` need no special case to stay honest: both are built entirely from
  `state.delivering`, which is populated only by `handle_info({:dp_exchange, :coinbase,
  payload}, state)` when an actual `Types.Quote`, `Types.OrderBook` or
  `Types.OrderBookDelta` arrives, tagged with whichever symbol it carries.
  `handle_info({:dp_exchange, :coinbase, %Notice{}}, state)` — the clause a
  `:rate_limited` notice takes — never touches `state.delivering` at all. A symbol that
  delivered a book is covered for `:order_book` whether or not its shard's subscribe was
  also, separately, answered with a refusal notice; a symbol that delivered nothing stays
  `:not_covered` regardless. The two facts were never coupled in the first place, which is
  the same "coverage is observed, never intended" guarantee this moduledoc opens with,
  just exercised by a venue behaviour this package did not anticipate rather than one it
  designed for.

  ## A timed-out subscribe used to be thrown away — now it is retried

  `FrameSender`'s own moduledoc says the whole point of turning a `send_frame` exit into
  `{:error, :send_timeout}` is that "a slow socket becomes a failed batch, which a caller
  can report and retry, rather than a dead connection", and that subscribes are idempotent
  on every venue in this family, so a duplicate is harmless. This module used to log that
  error and drop it — the retry half of the design was never wired, so a `channel_subscribe`
  that lost the race against a `level2` snapshot burst simply stayed unsubscribed until the
  next unconditional resubscribe tick, which reproduces the identical busy-socket condition
  and fails identically.

  This is not hypothetical. A consumer running against a real ~400-symbol universe measured
  the exact inversion this predicts, across five boots over roughly 5.5 hours:

  | state | quotes (`ticker`) | order_book (`level2`) |
  |---|---|---|
  | broken (4 boots) | ~5 / 406 | ~406 / 406, 11,000+ frames |
  | healthy (1 boot) | 400 / 406 | 6 / 406 |

  When `level2` gets through broadly, its opening snapshot burst is what starves `ticker`;
  when the venue refused most `level2` subscriptions outright (its own per-session stream
  limit — see above), `ticker` had the socket to itself and got everything. A lone
  `:send_timeout` on a `ticker` subscribe was also observed directly in an earlier run.
  Both are DpCryptoManagement's issue #22.

  ### Classify before retrying — not every failure can be fixed by waiting

  `{:error, :send_timeout}` and `{:error, {:send_exit, reason}}` are **transient**: the
  socket was busy decoding a burst, or briefly gone, and the identical request can
  reasonably succeed once it catches up. `{:error, {:credentials_required, channel}}` (see
  `Socket`'s `subscription_message/3`) is **permanent** — no amount of waiting supplies a
  credential that was never given, and retrying it would only loop, so it fails loudly on
  the first attempt and is never rescheduled.

  ### The backoff waits out a socket's own burst, not another channel's

  At the time this was written, a retry waited out the same busy-socket condition
  `@channel_spacing_ms` existed to wait out between `level2` and `ticker` sharing one
  socket, so `@subscribe_retry_delay_ms` borrowed that value rather than guessing a second
  number for the same underlying wait. `@channel_spacing_ms` is gone now that no socket
  carries two channels — see "`level2` gets its own, smaller sockets" above —
  `@subscribe_retry_delay_ms` keeps its value (`8_000`ms) but stands on its own reasoning:
  a socket can still be busy decoding *its own* just-subscribed burst (a `level2` socket's
  own snapshot, however small its shard), and the identical request can reasonably succeed
  once that clears. `@max_subscribe_retries` is `2`: one initial attempt plus two retries
  is enough to survive one snapshot burst without turning a stuck socket into an unbounded
  loop. See the constants' own comments for the arithmetic that keeps the whole retry
  chain well inside a resubscribe cycle, so it can never stack frames against the
  unconditional re-issue documented below.

  ### Exhaustion is loud

  A channel that never subscribed is exactly the invisible half-dead feed this whole issue
  is about, and it used to surface as a `Logger.warning` a consumer had no facade-level way
  to see. Giving up — whether because the failure was permanent or because retries ran out
  — now also emits a `Core.Notice` of kind `:coverage_change`: those symbols will not
  deliver this kind of data, which is exactly the fact `coverage/1` and `coverage_by_kind/1`
  need a consumer to go re-check rather than discover from a quiet chart.

  ## A reconnect that does not resubscribe is a coverage collapse with no error

  WebSockex reconnects a dropped socket on its own, and a bare reconnect leaves it
  connected and subscribed to **nothing** — silently, because a socket that is up and
  receiving nothing is not itself an error. That is a real, measured incident on this
  venue's own reference implementation: coverage decayed from full to the REST-poll
  floor over roughly forty minutes with the feed still reporting healthy, because
  nothing re-asked the venue for anything after the reconnect.

  This coordinator re-issues every shard's subscriptions on a timer, unconditionally.
  Re-subscribing a channel the socket already carries costs one frame the venue ignores;
  not re-subscribing one it silently dropped costs the shard's whole coverage until
  someone notices a quiet chart.

  ## Every shard beyond the first must open on its own tick, not the same one

  `shard_spacing_ms` staggers shard opens **relative to each other**, not relative to a
  fixed instant. A scope wide enough to need three or more shards — DpCryptoManagement's
  issue #20, 406 symbols / 5 shards, filed against real production traffic — used to
  schedule every shard past the first (the synchronous one) with the *same* fixed delay,
  so all of them opened in the same instant: exactly the connect burst this module's own
  design note above warns the venue answers with resets. Only the shard whose burst-mate
  connections lost that race ever delivered a tick; coverage sat at whatever fraction of
  one shard survived, indistinguishable from the outside from a quiet market. The
  60-second unconditional resubscribe re-issued the same burst every minute. Both paths
  now schedule each shard's turn `position * shard_spacing_ms` after the one before it —
  see "`shard_spacing_ms` — a supervision option" below for what that value is, where it
  comes from, and how a consumer can change it.

  **This staggering has to reach an already-open shard too, not only a brand-new
  connection.** `reconcile_shard/7` used to receive the same `delay` `reshard/1` computes
  for it and drop it on the floor — every already-open shard `update_symbols/2` touches in
  one call had its `level2` subscribe scheduled at the identical instant. That is not the
  connect burst above (no new socket opens), but it is a related hazard: `Socket.
  subscribe/4` blocks THIS `GenServer` — via `FrameSender`, up to `WebSockex.send_frame/2`'s
  5s window — for as long as its target socket takes to acknowledge, and several such
  messages landing in this process's own mailbox together serialise into back-to-back
  blocking sends, stalling `coverage/1` and every other call to this `Feed` for as long as
  the slowest one takes. Fixed the same way: `delay` now reaches `reconcile_shard/7` and
  staggers its frames exactly as it already staggered a new shard's.

  ## `shard_spacing_ms` — a supervision option, so a test does not have to wait out a
  production timer to prove staggering happened

  `30` in `@default_level2_pairs_per_socket` and `60_000` in
  `@default_resubscribe_interval_ms` both became supervision options once they had a
  reason a consumer might legitimately want to move them. `shard_spacing_ms` gets the
  same treatment for a different reason: this package's own test suite needed one first.

  Five of this file's own sharding tests exist to prove staggering happened — that a
  connect burst is spread across ticks, that `ticker` shards are scheduled ahead of
  `level2` ones, that an already-open shard's reconcile is staggered too (the
  "already-open shard" fix two sections up) — and every one of them, before this option
  existed, could only prove that by actually waiting out `@shard_spacing_ms` in real
  time: 45 of this suite's roughly 51 seconds, across five tests, one of them 15 seconds
  on its own. That is not merely slow; a test that synchronises by sleeping out a real
  production timer is the same shape of hazard `wait_until/3` exists elsewhere in this
  suite to avoid — passing locally, then flaking in a more loaded CI the timer was never
  sized for. `Feed.start_link/1` (via `DpExchange.Coinbase.Supervisor`'s ordinary opts
  pass-through — no Supervisor code change needed, the same as `level2_pairs_per_socket`)
  now accepts `shard_spacing_ms: n` and every stagger this module schedules — a new
  shard's connect, an already-open shard's reconcile, the unconditional resubscribe, the
  derived floor under `resubscribe_interval_ms` (`next_resubscribe_delay/1`) — reads it
  from `state` instead of the module attribute. A test drives it down to a few tens of
  milliseconds and keeps every one of those assertions meaningful: the relative ordering
  (shard 1 before shard 2, `ticker` before `level2`) and the fact that a real,
  positive delay was scheduled at all — see each test's own comment for how it does that
  without merely asserting the calls happened.

  **Validated the same way `level2_pairs_per_socket` is, on the axis that is
  unconditionally nonsense.** A negative value or a non-integer cannot schedule
  `Process.send_after/3` at all and is refused at `init/1` with an `ArgumentError` — see
  `validate_shard_spacing_ms!/1`. `0` is NOT refused: `Process.send_after/3` accepts it
  without complaint, and unlike a negative delay there is nothing mathematically broken
  about "every shard opens in the same instant" — it is simply the connect burst this
  whole file otherwise exists to avoid, which is the next paragraph's problem, not this
  one.

  **This is also a knob pointed at a venue rate limit, and this package just spent one
  investigation (`level2_pairs_per_socket`, above) learning what happens when a number
  that should be the venue's own fact is instead a guess.** Unlike `level2`'s per-session
  product ceiling, though, Coinbase does document a connect-rate number: the Advanced
  Trade rate-limits page states "WebSocket connections ... are ... limited to 8 per
  second per IP" (re-read 2026-09-06, the same pass that produced the `level2` ceiling
  above). This module opens one new socket per `shard_spacing_ms` tick, so that figure
  converts directly into a floor: `ceil(1_000 / 8)` = `125`ms. A consumer setting
  something below that is asking this package's own connects alone to exceed a limit
  Coinbase states outright, independent of whatever else shares that IP.

  Below the floor is honoured, not refused — the same shape as `level2_pairs_per_socket`
  above its own measured ceiling, and for a symmetric reason: this package has no
  visibility into a consumer's own network position (a dedicated IP with headroom this
  repo cannot see, say), so it does not get to assume the conservative number is the only
  correct one for every consumer. What a sub-floor value gets instead is a loud
  `Logger.warning` naming the documented floor, its source, and the concrete risk —
  connects tighter than the venue's own stated per-IP rate risk the connect-burst resets
  this moduledoc opens with — legible, not silently accepted, exactly the standard
  `level2_pairs_per_socket` set above the measured `30`.

  **The default stays `5_000`, unmoved by this change, on purpose.** `@default_shard_spacing_ms`
  predates this option and is carried over from the reference fix this package replaced —
  inherited, not derived, the same way `@pairs_per_socket` (100) is. Against the
  documented 8-connections-per-second-per-IP floor above, `5_000`ms is roughly forty
  times more conservative than the venue's own stated rate requires, which is worth
  saying plainly: it is very likely safe to tighten. It is not tightened here. This task
  was to make the value injectable for a test, and to leave production behaviour alone
  while doing it — retuning a constant nobody has yet deliberately measured a better
  value for, inside a change whose stated purpose is test speed, is exactly the kind of
  drive-by this family's own `FrameSender` moduledoc already warns against for a
  different constant ("that is a decision for the design doc, with reasoning, not a
  drive-by here"). See `docs/design/ideas/shard-spacing-headroom.md` for this observation
  recorded as a non-blocking discovery, not acted on.

  ## The venue rewrites an aliased product id on delivery, and that has to be undone HERE

  **Measured live, 2026-09-05**, against `wss://advanced-trade-ws.coinbase.com`:
  subscribing `ticker` to `["XLM-USDC", "AVAX-USDC"]` — sent exactly as asked, both real,
  listed products — delivers every frame tagged `XLM-USD` and `AVAX-USD`. The venue's own
  subscription acknowledgement even echoes the rewritten names back
  (`"ticker" => ["XLM-USD", "AVAX-USD"]`), not the ones actually sent. This is the venue's
  own declared behaviour, not a guess: `Rest.get_alias_map/1` reads the same public
  `/market/products` catalogue this module already reaches through `Rest.get_symbols/1`
  and `Rest.list_instruments/1`, and on this date 112 of the first 114 USDC products
  carried a non-empty `alias` naming their `-USD` counterpart. A caller subscribed under
  the alias form received nothing under the name it asked for while a name it never asked
  for arrived instead — measured against a real 406-symbol consumer scope
  (DpCryptoManagement's issue #22): 174 of 406 *requested* pairs delivered nothing, while
  401 pairs *never requested* were decoded and stored.

  ### Attribution lives here, not in `Socket`

  `Socket` stays venue-mechanics-only: it decodes a frame and delivers a struct tagged
  with whatever `product_id` the venue actually sent, exactly as it did before this fix.
  Every consumer-facing rewrite happens in this module's `handle_info({:dp_exchange,
  :coinbase, payload}, state)`, immediately before a delivered payload is recorded as
  coverage and fanned out — because this is the one place that already holds `wanted`
  (what the caller actually asked for) beside the delivered payload. Duplicating `wanted`
  into `Socket` just to make the same decision twice would be a second place for the two
  to disagree. `Socket` holds no book to key by anything — see its own moduledoc — so
  this holds regardless of which channel delivered the frame (`ticker` via
  `deliver_ticker/3`, or `level2` via `Socket`'s `deliver_snapshot/4`/`deliver_delta/4`)
  since all three arrive here as the same `{:dp_exchange, :coinbase, payload}` shape and
  every struct `Socket` sends carries `:symbol`.

  ### Built once, from the venue's own catalogue, never from string-munging

  `Rest.get_alias_map/1` is the only source for this map — reusing the same
  `/market/products` fetch `get_symbols/1` and `list_instruments/1` already make, per the
  standing rule against a second way to ask. Munging `-USDC` into `-USD` would be exactly
  the "nearby substitute" this family forbids, and would be wrong for any pair the venue
  does not alias — nothing here assumes the suffix relationship holds in general.

  It is scheduled **once**, asynchronously, the first time `subscribe/3` or
  `update_symbols/2` is called (`maybe_schedule_alias_map_fetch/1`, gated on
  `alias_map_status: :unfetched` so a second call never re-schedules it) — not from
  `init/1`, so a `Feed` that is merely supervised and never asked to stream anything never
  makes a network call, and not synchronously inside the triggering `handle_call/3`, so it
  never competes with `@call_timeout`'s socket-connect budget. Until it resolves,
  `state.alias_map` is simply `%{}` — indistinguishable, by design, from "the venue
  aliases nothing here", which resolves to the same safe fallback below.

  ### The fetch has to wait, not fail — DpCryptoManagement's issue #26

  `Rest.get_alias_map/1` reached `Core.HttpClient` without `rate_limit_blocking: true`,
  so it went through fail-fast `check/3` rather than blocking `acquire/3` — and this fetch
  is scheduled off the first `subscribe/3`, which for any real consumer **is** boot, the
  single most contended moment for their own rate limiter (universe discovery, catalogue
  reads and market overviews all landing at once). It is scheduled into exactly the window
  most likely to throttle it. One throttled call at that moment, on code that never
  retried (see below, before this fix), disabled attribution for the life of the process.
  Measured live: 406 pairs requested as `-USDC`, delivered as `-USD`, overlap 5 —
  `coverage_by_kind/1` and the consumer's own tracker each reporting a truthful, and
  wildly different, count.

  This is the third instance of one family-wide pattern — `dp_exchange_robinhood`'s issue
  #16, this package's own issue #23 sweep (which fixed every other REST call site in this
  package and missed this one, because the alias-map fetch did not exist to audit when
  that comment was written), and now this: a background call with nothing waiting on it,
  failing instead of waiting, while `Core.HttpClient`'s own error message names the fix in
  its text ("callers that can wait should set `rate_limit_blocking: true`"). This call
  site is exactly the caller that can: it runs off `Process.send_after`, nothing blocks on
  its result, and its only job is to populate a cache before frames arrive. Waiting a
  second here is free; failing is total. `rate_limit_blocking: true` is now set
  unconditionally by `default_alias_map_source/2`, which also forwards `:limiter`,
  `:plug`, `:timeout`, `:retry_attempts`, `:retry_delay` and `:weight` from this module's
  own `opts` — the same allowlist shape `Rest`'s own request pipeline uses — so a test can
  exercise the real fetch pipeline end-to-end (a fake `:plug` response behind a real,
  deterministic `:limiter`) rather than only ever exercising the `alias_map_source`
  injection seam.

  ### Classified and retried, the same way a channel subscribe already is

  Blocking removes the *self*-throttle as a failure mode, but does not remove every
  failure: the limiter's own bounded wait can still time out
  (`{:exchange_error, _venue, :rate_limit_timeout}` — the wait itself ran out, not a
  refusal), and the fetch can still fail for reasons no amount of waiting fixes.
  `transient_alias_map_failure?/1` classifies it exactly the way
  `transient_subscribe_failure?/1` classifies a channel subscribe, and for the same
  reason: not every failure can be fixed by retrying, so retrying one that can't only
  delays an honest "this failed" and spends a retry budget a genuinely transient failure
  needs.

  A timed-out wait for the caller's own rate limiter is the one case treated as
  transient — the identical request can reasonably succeed once the limiter's bucket has
  drained further, which is the whole reason `rate_limit_blocking: true` exists here.
  Everything else — an unrecognised response shape, a refused request, a raw or
  unclassified reason (including whatever a test's own stand-in returns) — is treated as
  permanent, matching `transient_subscribe_failure?/1`'s own default-to-permanent stance
  for anything not explicitly known to clear on its own. Retries are bounded
  (`@max_alias_map_retries`, backed off by `@alias_map_retry_delay_ms` — both overridable
  via opts for a test's benefit, the same shape as `subscribe_retry_delay_ms` above)
  rather than looped forever, so a fetch that genuinely cannot succeed still gives up and
  reports itself rather than retrying silently without end.

  Exhausting the retries, or failing permanently on the first attempt, both leave
  `state.alias_map` at `%{}` and `alias_map_status: :unavailable` — the same safe
  fallback as before this fix, just reached only after a transient failure has been given
  its fair chance to clear.

  ### A failed fetch reports itself — and a late notice subscriber has to be able to hear it

  A failed fetch reports itself, as a `:data_quality` notice to `notice_subscribers` —
  "attribution is degraded and here is why" — never a silently guessed mapping.
  `attribution_targets/2` is the single fallback for every case where no wanted name
  resolves — unfetched, failed, legitimately alias-free, or a frame arriving for a symbol
  outside `wanted` altogether (in-flight just after an unsubscribe, or a raw test
  `send/2`): deliver under whatever the venue actually sent, exactly the pre-fix
  behaviour, rather than inventing a name.

  **The notice used to be unreceivable by construction — also DpCryptoManagement's issue
  #26.** The fetch is scheduled from `subscribe/3`; a consumer that calls
  `subscribe_notices/1` afterward — the ordinary sequence, since notices are naturally the
  second thing a caller registers once it already knows it wants data — could register
  only after the fetch had already failed and fanned out to zero subscribers. A notice
  announcing a *persistent* degraded state that can only ever fire in the one window
  before anyone could be listening for it is worse than no signal: it looks like a
  working alarm that never rings.

  Fixed by replay, not by moving the emission earlier — narrowing the window does not
  close it, and this file already learned that lesson once with
  `next_resubscribe_delay/1`'s per-tick storm. `state.alias_map_status` and the reason
  that produced it (`state.alias_map_failure_reason`) already persist for as long as the
  condition holds, so `{:subscribe_notices, subscriber}` replays the identical notice to
  that one newly-registered subscriber whenever it finds the state already `:unavailable`
  — once per registration, never on a timer, and never re-sent to a subscriber who
  already has it, so it cannot become the per-tick storm `next_resubscribe_delay/1` was
  already fixed for once. A consumer that registers before the fetch resolves sees the
  ordinary fan-out, exactly as before; one that registers after sees the same notice,
  late but not lost.

  ### Both caller-facing names, when both are wanted

  The venue treats `XLM-USDC` and `XLM-USD` as one market. If a caller subscribes to
  both, both are entitled to every update — `attribution_targets/2` resolves a delivered
  id to *every* name in `wanted` that names the same market (its own id and, where the
  catalogue says so, its alias), and the delivery loop sends one copy per resolved name.
  This holds regardless of whether the venue itself echoes one frame or two per update for
  a dual subscription — resolution runs per delivered frame against the full candidate
  set, so two frames naming the same pair of wanted symbols do not double-deliver into a
  name twice per market update; they each resolve to the same one-or-both names again.

  ### `coverage/1` needed no code change to become honest

  Coverage was already *whatever key `delivering` holds* — see the moduledoc up top. Once
  delivery is recorded under the caller's own requested name instead of the venue's
  rewritten one, `coverage/1` reports exactly what was asked for, by construction, with
  nothing endpoint-specific added at the `coverage/1` call site itself.

  ### `coverage_by_kind/1` — the same fact, split by what actually arrived

  `coverage/1` answers "is anything arriving for this symbol", and it answers that
  question truthfully — but it asks nothing about *which* kind of payload showed up.
  `Types.Quote`, `Types.OrderBook` and `Types.OrderBookDelta` all carry `:symbol`, so a
  `level2` book update (whether a full snapshot or an incremental delta) and a `ticker`
  quote count identically toward `delivering`, and a symbol with one of the two dark
  looks exactly like a symbol with both healthy.

  That is not a hypothetical: `level2` on this venue delivered upward of 11,000 frames
  across 406 subscribed symbols while `ticker` stayed dark on all but a handful of them,
  and `coverage/1` still answered `:stream` for all 406 — correctly, by its own definition,
  and useless for telling anyone that quotes had gone silent. Two separate
  DpCryptoManagement issues (#20 and #22) sat unpinned for days because nothing in this
  package's own observability could distinguish "everything is fine" from "the book is
  fine and the ticker is dead". `coverage_by_kind/1` exists to make that distinction
  answerable without adding a second, differently-shaped API: it reports the same
  observed-arrival fact `coverage/1` reports, just partitioned by
  `t:DpExchange.Core.Capabilities.data_kind/0` instead of collapsed across it.

  The kind is read off the payload's own struct — `%Types.Quote{}` is `:quotes`,
  `%Types.OrderBook{}` and `%Types.OrderBookDelta{}` are both `:order_book` — never off a
  channel name. Snapshot and delta share one kind deliberately: this question is "is
  book data arriving", not "in what shape", and the struct type itself already tells a
  caller which shape it is holding. `level2` and `ticker` are this venue's words for its
  own wire protocol and stop existing the moment a frame becomes a `Core.Types.*` struct;
  `coverage_by_kind/1` never sees them and could not leak them if it wanted to.

  `state.delivering` therefore keys each symbol to a small map of `kind => timestamp`
  rather than a single timestamp, so a symbol that has delivered both a quote and a book
  update carries both kinds at once, and one going dark does not erase the other.
  `coverage_by_kind/1` folds that structure the other way — kind first, then symbol — to
  match the shape `c:DpExchange.Core.Venue.coverage_by_kind/1` promises.
  """

  use GenServer

  alias DpExchange.Coinbase.{Rest, Socket}
  alias DpExchange.Core.{Capabilities, Notice, Types}

  require Logger

  # `ticker`'s own shard size — see the moduledoc: measured on the venue this package
  # replaces, not on this one. `level2` no longer shares it; see
  # `@level2_pairs_per_socket` below and the moduledoc's "`level2` gets its own, smaller
  # sockets" section.
  @pairs_per_socket 100

  # `level2`'s own DEFAULT shard size — deliberately NOT `@pairs_per_socket`. Not read
  # from documentation: no Coinbase document states a per-session `level2` product ceiling
  # (re-checked 2026-09-06), and this repo cannot probe an authenticated channel live to
  # find one itself (see the moduledoc). `30` is a live bisection DpCryptoManagement ran
  # against the real venue with real credentials — tier 3, structurally unavailable to
  # this repo — on 2026-09-06 (issue #22): 6/12/25/30 accepted, 31/35/50/100 refused,
  # boundary confirmed by interleaving and by a contamination check. See the moduledoc's
  # "why 30" section for the method and the "cumulative vs. concurrent" section for what
  # this number does and does not prove about a long-lived socket's own history.
  #
  # Overridable via `:level2_pairs_per_socket` — see the moduledoc's own section on that
  # option for why a hardcoded venue fact needed to become a supervision knob, what
  # validation applies, and why the default here is not shrunk for headroom. The same
  # "diagnostic knob, real default" shape as `@default_resubscribe_interval_ms` below,
  # just validated at start where that one is not, because a nonsense value here (`0`, a
  # float, a negative number) cannot chunk anything at all rather than merely picking an
  # unwise cadence.
  @default_level2_pairs_per_socket 30

  # Between opening each new socket, whichever channel it will carry. Opening several
  # connections in the same instant is a connect burst the venue answers with resets.
  #
  # `5_000` is inherited from the reference fix this package replaced, the same way
  # `@pairs_per_socket` (100) is — carried over, not derived from anything measured
  # against this venue. See the moduledoc's "`shard_spacing_ms` — a supervision option"
  # section for the one number this package DOES have on the record for connect pacing
  # (Coinbase's own documented 8 connections/second/IP) and why the default is left alone
  # here rather than tightened to it.
  #
  # Overridable via `:shard_spacing_ms`, the same shape as `:resubscribe_interval_ms` and
  # `:level2_pairs_per_socket` — see `validate_shard_spacing_ms!/1` and the moduledoc's own
  # section for the validation this one carries.
  @default_shard_spacing_ms 5_000

  # Coinbase's own Advanced Trade rate-limits page: "WebSocket connections ... are ...
  # limited to 8 per second per IP" — re-read 2026-09-06 alongside the `level2` ceiling
  # investigation above, the same pass that produced `@default_level2_pairs_per_socket`.
  # This package opens one new connection per `@default_shard_spacing_ms` tick, so 8/sec
  # translates directly into a floor on that spacing: `ceil(1_000 / 8)` = `125`ms. Below
  # that, THIS package's own connects alone could exceed the documented per-IP ceiling,
  # independent of whatever else shares the IP. See `validate_shard_spacing_ms!/1` — this
  # is a documented venue fact, not a measured one like `30` above, so it earns a
  # comparison and a warning rather than the outright refusal a mathematically nonsense
  # value gets.
  @shard_spacing_floor_ms 125

  # How long to wait before retrying a subscribe that timed out — see the moduledoc's "a
  # timed-out subscribe used to be thrown away" section. At the time this was chosen it was
  # borrowed from `@channel_spacing_ms`, the wait between two channels sharing one socket;
  # that constant is gone now that no socket carries two channels (see "`level2` gets its
  # own, smaller sockets" in the moduledoc), so this stands on its own reasoning: a socket
  # can still be busy decoding its own just-subscribed burst, and the identical request can
  # reasonably succeed once that clears. The value is unchanged.
  #
  # Overridable via `:subscribe_retry_delay_ms`, for the same reason
  # `:resubscribe_interval_ms` is: a test proving a retry actually happens and succeeds
  # must not wait out the real, multi-second production delay to do it.
  @subscribe_retry_delay_ms 8_000

  # One initial attempt plus this many retries. Bounded deliberately — see "not every
  # failure can be fixed by waiting" in the moduledoc. Shared between a plain channel
  # subscribe and a reconcile's two phases (unsubscribe, then subscribe — see
  # `attempt_channel_reconcile/6` and the moduledoc's "unsubscribe before subscribe"
  # section), rather than each phase inventing its own bound for the identical
  # underlying wait.
  #
  # The whole retry chain for one channel subscribe must finish well inside a resubscribe
  # cycle, or its tail would stack fresh frames onto a socket the next unconditional
  # re-issue is about to hit again (see `next_resubscribe_delay/1`). Worst case for a
  # PLAIN subscribe: `@max_subscribe_retries * @subscribe_retry_delay_ms` = 16_000ms. A
  # reconcile that both loses and gains symbols can pay this twice in sequence — the
  # unsubscribe phase exhausting its own retries before the subscribe phase even starts
  # its first attempt — for a worst case of 32_000ms. Both are comfortably inside the 60s
  # default and inside any interval `next_resubscribe_delay/1` computes (which only ever
  # extends the interval, never shortens it). No per-shard channel offset to add any more:
  # each socket carries exactly one channel now, so there is no "second channel on this
  # socket" delay to stack on top.
  @max_subscribe_retries 2

  # Backoff for a retried alias-map fetch — see the moduledoc's "the fetch has to wait,
  # not fail" and "classified and retried" sections (DpCryptoManagement's issue #26). Not
  # borrowed from `@subscribe_retry_delay_ms`: that number waits out a busy WebSocket
  # decoding a snapshot burst, an unrelated condition to this REST fetch's own rate
  # limiter draining its bucket, so reusing it would be the same "second, independently
  # guessed number for the same wait" mistake in reverse — a number that happens to be
  # borrowed FROM the wrong condition rather than invented for the right one. Two seconds
  # is long enough for a boot-time contention spike to ease without stalling attribution
  # noticeably longer than the blocking wait itself already costs.
  #
  # Overridable via `:alias_map_retry_delay_ms`, the same shape as
  # `:subscribe_retry_delay_ms`: a test proving a retry actually happens and succeeds must
  # not wait out the real, multi-second production delay to do it.
  @alias_map_retry_delay_ms 2_000

  # One initial attempt plus this many retries — the same bound and the same reasoning as
  # `@max_subscribe_retries`: not every failure can be fixed by waiting, so retrying stays
  # finite rather than open-ended. Nothing here competes with a resubscribe cycle the way
  # the channel-subscribe retry chain does, since this fetch runs once at boot rather than
  # on every re-issue tick, so there is no shared-budget arithmetic to repeat.
  @max_alias_map_retries 2

  # Re-issue every shard's current subscriptions on this cadence, unconditionally — see
  # the moduledoc on reconnects.
  #
  # Overridable via `:resubscribe_interval_ms`, and the reason is diagnostic rather than
  # cosmetic. Because this re-issue is unconditional, the package sends a `level2`
  # subscribe per shard per interval indefinitely, and `FrameSender`'s moduledoc leans on
  # the assumption that "subscribes are idempotent on every venue in this family, so a
  # duplicate is harmless". If a venue counted *attempted* L2 stream requests per session
  # rather than established streams, that assumption would be false here and this timer
  # would be feeding the counter — the open question in DpCryptoManagement's issue #22,
  # STILL open after the `6` -> `30` bisection: that bisection used a fresh socket per
  # attempt specifically to keep this question out of its own result (see the moduledoc's
  # "cumulative vs. concurrent" section) and answers only the concurrent ceiling, not
  # whether repeated identical resubscribes on ONE socket ever count against anything.
  # Settling it needs a short interval against a symbol count too small to exhaust any
  # plausible stream limit, which is not something a consumer could arrange while this was
  # a hardcoded constant.
  @default_resubscribe_interval_ms 60_000

  # WebSockex's own send window, which is not configurable.
  @frame_window_ms 5_000

  # Derived from the most frames one call can send, not guessed.
  #
  # `WebSockex.send_frame/2` blocks for up to `@frame_window_ms` before the guard can
  # turn its exit into a return, and that wait happens inside `handle_call/3`. With
  # `GenServer.call`'s five-second default the two race, and the caller times out first —
  # so a slow socket surfaces as a caller-side exit instead of the
  # `{:error, :send_timeout}` the guard exists to produce, losing the one piece of
  # information that says "retry the batch" rather than "the venue is gone".
  #
  # `update_symbols/2` is the worst case: it can send an unsubscribe *and* a subscribe
  # on each of a symbol's affected shards, so a single call can wait out several windows.
  @call_timeout @frame_window_ms * 3

  @doc """
  The scope split into one list per `ticker` socket. `level2` is chunked separately, at
  its own, smaller and independently configurable size — see the moduledoc's "`level2`
  gets its own, smaller sockets" and "`level2_pairs_per_socket` — a supervision option"
  sections — and has no public function of its own, the same way it has no public
  visibility anywhere else in this module.
  """
  @spec shards([String.t()]) :: [[String.t()]]
  def shards([]), do: []
  def shards(symbols), do: Enum.chunk_every(symbols, @pairs_per_socket)

  # `level2`'s own grouping — never exposed, for the same reason `shards/1` documents
  # itself as `ticker`-only above: this module's whole point is that a consumer cannot
  # tell how data arrives, and per-channel shard sizes are exactly that. `size` is
  # `state.level2_pairs_per_socket` at every call site — the caller-supplied or default
  # value, already validated in `init/1`.
  defp level2_shards([], _size), do: []
  defp level2_shards(symbols, size), do: Enum.chunk_every(symbols, size)

  # Which channels this feed carries at all, given whether it has credentials — see
  # `Socket`'s `@authenticated_channels`. A credential-less caller only ever wanted the
  # public `ticker` channel; sending a doomed `level2` subscribe would either report a
  # `credentials_required` error as a call's synchronous result (masking that `ticker`
  # works fine) or cost a wire round trip to learn what the credential's absence already
  # answers.
  defp active_channels(nil), do: ["ticker"]
  defp active_channels(_credentials), do: ["ticker", "level2"]

  # Each channel's own grouping, at its own size — see `shards/1` and `level2_shards/2`.
  # `level2_pairs_per_socket` is unused for `ticker`, which has no per-channel size of
  # its own to read from state (see the moduledoc's "ticker gets no equivalent option"
  # paragraph).
  defp shards_for(symbols, "ticker", _level2_pairs_per_socket), do: shards(symbols)

  defp shards_for(symbols, "level2", level2_pairs_per_socket),
    do: level2_shards(symbols, level2_pairs_per_socket)

  # `ticker` sorts ahead of `level2` wherever shard keys are ordered, so a call touching
  # both keeps its synchronous reply — and the front of any stagger sequence — on `ticker`,
  # preserving that channel's boot-time coverage exactly as before `level2` got its own,
  # far more numerous shards. See the moduledoc's "connects are staggered across both
  # groups on one sequence" section.
  defp channel_priority("ticker"), do: 0
  defp channel_priority("level2"), do: 1

  defp shard_key_order({channel_a, index_a}, {channel_b, index_b}) do
    {channel_priority(channel_a), index_a} <= {channel_priority(channel_b), index_b}
  end

  # See the moduledoc's "`level2_pairs_per_socket` — a supervision option" section for
  # the full reasoning; this is only the mechanism.
  #
  # Below `1` (or not an integer at all) is unconditionally nonsense — `Enum.chunk_every/2`
  # cannot chunk anything to it — and is refused here, in `init/1`, rather than coerced
  # into some nearby "safe" value: this family fails closed rather than substitutes.
  # Raising here fails `GenServer.start_link/3` (and therefore `Feed.start_link/1` and
  # `Supervisor.start_link/1`) synchronously with the exception, so a consumer sees why
  # its own tree would not start rather than a `Feed` silently running with a value that
  # could never have shaped a shard.
  #
  # A value ABOVE the measured `30` is deliberately NOT refused — capping it would defeat
  # the option's own purpose (absorbing a venue-side change without a package release),
  # and this repo has no way to verify whether such a change happened (see "why 30" in the
  # moduledoc). It is instead honoured with a loud warning naming the measured ceiling,
  # its date and source, and the concrete risk: an oversized `level2` subscribe is refused
  # by the venue WHOLESALE — not truncated to the first 30 — losing that whole shard's
  # coverage. The socket itself survives (measured 2026-09-07, see the moduledoc's own
  # "concrete risk" section), which makes this quieter than a disconnect, not louder: no
  # link-down, no reconnect, just a shard that silently never delivers.
  defp validate_level2_pairs_per_socket!(value) when is_integer(value) and value >= 1 do
    if value > @default_level2_pairs_per_socket do
      Logger.warning(
        "[Coinbase Feed] level2_pairs_per_socket #{value} is above the measured venue " <>
          "ceiling of #{@default_level2_pairs_per_socket} (DpCryptoManagement, issue #22, " <>
          "measured 2026-09-06 against the live venue with real credentials — see this " <>
          "module's own moduledoc, \"why 30\"). This value is honoured anyway: absorbing " <>
          "a venue-side change without a package release is the reason this option " <>
          "exists, and this package cannot verify whether the venue's ceiling has moved. " <>
          "But if it has not, every ordinary level2 subscribe at this size is a single " <>
          "subscribe over the venue's real limit, which DpCryptoManagement measured " <>
          "directly (2026-09-07, issue #22 continuing): the refusal is WHOLESALE, not " <>
          "truncated — the whole shard delivers nothing — and the socket SURVIVES, no " <>
          "disconnect, reported only as a `:rate_limited` Core.Notice. That is quieter " <>
          "than the 2026-08-26 incident this option's warning used to describe (a " <>
          "disconnect at least announces itself); a live socket delivering nothing does " <>
          "not. Watch `coverage/1` or `coverage_by_kind/1` for this shard, not liveness."
      )
    end

    value
  end

  defp validate_level2_pairs_per_socket!(value) do
    raise ArgumentError,
          "level2_pairs_per_socket must be a positive integer, got: #{inspect(value)}"
  end

  # See the moduledoc's "`shard_spacing_ms` — a supervision option" section.
  #
  # Below `0`, or not an integer at all, is unconditionally nonsense: `Process.send_after/3`
  # takes a non-negative integer delay, so a negative or fractional value could never have
  # scheduled anything. Refused here, in `init/1`, the same way an unusable
  # `level2_pairs_per_socket` is — this family fails closed rather than substitutes. `0`
  # itself is NOT refused: it is a real, if extreme, choice (every shard opens in the same
  # instant) and `Process.send_after/3` accepts it without complaint, so there is nothing
  # mathematically broken about it the way there is about a negative delay.
  #
  # A value below the documented `@shard_spacing_floor_ms` (125 — Coinbase's own 8
  # connections/second/IP, see that constant's comment) is honoured, not refused, the same
  # shape as `level2_pairs_per_socket` above the measured `30`: this package cannot verify
  # whether a consumer's own network position makes a faster pace safe for them (a
  # dedicated IP with headroom this repo has no visibility into, say), so it does not get
  # to assume the conservative answer is the only correct one. What it gets instead is a
  # loud `Logger.warning` naming the documented floor, its source, and the concrete risk:
  # connects tighter than the venue's own stated per-IP rate risk exactly the connect-burst
  # resets this module's own moduledoc opens with.
  defp validate_shard_spacing_ms!(value) when is_integer(value) and value >= 0 do
    if value < @shard_spacing_floor_ms do
      Logger.warning(
        "[Coinbase Feed] shard_spacing_ms #{value} is below the documented connect-rate " <>
          "floor of #{@shard_spacing_floor_ms}ms, derived from Coinbase's own Advanced " <>
          "Trade rate-limits page (\"WebSocket connections ... are ... limited to 8 per " <>
          "second per IP\", re-read 2026-09-06). This value is honoured anyway: this " <>
          "package cannot verify whether a faster pace is safe for your own network " <>
          "position. But every new socket this feed opens ticks at this spacing, so a " <>
          "scope wide enough to need several shards will now open connections faster " <>
          "than the venue's own documented per-IP rate allows, risking the connect-burst " <>
          "resets this module's own moduledoc describes."
      )
    end

    value
  end

  defp validate_shard_spacing_ms!(value) do
    raise ArgumentError,
          "shard_spacing_ms must be a non-negative integer, got: #{inspect(value)}"
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec subscribe(GenServer.server(), [String.t()], keyword()) :: :ok | {:error, term()}
  def subscribe(feed \\ __MODULE__, symbols, opts \\ []) do
    GenServer.call(feed, {:subscribe, symbols, Keyword.get(opts, :to, self())}, @call_timeout)
  end

  @spec unsubscribe(GenServer.server(), [String.t()]) :: :ok | {:error, term()}
  def unsubscribe(feed \\ __MODULE__, symbols),
    do: GenServer.call(feed, {:unsubscribe, symbols}, @call_timeout)

  @spec update_symbols(GenServer.server(), [String.t()]) :: :ok | {:error, term()}
  def update_symbols(feed \\ __MODULE__, symbols),
    do: GenServer.call(feed, {:update_symbols, symbols}, @call_timeout)

  @spec coverage(GenServer.server()) :: %{String.t() => :stream | :internal_poll | :not_covered}
  def coverage(feed \\ __MODULE__), do: GenServer.call(feed, :coverage)

  @doc """
  `coverage/1`, split by which `Core.Types.*` kind actually arrived — see the moduledoc's
  "coverage_by_kind/1" section for why `coverage/1` alone could not tell "ticker dark,
  book healthy" apart from "everything healthy".
  """
  @spec coverage_by_kind(GenServer.server()) :: %{
          Capabilities.data_kind() => %{String.t() => :stream | :internal_poll | :not_covered}
        }
  def coverage_by_kind(feed \\ __MODULE__), do: GenServer.call(feed, :coverage_by_kind)

  @spec subscribe_notices(GenServer.server(), keyword()) :: :ok
  def subscribe_notices(feed \\ __MODULE__, opts \\ []),
    do: GenServer.call(feed, {:subscribe_notices, Keyword.get(opts, :to, self())})

  # --- server ------------------------------------------------------------

  @impl true
  def init(opts) do
    resubscribe_interval_ms =
      Keyword.get(opts, :resubscribe_interval_ms) || @default_resubscribe_interval_ms

    # See the moduledoc's "`level2_pairs_per_socket` — a supervision option" section.
    # `Keyword.get/2 || default` is the same nil-vs-absent-safe shape
    # `resubscribe_interval_ms` above uses; `validate_level2_pairs_per_socket!/1` is the
    # part that IS new — a value here that cannot chunk anything (not a positive integer)
    # fails `init/1` loudly rather than being coerced or ignored, per this family's "fail
    # closed; never substitute" rule.
    level2_pairs_per_socket =
      (Keyword.get(opts, :level2_pairs_per_socket) || @default_level2_pairs_per_socket)
      |> validate_level2_pairs_per_socket!()

    # See the moduledoc's "`shard_spacing_ms` — a supervision option" section and
    # `validate_shard_spacing_ms!/1`. Same nil-vs-absent-safe `Keyword.get/2 || default`
    # shape as the two options above; validated the same way `level2_pairs_per_socket` is,
    # because a value that cannot schedule anything (negative, non-integer) is exactly as
    # unusable here as one that cannot chunk anything is there.
    shard_spacing_ms =
      (Keyword.get(opts, :shard_spacing_ms) || @default_shard_spacing_ms)
      |> validate_shard_spacing_ms!()

    Process.send_after(self(), :resubscribe, resubscribe_interval_ms)

    credentials = Keyword.get(opts, :credentials)

    # A test injects a fast, hermetic stand-in here — see the moduledoc's alias-map
    # section. Production supplies none, so this default runs: the venue's own public
    # catalogue, reusing `Rest`'s existing products fetch rather than a second way to ask.
    alias_map_source =
      Keyword.get(opts, :alias_map_source, default_alias_map_source(opts, credentials))

    {:ok,
     %{
       credentials: credentials,
       socket_opts: Keyword.take(opts, [:url]),
       # A pre-established connection, consumed the first time any shard opens. Ordinary
       # use leaves this `nil` and the feed dials its own; it is set by tests that need
       # the socket-bearing branches without reaching a venue.
       injected_socket: Keyword.get(opts, :socket),
       # index => %{socket: pid, symbols: [...]}. Populated as shards open; a shard
       # whose socket has not opened yet (still waiting out its `shard_spacing_ms`
       # delay, or the connect failed) is simply absent — its symbols stay on whatever
       # this package's REST poll answers until the socket comes up.
       shards: %{},
       # {channel, index} => [symbol, ...] — departing symbols whose unsubscribe could
       # not be confirmed sent, believed still live on the venue. See the moduledoc's "a
       # stranded unsubscribe is not silently forgotten" section: written by
       # `strand_unsubscribe/7` when a reconcile gives up on releasing them, read and
       # retried by `handle_info(:resubscribe, _)` on the same unconditional cadence
       # `retry_missing_shards/1` already uses for a shard that never got a socket at
       # all, and cleared (per symbol) the moment a retry actually sends. Absent from a
       # key entirely is the ordinary case — this map is normally empty.
       pending_unsubscribes: %{},
       subscribers: MapSet.new(),
       notice_subscribers: MapSet.new(),
       wanted: MapSet.new(),
       # symbol => %{kind => timestamp_ms}, one entry per `Capabilities.data_kind()` that
       # has actually delivered for that symbol — see the moduledoc's "coverage_by_kind/1"
       # section. `coverage/1` only needs "does this symbol have any entry at all";
       # `coverage_by_kind/1` needs the kinds themselves, which is why this is a nested
       # map rather than the bare timestamp it used to be.
       delivering: %{},
       resubscribe_interval_ms: resubscribe_interval_ms,
       # See `@default_level2_pairs_per_socket` and the moduledoc's own section on this
       # option. Read once, here, already validated — `level2_shards/2` (via
       # `shards_for/3`) takes this as a plain argument rather than reaching back into
       # `@default_level2_pairs_per_socket` itself, so every shard this process ever
       # computes uses the value it started with, not a constant that ignores what the
       # caller asked for.
       level2_pairs_per_socket: level2_pairs_per_socket,
       # See `@default_shard_spacing_ms` and the moduledoc's own section on this option.
       # Read once, here, already validated — every place that used to reach for
       # `@shard_spacing_ms` directly (`reshard/1`, `reconcile_shard_in_place/7`,
       # `handle_info(:resubscribe, _)`, `retry_missing_shards/1`,
       # `next_resubscribe_delay/1`) now reads `state.shard_spacing_ms` instead, so every
       # stagger this process ever schedules uses the value it started with.
       shard_spacing_ms: shard_spacing_ms,
       # See `@subscribe_retry_delay_ms` — the same "diagnostic knob, real default" shape
       # as `resubscribe_interval_ms` above, for a test's benefit rather than a consumer's.
       subscribe_retry_delay_ms:
         Keyword.get(opts, :subscribe_retry_delay_ms) || @subscribe_retry_delay_ms,
       # See `@alias_map_retry_delay_ms` — same shape, same reason: a test proving the
       # alias-map fetch's own retry actually happens must not wait out the real delay.
       alias_map_retry_delay_ms:
         Keyword.get(opts, :alias_map_retry_delay_ms) || @alias_map_retry_delay_ms,
       # The venue's own declared alias relationships — see the moduledoc's "the venue
       # rewrites an aliased product id on delivery" section. `%{}` until fetched (or
       # forever, if every retry is exhausted), which is deliberately indistinguishable
       # from "the venue aliases nothing here": both resolve through the same safe
       # fallback in `attribution_targets/2`.
       alias_map: %{},
       alias_map_status: :unfetched,
       # The reason the fetch last gave up, if it ever did — `nil` while `alias_map_status`
       # is anything but `:unavailable`. Persisted so a notice subscriber that registers
       # after the fact (see `handle_call({:subscribe_notices, _}, _, _)` below and the
       # moduledoc's "a late notice subscriber has to be able to hear it" section) can be
       # replayed the same notice a subscriber present at the time already received.
       alias_map_failure_reason: nil,
       alias_map_source: alias_map_source
     }}
  end

  @impl true
  def handle_call({:subscribe, symbols, subscriber}, _from, state) do
    wanted = MapSet.union(state.wanted, MapSet.new(symbols))

    state =
      %{state | subscribers: MapSet.put(state.subscribers, subscriber), wanted: wanted}
      |> maybe_schedule_alias_map_fetch()

    {result, state} = reshard(state)
    {:reply, result, state}
  end

  def handle_call({:unsubscribe, symbols}, _from, state) do
    wanted = MapSet.difference(state.wanted, MapSet.new(symbols))
    state = %{state | wanted: wanted, delivering: Map.drop(state.delivering, symbols)}
    {result, state} = reshard(state)
    {:reply, result, state}
  end

  def handle_call({:update_symbols, symbols}, _from, state) do
    wanted = MapSet.new(symbols)

    state =
      %{state | wanted: wanted, delivering: Map.take(state.delivering, symbols)}
      |> maybe_schedule_alias_map_fetch()

    {result, state} = reshard(state)
    {:reply, result, state}
  end

  def handle_call(:coverage, _from, state) do
    # Only what arrived. A subscribed symbol that has delivered nothing is absent, and
    # the facade documents absence as `:not_covered`. `state.delivering` values are now
    # `%{kind => timestamp}` rather than a bare timestamp — see `coverage_by_kind/1` — but
    # this reply only ever needs "has this symbol delivered anything at all", so the kind
    # breakdown is irrelevant here and dropped.
    {:reply, Map.new(state.delivering, fn {symbol, _kinds} -> {symbol, :stream} end), state}
  end

  def handle_call(:coverage_by_kind, _from, state) do
    # Inverts `state.delivering` from symbol-first (`%{symbol => %{kind => timestamp}}`)
    # to kind-first (`%{kind => %{symbol => :stream}}`) — the shape
    # `c:DpExchange.Core.Venue.coverage_by_kind/1` promises. A symbol that has delivered
    # both a quote and a book update appears under both kinds; one going dark later drops
    # only that kind's entry, never the other's.
    by_kind =
      Enum.reduce(state.delivering, %{}, fn {symbol, kinds}, acc ->
        Enum.reduce(Map.keys(kinds), acc, fn kind, acc_by_kind ->
          Map.update(acc_by_kind, kind, %{symbol => :stream}, &Map.put(&1, symbol, :stream))
        end)
      end)

    {:reply, by_kind, state}
  end

  def handle_call({:subscribe_notices, subscriber}, _from, state) do
    # Read before the set is updated below: a subscriber calling this a second time is
    # already registered, and must not be replayed the notice again just for asking twice
    # — see the moduledoc's "a late notice subscriber has to be able to hear it" section.
    already_registered? = MapSet.member?(state.notice_subscribers, subscriber)
    state = %{state | notice_subscribers: MapSet.put(state.notice_subscribers, subscriber)}

    # (DpCryptoManagement's issue #26): the degraded-attribution notice fires once, when
    # the fetch first gives up, which is typically *before* a consumer following the
    # ordinary `subscribe/2` then `subscribe_notices/1` sequence has registered at all.
    # Replayed here, to this one newly-registered subscriber only — never to a subscriber
    # already registered, who already has it — and only while the condition still holds,
    # so this cannot become a per-tick notice storm; it fires at most once per NEW
    # registration, an event, not a timer.
    if not already_registered? and state.alias_map_status == :unavailable do
      notify_one(subscriber, degraded_attribution_notice(state.alias_map_failure_reason))
    end

    {:reply, :ok, state}
  end

  def handle_call(_other, _from, state), do: {:reply, {:error, :unknown_call}, state}

  @impl true
  def handle_info({:dp_exchange, :coinbase, %Notice{} = notice}, state) do
    fan_out(state.notice_subscribers, {:dp_exchange, :coinbase, notice})
    {:noreply, state}
  end

  def handle_info({:dp_exchange, :coinbase, payload}, state) do
    # See the moduledoc's alias-map section: `targets` is every name in `wanted` that
    # names the same market as the venue's delivered id — its own name and, where the
    # catalogue says so, its alias — falling back to the delivered id itself when nothing
    # in `wanted` resolves.
    targets = attribution_targets(payload, state)
    kind = payload_kind(payload)
    now = :os.system_time(:millisecond)

    Enum.each(targets, fn symbol ->
      fan_out(state.subscribers, {:dp_exchange, :coinbase, %{payload | symbol: symbol}})
    end)

    delivering =
      Enum.reduce(targets, state.delivering, fn symbol, acc ->
        Map.update(acc, symbol, %{kind => now}, &Map.put(&1, kind, now))
      end)

    {:noreply, %{state | delivering: delivering}}
  end

  def handle_info(:fetch_alias_map, state) do
    attempt_alias_map_fetch(1, state)
  end

  # The retry this module schedules on a transient failure — see the moduledoc's "the
  # fetch has to wait, not fail" and "classified and retried" sections. `attempt` starts
  # at `2` here; the first attempt is always the bare `:fetch_alias_map` clause above,
  # mirroring `handle_info({:channel_subscribe, ...})`'s own two-clause shape.
  def handle_info({:fetch_alias_map, attempt}, state) do
    attempt_alias_map_fetch(attempt, state)
  end

  def handle_info({:open_shard, channel, index, symbols}, state) do
    case get_socket(state) do
      {:ok, socket, state} ->
        state = put_in(state.shards[{channel, index}], %{socket: socket, symbols: symbols})
        attempt_channel_subscribe(socket, channel, symbols, state.credentials, 1, state)

      {:error, reason} ->
        # Never silent: this shard's symbols keep arriving over whatever REST poll runs
        # beside this feed, but at poll cadence rather than stream cadence, and that
        # difference has to be findable rather than inferred from a quiet chart. A
        # `Logger.warning` alone does not make that findable — it never crosses the
        # facade, and a consumer's only facade-level window onto this feed's health is
        # `coverage/1`, `coverage_by_kind/1` and `subscribe_notices/1`. Before this fix
        # this branch logged and nothing else: a shard whose socket never opened at all —
        # the async path every shard past the first (or a resharded existing shard) takes
        # — left its symbols silently absent from coverage with no `Core.Notice` telling a
        # consumer why, the exact "silent half-dead feed" this module's own moduledoc is
        # about. `notify_shard_open_failed/4` closes that gap with the same
        # `:coverage_change` kind `notify_subscribe_failed/5` already uses for a channel
        # that never subscribed — both are "subscribed intent that did not become
        # delivery".
        Logger.warning(
          "[Coinbase Feed] #{channel} shard #{index} did not open (#{inspect(reason)}) — " <>
            "its #{length(symbols)} symbol(s) stay on the internal poll only"
        )

        notify_shard_open_failed(state, channel, index, symbols, reason)
        {:noreply, state}
    end
  end

  def handle_info({:channel_subscribe, socket, channel, symbols, credentials}, state) do
    attempt_channel_subscribe(socket, channel, symbols, credentials, 1, state)
  end

  # The retry this module schedules on a transient failure — see the moduledoc's "a
  # timed-out subscribe used to be thrown away" section. `attempt` starts at `2` here;
  # the first attempt is always the 5-tuple clause above.
  def handle_info({:channel_subscribe, socket, channel, symbols, credentials, attempt}, state) do
    attempt_channel_subscribe(socket, channel, symbols, credentials, attempt, state)
  end

  # `removed` is unsubscribed here before `added` is subscribed — see the moduledoc's
  # "unsubscribe before subscribe" section for why this ONE deferred message, rather than
  # the two independent `Process.send_after/3` calls this replaced, is what makes that
  # order a property of ordinary sequential code instead of two timers firing at the same
  # tick. `attempt_channel_reconcile/7` is the whole implementation; this clause and the
  # one below it only supply the starting attempt number, the same two-clause shape
  # `:channel_subscribe` already uses. `key` travels alongside so a failure that gives up
  # can record `removed` against the right shard in `state.pending_unsubscribes` — see
  # `strand_unsubscribe/7` and the moduledoc's "a stranded unsubscribe is not silently
  # forgotten" section. This same message shape is also what `handle_info(:resubscribe,
  # _)` sends for every shard on its own unconditional cadence — see below — so a shard
  # with nothing pending and one that is retrying a stranded release both flow through
  # the identical code.
  def handle_info({:channel_reconcile, key, socket, channel, removed, added, credentials}, state) do
    attempt_channel_reconcile(key, socket, channel, removed, added, credentials, 1, state)
  end

  # The retry this module schedules when the UNSUBSCRIBE half of a reconcile fails
  # transiently — see `handle_unsubscribe_failure/8`. `attempt` starts at `2` here; the
  # first attempt is always the 6-tuple clause above.
  def handle_info(
        {:channel_reconcile, key, socket, channel, removed, added, credentials, attempt},
        state
      ) do
    attempt_channel_reconcile(key, socket, channel, removed, added, credentials, attempt, state)
  end

  def handle_info(:resubscribe, state) do
    Process.send_after(self(), :resubscribe, next_resubscribe_delay(state))

    # Staggered the same way `reshard/1` staggers opening several new shards: re-issuing
    # every shard's subscribe in the same instant is the identical connect/subscribe
    # burst the moduledoc warns about, just recurring on this cadence instead of once at
    # boot. `ticker` shards sort first — see `shard_key_order/2` — so an already-open
    # `ticker` shard's re-issue is never pushed behind the (likely far more numerous)
    # `level2` shards'.
    #
    # `pending` — this shard's own `state.pending_unsubscribes` entry, `[]` for the
    # ordinary case — travels with it so the eventual reconcile releases anything still
    # stranded BEFORE it re-issues the shard's current symbols, the same ordering
    # guarantee every other reconcile in this module keeps. See the moduledoc's "a
    # stranded unsubscribe is not silently forgotten" section for why this is read here
    # rather than tracked on a separate timer of its own.
    state.shards
    |> Map.keys()
    |> Enum.sort(&shard_key_order/2)
    |> Enum.with_index()
    |> Enum.each(fn {{channel, _index} = key, position} ->
      %{socket: socket, symbols: symbols} = Map.fetch!(state.shards, key)
      pending = Map.get(state.pending_unsubscribes, key, [])

      if Process.alive?(socket) do
        Process.send_after(
          self(),
          {:resubscribe_shard, key, socket, channel, pending, symbols, state.credentials},
          position * state.shard_spacing_ms
        )
      end
    end)

    # A shard that never got a socket in the first place — its async `:open_shard`
    # connect failed or timed out — is absent from `state.shards` entirely, so the walk
    # above never touches it: there is nothing there to resubscribe. Without this, such a
    # shard has NO automatic recovery path at all, ever — `reshard/1` only reconsiders it
    # on the next explicit `subscribe/3`, `unsubscribe/2` or `update_symbols/2` call, which
    # may never come if a consumer's scope is stable. That is a silent, permanent coverage
    # gap indistinguishable from a quiet market, on a venue this coordinator's OWN
    # moduledoc says must never go unretried. Retrying it here, on the same unconditional
    # cadence an already-open shard's subscriptions are re-issued on, closes that gap —
    # staggered past whatever this tick already scheduled for open shards, for the same
    # connect-burst reason `shard_spacing_ms` exists everywhere else in this module.
    retry_missing_shards(state)

    {:noreply, state}
  end

  # Reissues this shard's full current membership through the SAME unsubscribe-before-
  # subscribe machinery an ordinary reconcile uses — `pending` is `removed`, `symbols`
  # (the shard's WHOLE current set, not a delta) is `added`. For the ordinary case
  # (`pending == []`) this is exactly as cheap as the plain `Socket.subscribe/4` it
  # replaces: `unsubscribe_step/3` short-circuits on an empty list without sending
  # anything. For a shard carrying a stranded release, this is what actually retries it —
  # see the moduledoc's "a stranded unsubscribe is not silently forgotten" section.
  def handle_info(
        {:resubscribe_shard, key, socket, channel, pending, symbols, credentials},
        state
      ) do
    if Process.alive?(socket) do
      Process.send_after(
        self(),
        {:channel_reconcile, key, socket, channel, pending, symbols, credentials},
        0
      )
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- internal ------------------------------------------------------------

  # A re-issue cycle is not instantaneous: every shard — `ticker` and `level2` alike, each
  # on its own socket now — is staggered `shard_spacing_ms` apart, so the last frame of a
  # cycle goes out roughly
  #
  #     (shards - 1) * shard_spacing_ms
  #
  # after the tick. If the timer re-fires before that, cycles overlap: frames queue behind
  # each other, `WebSockex.send_frame/2` blows its window, and the `Feed` can stop
  # answering calls entirely while it drains — a wedged feed, which is strictly worse than
  # a late resubscribe.
  #
  # DpCryptoManagement hit this in issue #22 by setting `resubscribe_interval_ms: 5_000`,
  # well below even one shard's own send window, and lost the run to it. But the same
  # failure is reachable with NO option set: the 60s default is shorter than the cycle span
  # from 13 shards upward — reachable from a single `level2` grouping alone once a universe
  # passes 360 symbols (`ceil(360 / 30)` is 12; 361 needs 13), a scope this package now
  # sizes at `@level2_pairs_per_socket` rather than the far larger `@pairs_per_socket` (a
  # 406-symbol universe needs 14 `level2` shards on its own), so a large enough consumer
  # can still walk into this without `ticker` needing any shards of its own at all.
  #
  # The delay is therefore derived from the shard count that actually exists right now,
  # never from the configured value alone, and the extension is logged rather than applied
  # silently — a diagnostic knob whose value is quietly ignored is its own trap.
  defp next_resubscribe_delay(state) do
    shard_count = map_size(state.shards)
    span = max(shard_count - 1, 0) * state.shard_spacing_ms
    floor_ms = span + @frame_window_ms

    if state.resubscribe_interval_ms < floor_ms do
      Logger.warning(
        "[Coinbase Feed] resubscribe interval #{state.resubscribe_interval_ms}ms is shorter " <>
          "than one re-issue cycle across #{shard_count} shard(s) (#{span}ms) — using " <>
          "#{floor_ms}ms instead. Overlapping cycles queue frames behind each other and " <>
          "can stop this feed answering calls."
      )

      floor_ms
    else
      state.resubscribe_interval_ms
    end
  end

  # Re-attempts opening any shard `state.wanted` implies (for either channel) that is not
  # currently a key in `state.shards` — see `handle_info(:resubscribe, _)` for why this
  # exists: a shard whose socket never opened has no other automatic recovery path.
  # Computed the same way `reshard/1` computes `new_shards`, so the keys agree with
  # whatever a fresh `subscribe/3` or `update_symbols/2` call would also compute for the
  # same `wanted` set.
  #
  # Staggered starting one `shard_spacing_ms` past every already-open shard's own
  # resubscribe slot (`map_size(state.shards)` of them, scheduled just above), so a retry
  # here never lands in the same instant as an open shard's unconditional resubscribe.
  defp retry_missing_shards(state) do
    existing = Map.keys(state.shards)
    base = map_size(state.shards)
    wanted_list = MapSet.to_list(state.wanted)

    state.credentials
    |> active_channels()
    |> Enum.flat_map(fn channel ->
      wanted_list
      |> shards_for(channel, state.level2_pairs_per_socket)
      |> Enum.with_index()
      |> Enum.map(fn {symbols, index} -> {{channel, index}, symbols} end)
    end)
    |> Enum.reject(fn {key, _symbols} -> key in existing end)
    |> Enum.sort_by(fn {key, _symbols} -> key end, &shard_key_order/2)
    |> Enum.with_index()
    |> Enum.each(fn {{{channel, index}, symbols}, position} ->
      Process.send_after(
        self(),
        {:open_shard, channel, index, symbols},
        (base + position) * state.shard_spacing_ms
      )
    end)
  end

  # Recomputes each active channel's shards from `state.wanted` and reconciles: a shard
  # whose symbol set changed gets its socket's subscriptions brought current, a brand-new
  # shard gets a socket opened, and a shard that no longer has any symbols is dropped —
  # its socket is left to WebSockex's own lifecycle rather than torn down here, because a
  # shard reappearing moments later (a common `update_symbols` pattern) should not pay to
  # reopen a connection it only just closed.
  #
  # `ticker` and `level2` are chunked independently, at their own sizes — see the
  # moduledoc's "`level2` gets its own, smaller sockets" section — so a shard *key* is now
  # `{channel, index}`, and every key names exactly one socket carrying exactly one
  # channel. Nothing below this line treats `ticker` and `level2` shards any differently
  # from one another; only `shards_for/2` (via `active_channels/1`) knows there are two
  # groupings with two different sizes at all.
  #
  # ## Why exactly one shard is handled synchronously
  #
  # A caller subscribing to ten symbols touches one shard and needs to know, in the
  # reply, whether that connection actually accepted the request — reporting success
  # unconditionally would produce a subscription that never delivers, indistinguishable
  # from a quiet market. A caller whose `update_symbols` spans four hundred symbols
  # touches dozens of shards (`level2`'s own grouping alone, at `@level2_pairs_per_socket`,
  # sees to that), and dialling all of them inline would block the reply behind
  # `shard_spacing_ms` many times over and risk a connect burst besides.
  #
  # So: the FIRST shard this call actually touches — by `shard_key_order/2`, which puts
  # every `ticker` shard ahead of every `level2` shard and orders each channel by index —
  # runs inline and its outcome is the call's reply, same as the single-socket design this
  # replaces. Every other shard the same call touches is staggered, exactly as a shard
  # opened by a later, separate call would be.
  defp reshard(state) do
    wanted_list = MapSet.to_list(state.wanted)

    new_shards =
      state.credentials
      |> active_channels()
      |> Enum.flat_map(fn channel ->
        wanted_list
        |> shards_for(channel, state.level2_pairs_per_socket)
        |> Enum.with_index()
        |> Enum.map(fn {symbols, index} -> {{channel, index}, symbols} end)
      end)
      |> Map.new()

    existing_keys = Map.keys(state.shards)
    wanted_keys = Map.keys(new_shards)
    new_keys = wanted_keys -- existing_keys

    # A shard whose whole symbol set was just removed disappears from `new_shards`
    # entirely — nothing above asked for any of its symbols any more. That must still
    # reach the venue as an unsubscribe on every symbol the shard was carrying, or the
    # venue keeps streaming them while this package's own bookkeeping has already
    # forgotten it asked to. Folded into `new_shards` as an explicit empty entry so
    # `reconcile_shard/7`'s ordinary removed-symbols path handles it — the same
    # operation, not a special case.
    vanishing_keys = existing_keys -- wanted_keys
    new_shards = Enum.reduce(vanishing_keys, new_shards, &Map.put(&2, &1, []))

    touched_keys =
      (wanted_keys ++ vanishing_keys)
      |> Enum.filter(fn key ->
        key in new_keys or shard_changed?(state, key, new_shards)
      end)
      |> Enum.sort(&shard_key_order/2)

    case touched_keys do
      [] ->
        state = drop_unwanted_shards(state, existing_keys, wanted_keys)
        {:ok, state}

      [primary | rest] ->
        {result, state} = touch_shard(state, primary, new_shards, sync: true, delay: 0)

        state =
          rest
          |> Enum.with_index(1)
          |> Enum.reduce(state, fn {key, position}, acc ->
            {_result, acc} =
              touch_shard(acc, key, new_shards,
                sync: false,
                delay: position * state.shard_spacing_ms
              )

            acc
          end)

        state = drop_unwanted_shards(state, existing_keys, wanted_keys)
        {result, state}
    end
  end

  defp shard_changed?(state, key, new_shards) do
    case get_in(state.shards[key]) do
      nil -> false
      %{symbols: current} -> current != Map.fetch!(new_shards, key)
    end
  end

  # Also drops any `pending_unsubscribes` entry for a shard that no longer exists — see
  # the moduledoc's "a stranded unsubscribe is not silently forgotten" section for why
  # this map could otherwise accumulate orphaned entries for shards `state.shards` has
  # already forgotten: nothing walks a key that is not in `state.shards` (the
  # `handle_info(:resubscribe, _)` walk below is keyed off `Map.keys(state.shards)`
  # specifically), so a dropped shard's own stranding would otherwise sit here forever,
  # retried by nothing. A dropped shard's socket is left running unmanaged either way
  # (see `reshard/1`'s own comment on why it is not torn down here) — this only stops
  # this module's own bookkeeping about it from growing without bound.
  defp drop_unwanted_shards(state, existing_keys, wanted_keys) do
    dropped_keys = existing_keys -- wanted_keys

    %{
      state
      | shards: Map.drop(state.shards, dropped_keys),
        pending_unsubscribes: Map.drop(state.pending_unsubscribes, dropped_keys)
    }
  end

  defp touch_shard(state, key, new_shards, sync: sync?, delay: delay) do
    {channel, _index} = key
    wanted_symbols = Map.fetch!(new_shards, key)

    case get_in(state.shards[key]) do
      nil ->
        open_shard(state, key, wanted_symbols, sync?, delay)

      %{symbols: current, socket: socket} ->
        reconcile_shard_in_place(
          state,
          key,
          channel,
          socket,
          current,
          wanted_symbols,
          sync?,
          delay
        )
    end
  end

  defp open_shard(state, {channel, _index} = key, symbols, true, _delay) do
    case get_socket(state) do
      {:ok, socket, state} ->
        state = put_in(state.shards[key], %{socket: socket, symbols: symbols})
        result = Socket.subscribe(socket, channel, symbols, state.credentials)
        {result, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp open_shard(state, {channel, index}, symbols, false, delay) do
    Process.send_after(self(), {:open_shard, channel, index, symbols}, delay)
    {:ok, state}
  end

  # `removed` is unsubscribed before `added` is subscribed, on the SAME already-open
  # socket, for BOTH channels and in all three shapes a shard's membership can change
  # (only losses, only gains, both at once) — see the moduledoc's "unsubscribe before
  # subscribe" section for why this replaces the socket-replacement fix `level2` used to
  # need here, and what guarantee the ordering actually rests on. Shrinking before growing
  # is what keeps the socket's own concurrently-held product count at or under
  # `state.level2_pairs_per_socket` at every instant of a reconcile, not merely at rest:
  # the transient count is bounded by `max(length(current), length(wanted))`, both already
  # bounded by shard construction. `ticker` takes the identical path — it has no known
  # ceiling to protect, so the ordering costs it nothing and buys it nothing, but there is
  # no longer a reason for the two channels to reconcile differently at all.
  defp reconcile_shard_in_place(state, key, channel, socket, current, wanted, true, _delay) do
    added = wanted -- current
    removed = current -- wanted

    # `added` is never sent while `removed`'s own unsubscribe has not succeeded — see the
    # moduledoc. No RETRY here, matching every other synchronous, call-reply branch in this
    # module (`open_shard/5`'s own sync clause included): a caller subscribing to the
    # primary shard gets back exactly what happened on this one attempt, not a hidden
    # multi-second retry loop stealing its `@call_timeout` budget. A failed unsubscribe is
    # not simply dropped, though — it is stranded into `state.pending_unsubscribes`, the
    # same record-and-recover-on-the-next-tick shape the async clause's own bounded retry
    # chain falls back to once IT gives up — see `strand_unsubscribe/7` and the moduledoc's
    # "a stranded unsubscribe is not silently forgotten" section.
    {result, state} =
      if Process.alive?(socket) do
        case unsubscribe_step(socket, channel, removed) do
          :ok when added == [] ->
            {:ok, clear_pending_unsubscribe(state, key, removed)}

          :ok ->
            state = clear_pending_unsubscribe(state, key, removed)
            {Socket.subscribe(socket, channel, added, state.credentials), state}

          {:error, reason} = error ->
            state =
              strand_unsubscribe(
                state,
                key,
                channel,
                removed,
                added,
                reason,
                "it will be retried on the next unconditional resubscribe cycle"
              )

            {error, state}
        end
      else
        {:ok, state}
      end

    {result, put_in(state.shards[key], %{socket: socket, symbols: wanted})}
  end

  # `delay` staggers this shard's frames past every OTHER shard `reshard/1` is touching in
  # the same call, the same way `open_shard/5`'s async clause already staggers opening a
  # brand-new socket — see `reshard/1`'s "position * shard_spacing_ms" comment. Before the
  # staggering fix this replaced, `delay` was computed by `reshard/1` and then silently
  # dropped here: a single `update_symbols/2` that reshuffled several ALREADY-OPEN shards
  # at once scheduled every one of their frames at the same instant regardless.
  #
  # Unsubscribe and subscribe are ONE deferred message now, not two independent
  # `Process.send_after/3` calls at the identical `delay` — see the moduledoc. Two timers
  # scheduled for the same tick leave their relative firing order to however the BEAM's
  # timer wheel happens to break the tie, which this module does not get to assume when
  # that order is load-bearing. Folding both into the single `{:channel_reconcile, ...}`
  # message `attempt_channel_reconcile/6` handles makes the order a property of ordinary,
  # sequential Elixir code instead.
  defp reconcile_shard_in_place(state, key, channel, socket, current, wanted, false, delay) do
    added = wanted -- current
    removed = current -- wanted

    if (added != [] or removed != []) and Process.alive?(socket) do
      Process.send_after(
        self(),
        {:channel_reconcile, key, socket, channel, removed, added, state.credentials},
        delay
      )
    end

    {:ok, put_in(state.shards[key], %{socket: socket, symbols: wanted})}
  end

  defp unsubscribe_step(_socket, _channel, []), do: :ok

  defp unsubscribe_step(socket, channel, removed),
    do: Socket.unsubscribe(socket, channel, removed)

  # `pending -- removed` rather than dropping the whole key: a shard can accumulate a
  # stranded release from one reconcile while an UNRELATED, still-outstanding one from an
  # earlier reconcile is also sitting here — see `strand_unsubscribe/7`'s own comment on
  # why entries are merged, never overwritten. Only the symbols THIS successful send
  # actually covered are removed; anything else pending for this shard stays, to be
  # retried on its own account.
  defp clear_pending_unsubscribe(state, _key, []), do: state

  defp clear_pending_unsubscribe(state, key, removed) do
    update_in(state.pending_unsubscribes, fn pending ->
      case Map.get(pending, key, []) -- removed do
        [] -> Map.delete(pending, key)
        remaining -> Map.put(pending, key, remaining)
      end
    end)
  end

  # `Socket.subscribe/4` for `added` only ever runs once `unsubscribe_step/3` has returned
  # `:ok` for THIS message's own `removed` list — see `reconcile_shard_in_place/7`'s async
  # clause and the moduledoc's "unsubscribe before subscribe" section. A transient
  # unsubscribe failure retries the unsubscribe itself, the same bounded backoff a channel
  # subscribe already gets (`handle_unsubscribe_failure/8`), rather than risk sending
  # `added` while `removed` may still be live on the venue's own session. A successful
  # send clears whatever THIS `removed` list covers from `state.pending_unsubscribes` —
  # see `clear_pending_unsubscribe/3` — which is how a shard's own stranding self-heals
  # once this same message is later replayed by `handle_info(:resubscribe, _)`.
  defp attempt_channel_reconcile(
         key,
         socket,
         channel,
         removed,
         added,
         credentials,
         attempt,
         state
       ) do
    if Process.alive?(socket) do
      case unsubscribe_step(socket, channel, removed) do
        :ok ->
          state = clear_pending_unsubscribe(state, key, removed)

          if added == [] do
            {:noreply, state}
          else
            attempt_channel_subscribe(socket, channel, added, credentials, 1, state)
          end

        {:error, reason} ->
          handle_unsubscribe_failure(
            key,
            socket,
            channel,
            {removed, added},
            credentials,
            attempt,
            reason,
            state
          )
      end
    else
      {:noreply, state}
    end
  end

  # Mirrors `handle_subscribe_failure/6`, for the unsubscribe half of a reconcile.
  #
  # **In practice, the non-transient branch below never fires against the real venue.**
  # Every reason `Socket.unsubscribe/3` can return comes from `FrameSender` alone —
  # `Socket.unsubscribe/3` builds no JWT and checks no credentials the way
  # `subscription_message/3` does for a subscribe, so it has no analogue of
  # `{:credentials_required, channel}` to return. `FrameSender.send/3`'s only two error
  # shapes, `:send_timeout` and `{:send_exit, reason}`, are both `transient_frame_failure?/1`
  # `true`. The branch is kept anyway, for the same "do not assume a shape that happens to
  # hold today" reason `handle_subscribe_failure/6` keeps its own non-transient branch —
  # if `Socket.unsubscribe/3`'s own contract ever grows a real permanent-failure reason,
  # this is already wired to handle it identically to an exhausted retry chain, not
  # silently.
  #
  # Exhausting the retries does NOT fall through to subscribing `added` anyway — that
  # would be exactly the risk this whole change exists to avoid: sending `added` while
  # `removed` was never confirmed to have left the venue's own session. `removed` is
  # instead stranded into `state.pending_unsubscribes` (`strand_unsubscribe/7`) and
  # retried on the next unconditional resubscribe cycle — see the moduledoc's "a stranded
  # unsubscribe is not silently forgotten" section for the mechanism and what it does and
  # does not close.
  defp handle_unsubscribe_failure(
         key,
         socket,
         channel,
         {removed, added},
         credentials,
         attempt,
         reason,
         state
       ) do
    cond do
      not transient_frame_failure?(reason) ->
        state =
          strand_unsubscribe(
            state,
            key,
            channel,
            removed,
            added,
            reason,
            "it will be picked back up on the next unconditional resubscribe cycle"
          )

        {:noreply, state}

      attempt > @max_subscribe_retries ->
        state =
          strand_unsubscribe(
            state,
            key,
            channel,
            removed,
            added,
            reason,
            "it will be picked back up on the next unconditional resubscribe cycle"
          )

        {:noreply, state}

      true ->
        Logger.warning(
          "[Coinbase Feed] #{channel} unsubscribe for #{length(removed)} symbol(s) failed " <>
            "(#{inspect(reason)}), attempt #{attempt}/#{@max_subscribe_retries + 1} — " <>
            "retrying in #{state.subscribe_retry_delay_ms}ms before subscribing " <>
            "#{length(added)} newly-added symbol(s)"
        )

        Process.send_after(
          self(),
          {:channel_reconcile, key, socket, channel, removed, added, credentials, attempt + 1},
          state.subscribe_retry_delay_ms
        )

        {:noreply, state}
    end
  end

  # Records `removed` as still (believed) live on the venue after a failed, retry-
  # exhausted unsubscribe — see the moduledoc's "a stranded unsubscribe is not silently
  # forgotten" section. Merged into whatever this shard already has pending
  # (`Enum.uniq(&1 ++ removed)`), never overwritten, so an earlier, still-unresolved
  # stranding on this same shard is not lost by a later, unrelated one. Picked back up by
  # `handle_info(:resubscribe, _)` on the same unconditional cadence
  # `retry_missing_shards/1` already gives a shard whose socket never opened at all, and
  # cleared per symbol the moment a retry actually sends (`clear_pending_unsubscribe/3`).
  defp strand_unsubscribe(state, key, channel, removed, added, reason, outlook) do
    Logger.warning(
      "[Coinbase Feed] #{channel} unsubscribe for #{length(removed)} symbol(s) could not " <>
        "be confirmed sent (#{inspect(reason)}) — #{outlook}; withholding " <>
        "#{length(added)} newly-added symbol(s) on this reconcile"
    )

    notify_unsubscribe_failed(state, channel, removed, added, reason, outlook)

    update_in(state.pending_unsubscribes, fn pending ->
      Map.update(pending, key, removed, &Enum.uniq(&1 ++ removed))
    end)
  end

  # Same shape as `notify_subscribe_failed/5` — `:coverage_change` is Core's kind for
  # exactly this fact: subscribed intent that did not become delivery. Phrased for the
  # unsubscribe half specifically, and naming any withheld `added` symbols, rather than
  # reusing `notify_subscribe_failed/5` and reporting "0 symbol(s)" for a shard that was
  # only ever losing symbols in the first place.
  defp notify_unsubscribe_failed(state, channel, removed, added, reason, outlook) do
    message =
      if added == [] do
        "#{channel} unsubscribe for #{length(removed)} symbol(s) never took — #{outlook}"
      else
        "#{channel} unsubscribe for #{length(removed)} symbol(s) never took — #{outlook}; " <>
          "#{length(added)} newly-added symbol(s) were withheld on this reconcile as a result"
      end

    notice =
      Notice.new(:coverage_change, :coinbase,
        severity: :warning,
        message: message,
        details: %{
          channel: channel,
          removed_count: length(removed),
          added_count: length(added),
          reason: inspect(reason)
        }
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :coinbase, notice})
  end

  # See the moduledoc's "a timed-out subscribe used to be thrown away" section. Re-checks
  # `Process.alive?/1` on every attempt, not just the first — the socket this closure
  # closed over can die between a failed attempt and its scheduled retry, and sending
  # into a dead pid here would be exactly the crash `FrameSender` exists to prevent
  # elsewhere. A dead socket simply stops the chain: nothing subscribes it, and nothing
  # re-attempts against a corpse, matching every other dead-socket branch in this module.
  defp attempt_channel_subscribe(socket, channel, symbols, credentials, attempt, state) do
    if Process.alive?(socket) do
      case Socket.subscribe(socket, channel, symbols, credentials) do
        :ok ->
          :ok

        {:error, reason} ->
          handle_subscribe_failure(socket, channel, symbols, credentials, attempt, reason, state)
      end
    end

    {:noreply, state}
  end

  # Transient: the socket was busy decoding a burst or briefly unreachable, and the
  # identical request can reasonably succeed once it catches up — worth retrying.
  # Everything else (chiefly `{:credentials_required, channel}`, only ever possible on a
  # subscribe — see `Socket.subscription_message/3`) is a fact about the request itself
  # that no amount of waiting changes — retrying it would only loop. Shared between a
  # channel subscribe and the unsubscribe half of a reconcile
  # (`handle_unsubscribe_failure/8`): both send frames through the identical
  # `FrameSender` path and fail in the identical two shapes.
  defp transient_frame_failure?(:send_timeout), do: true
  defp transient_frame_failure?({:send_exit, _reason}), do: true
  defp transient_frame_failure?(_reason), do: false

  defp handle_subscribe_failure(socket, channel, symbols, credentials, attempt, reason, state) do
    cond do
      not transient_frame_failure?(reason) ->
        Logger.warning(
          "[Coinbase Feed] #{channel} subscribe for #{length(symbols)} symbol(s) failed " <>
            "permanently (#{inspect(reason)}) — not retrying"
        )

        notify_subscribe_failed(
          state,
          channel,
          symbols,
          reason,
          "this will keep failing every cycle until it is corrected"
        )

      attempt > @max_subscribe_retries ->
        Logger.warning(
          "[Coinbase Feed] #{channel} subscribe for #{length(symbols)} symbol(s) failed " <>
            "after #{attempt} attempt(s) (#{inspect(reason)}) — giving up until the next " <>
            "resubscribe cycle"
        )

        notify_subscribe_failed(
          state,
          channel,
          symbols,
          reason,
          "it may recover at the next unconditional resubscribe cycle"
        )

      true ->
        Logger.warning(
          "[Coinbase Feed] #{channel} subscribe for #{length(symbols)} symbol(s) failed " <>
            "(#{inspect(reason)}), attempt #{attempt}/#{@max_subscribe_retries + 1} — " <>
            "retrying in #{state.subscribe_retry_delay_ms}ms"
        )

        Process.send_after(
          self(),
          {:channel_subscribe, socket, channel, symbols, credentials, attempt + 1},
          state.subscribe_retry_delay_ms
        )
    end
  end

  # Loud on purpose — see the moduledoc's "exhaustion is loud" section. A channel that
  # never subscribed is exactly the invisible half-dead feed DpCryptoManagement's issue
  # #22 is about, and a `Logger.warning` alone gave a consumer no facade-level way to see
  # it. `:coverage_change` is Core's kind for exactly this shape of fact: subscribed
  # intent that did not become delivery, which is what should send a consumer back to
  # `coverage/1` or `coverage_by_kind/1` rather than trusting a quiet chart.
  defp notify_subscribe_failed(state, channel, symbols, reason, outlook) do
    notice =
      Notice.new(:coverage_change, :coinbase,
        severity: :warning,
        message: "#{channel} subscribe for #{length(symbols)} symbol(s) never took — #{outlook}",
        details: %{channel: channel, symbol_count: length(symbols), reason: inspect(reason)}
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :coinbase, notice})
  end

  # A shard whose socket never opened at all — connect refused, timed out, or DNS
  # failed — is the same "subscribed intent that did not become delivery" fact as a
  # channel that failed to subscribe on an already-open socket, so it gets the same
  # `:coverage_change` kind `notify_subscribe_failed/5` uses. See
  # `handle_info({:open_shard, _, _}, _)` for why a `Logger.warning` alone was not enough:
  # it never crosses the facade, and this shard's symbols are otherwise silently absent
  # from `coverage/1` with nothing telling a consumer why.
  defp notify_shard_open_failed(state, channel, index, symbols, reason) do
    notice =
      Notice.new(:coverage_change, :coinbase,
        severity: :warning,
        message:
          "#{channel} shard #{index} (#{length(symbols)} symbol(s)) did not open — " <>
            "staying on the internal poll until the next resubscribe cycle retries it",
        details: %{
          shard: index,
          channel: channel,
          symbol_count: length(symbols),
          reason: inspect(reason)
        }
      )

    fan_out(state.notice_subscribers, {:dp_exchange, :coinbase, notice})
  end

  defp get_socket(%{injected_socket: socket} = state) when is_pid(socket) do
    {:ok, socket, %{state | injected_socket: nil}}
  end

  defp get_socket(state) do
    opts = Keyword.merge(state.socket_opts, subscriber: self(), credentials: state.credentials)

    case Socket.start_link(opts) do
      {:ok, socket} -> {:ok, socket, state}
      {:error, reason} -> {:error, reason}
    end
  end

  # `Types.Quote`, `Types.OrderBook` and `Types.OrderBookDelta` all carry `:symbol`;
  # this is the one place coverage tracking needs to be generic over which kind
  # arrived.
  defp delivered_symbol(%{symbol: symbol}), do: symbol

  # The `Core.Types.*` struct names its own kind — never a venue channel name. `Socket`
  # sends exactly these three structs (plus `Notice`, matched in its own `handle_info/2`
  # clause above) into this module, so there is deliberately no catch-all: an unrecognised
  # struct here means a new payload kind was wired into `Socket` without being taught to
  # this function, and failing loudly beats silently mis-tagging its coverage.
  #
  # `%Types.OrderBookDelta{}` maps to `:order_book`, the same kind `%Types.OrderBook{}`
  # does — `coverage_by_kind/1` answers "which kind of data is arriving", not "in what
  # shape", and a host checking whether book data is flowing does not care whether the
  # next message is a full snapshot or an incremental delta. See `dp_exchange_core`'s
  # `Types.OrderBookDelta` moduledoc and its
  # `2026-09-06_stop-maintaining-books-in-packages.md` design doc for the reasoning.
  defp payload_kind(%Types.Quote{}), do: :quotes
  defp payload_kind(%Types.OrderBook{}), do: :order_book
  defp payload_kind(%Types.OrderBookDelta{}), do: :order_book

  # Schedules the alias-map fetch exactly once, the first time it is needed — see the
  # moduledoc. `:unfetched` is the only status this fires from, and it flips to
  # `:pending` in the same breath, so a second `subscribe/3` or `update_symbols/2` before
  # the async fetch resolves schedules nothing further.
  defp maybe_schedule_alias_map_fetch(%{alias_map_status: :unfetched} = state) do
    Process.send_after(self(), :fetch_alias_map, 0)
    %{state | alias_map_status: :pending}
  end

  defp maybe_schedule_alias_map_fetch(state), do: state

  # The production default for `alias_map_source` — see the moduledoc's "the fetch has to
  # wait, not fail" section (DpCryptoManagement's issue #26). Forwards the same options
  # `Rest`'s own request pipeline understands, so a caller of `start_link/1` can tune the
  # alias fetch's HTTP behaviour exactly as it would any other `Rest` call, and so a test
  # can drive the real fetch end-to-end with a fake `:plug` behind a real, named
  # `:limiter` rather than only ever exercising the `alias_map_source` injection seam.
  #
  # `rate_limit_blocking: true` is the fix: this is the one caller that can wait, by
  # construction — it runs off `Process.send_after`, nothing blocks on its result, and its
  # only job is to populate a cache before frames arrive. `Keyword.put_new/3` rather than
  # `Keyword.put/3` so an explicit override survives, matching every other opt here.
  defp default_alias_map_source(opts, credentials) do
    rest_opts =
      opts
      |> Keyword.take([:limiter, :plug, :timeout, :retry_attempts, :retry_delay, :weight])
      |> Keyword.put(:credentials, credentials)
      |> Keyword.put_new(:rate_limit_blocking, true)

    fn -> Rest.get_alias_map(rest_opts) end
  end

  # One attempt of the alias-map fetch, whichever attempt number this is — see the
  # moduledoc's "classified and retried" section.
  defp attempt_alias_map_fetch(attempt, state) do
    case state.alias_map_source.() do
      {:ok, map} when is_map(map) ->
        {:noreply,
         %{state | alias_map: map, alias_map_status: :ok, alias_map_failure_reason: nil}}

      {:error, reason} ->
        handle_alias_map_fetch_failure(attempt, reason, state)
    end
  end

  # Transient: the caller's own rate limiter made this fetch wait, and the wait itself ran
  # out before capacity freed up (`rate_limit_blocking: true` chooses `acquire/3`, whose
  # own bounded wait times out this way — see `Core.DefaultRateLimiter.acquire/3`) — the
  # identical request can reasonably succeed once the limiter's bucket has drained
  # further. Everything else — an unrecognised response shape, a refused request, a raw or
  # unclassified reason (including whatever a test's own stand-in returns) — is a fact
  # about the request or the venue that no amount of waiting changes, so it is not
  # retried, matching `transient_subscribe_failure?/1`'s own default-to-permanent stance.
  defp transient_alias_map_failure?({:exchange_error, _venue, :rate_limit_timeout}), do: true
  defp transient_alias_map_failure?(_reason), do: false

  defp handle_alias_map_fetch_failure(attempt, reason, state) do
    cond do
      not transient_alias_map_failure?(reason) ->
        Logger.warning(
          "[Coinbase Feed] alias catalogue fetch failed permanently (#{inspect(reason)}) — " <>
            "not retrying; delivering under the venue's own product id until restarted"
        )

        give_up_on_alias_map(state, reason)

      attempt > @max_alias_map_retries ->
        Logger.warning(
          "[Coinbase Feed] alias catalogue fetch failed after #{attempt} attempt(s) " <>
            "(#{inspect(reason)}) — giving up; delivering under the venue's own product " <>
            "id until restarted"
        )

        give_up_on_alias_map(state, reason)

      true ->
        Logger.warning(
          "[Coinbase Feed] alias catalogue fetch failed (#{inspect(reason)}), attempt " <>
            "#{attempt}/#{@max_alias_map_retries + 1} — retrying in " <>
            "#{state.alias_map_retry_delay_ms}ms"
        )

        Process.send_after(
          self(),
          {:fetch_alias_map, attempt + 1},
          state.alias_map_retry_delay_ms
        )

        {:noreply, state}
    end
  end

  defp give_up_on_alias_map(state, reason) do
    notify_degraded_attribution(state, reason)

    {:noreply,
     %{state | alias_map: %{}, alias_map_status: :unavailable, alias_map_failure_reason: reason}}
  end

  # See the moduledoc's "the venue rewrites an aliased product id on delivery" section.
  # `delivered` is whatever the venue actually tagged this frame with; `equivalent` is its
  # alias under the venue's own declared relationship, if the catalogue named one. A
  # delivered id resolves to every name in `wanted` that names the same market — which is
  # `[delivered, equivalent]` filtered down to what the caller actually asked for, and
  # covers the "both names subscribed" case by construction: if both are wanted, both
  # survive the filter and both receive a copy below.
  defp attribution_targets(payload, state) do
    delivered = delivered_symbol(payload)
    equivalent = Map.get(state.alias_map, delivered)

    targets =
      [delivered, equivalent]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.filter(&MapSet.member?(state.wanted, &1))

    # Nothing in `wanted` resolved — the map is empty (unfetched, permanently failed, or
    # the venue genuinely aliases nothing here, which look identical by design) or this
    # frame is for a symbol outside `wanted` altogether (in-flight just after an
    # unsubscribe, or a raw `send/2` in a test). Either way: deliver under whatever the
    # venue actually sent, the exact pre-fix behaviour, never a fabricated name.
    if targets == [], do: [delivered], else: targets
  end

  # Fired once, when the alias-map fetch gives up for good (permanently, or after
  # exhausting its retries) — see `handle_alias_map_fetch_failure/3`. Never on every
  # delivered frame: a notice is a condition to act on, not per-message noise, and this
  # condition does not change again once the fetch has given up. `degraded_attribution_notice/1`
  # is factored out so a subscriber that registers late (see
  # `handle_call({:subscribe_notices, _}, _, _)` above and the moduledoc's "a late notice
  # subscriber has to be able to hear it" section) can be replayed the exact same notice.
  defp notify_degraded_attribution(state, reason) do
    fan_out(
      state.notice_subscribers,
      {:dp_exchange, :coinbase, degraded_attribution_notice(reason)}
    )
  end

  defp degraded_attribution_notice(reason) do
    Notice.new(:data_quality, :coinbase,
      message:
        "alias catalogue unavailable — delivering under the venue's own product id " <>
          "rather than the caller's requested symbol",
      details: %{reason: inspect(reason)}
    )
  end

  # A dead subscriber stops delivery. The venue must not accumulate events for a process
  # that no longer exists.
  #
  # A subscriber may be a raw pid or a registered name — `subscribe/2`'s `to:` accepts
  # either, matching ordinary OTP practice (a consumer registering itself by name and
  # handing that name to a producer). `Process.alive?/1` only accepts a pid and raises on
  # anything else, so a registered-name subscriber crashed this whole GenServer on every
  # delivery. Resolving first, uniformly, fixes both: a dead pid resolves to itself and
  # `Process.alive?/1` filters it; an unregistered name resolves to `nil` and is silently
  # skipped, the same as a dead subscriber already was.
  defp fan_out(subscribers, message) do
    Enum.each(subscribers, fn subscriber ->
      case resolve_subscriber(subscriber) do
        pid when is_pid(pid) -> send(pid, message)
        nil -> :ok
      end
    end)
  end

  defp resolve_subscriber(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid
  end

  defp resolve_subscriber(name) when is_atom(name), do: Process.whereis(name)

  # `fan_out/2` restricted to exactly one subscriber — see
  # `handle_call({:subscribe_notices, _}, _, _)`'s notice-replay above. A `MapSet` of one
  # would work too, but this says directly what it does: tell this one subscriber, not
  # "everyone in a set that happens to have one member".
  defp notify_one(subscriber, message) do
    case resolve_subscriber(subscriber) do
      pid when is_pid(pid) -> send(pid, {:dp_exchange, :coinbase, message})
      nil -> :ok
    end
  end
end

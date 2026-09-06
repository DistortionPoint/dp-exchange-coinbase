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

  **No documentation states the real ceiling.** Re-read 2026-09-06 specifically looking
  for a per-session `level2` stream count: the Advanced Trade channels reference, the
  connection overview, and the Advanced Trade rate-limits page ("WebSocket connections
  and unauthenticated messages are each limited to 8 per second per IP" — a connect-rate
  ceiling, not a per-session subscription count) all say nothing about how many products
  one session may carry on `level2`. The older Exchange product's own separate
  rate-limits page states a different number entirely — 10 subscriptions per *product*
  per channel, meaning duplicate subscriptions to the same product, not the count of
  distinct products — and this package speaks Advanced Trade (`Socket`'s `@endpoint`),
  not Exchange, so that number would not transfer even if it were on point. The prior
  investigation that first shipped `@pairs_per_socket` found the docs silent on this; they
  still are.

  **This package cannot narrow it by probing the venue itself, either.** `level2` is on
  `@authenticated_channels`, and this repo's own testing strategy draws the line at
  exactly that boundary: tier 2 (live public endpoints, by hand) is fair game, tier 3
  (authenticated) "needs credentials this repo must never hold." Finding the exact
  ceiling would mean bisecting a real session's `level2` subscription size against the
  live venue with a real credential — precisely tier 3. That is not merely inconvenient;
  it is a line this repo does not cross for any endpoint, `level2` included.

  **`@level2_pairs_per_socket` is `6`.** Not a rediscovered venue limit — the largest
  `level2` subscription size this package has any positive evidence the venue accepts,
  taken directly from the production numbers above: 100 was refused four times out of
  four, 6 succeeded once out of one. Anything strictly between those two is exactly the
  unverified guess this family forbids presenting as measured; 6 is the one figure
  actually in evidence. It is deliberately conservative — the true ceiling may be well
  above it — and that headroom is traded away on purpose rather than spent on a number
  with nothing behind it but a guess at where between a known failure and a known success
  the line falls.

  **The two channels no longer share a shard slice.** `ticker` keeps `@pairs_per_socket`
  (100) — it has no known ceiling, and shrinking it to match `level2` would multiply
  connection count for the channel that was never the problem, for no benefit `ticker`
  needs. `level2` is chunked separately, at `@level2_pairs_per_socket`, and every chunk of
  either channel opens its own dedicated, single-channel socket: there is no longer a
  shard that carries both. For the 406-symbol universe above that is 5 `ticker` sockets
  (unchanged) plus 68 `level2` sockets (`ceil(406 / 6)`) — 73 total against 5 before.
  `Socket`'s own moduledoc records why more sockets is affordable now in a way it would
  not have been before 2026-09-06: removing in-package `level2` book maintenance cut
  per-frame decode cost roughly tenfold (65–110 ms to 6.6 ms, at the `BTC-USD` book size
  DpCryptoManagement measured live) — decode cost, not socket count, was the resource
  actually in short supply.

  **Connects are staggered across both groups on one sequence, `ticker` first.** Every new
  socket this module opens — whichever channel it carries — takes the next tick of
  `@shard_spacing_ms`, in an order that places every touched `ticker` shard ahead of every
  touched `level2` shard. This is what keeps `ticker`'s own boot-time coverage exactly as
  fast as the section above describes: a 406-symbol subscribe still resolves its
  synchronous reply and its remaining `ticker` shards inside the same handful of seconds
  as before this fix, with `level2`'s 68 shards ramping in behind them. For that universe
  the last `level2` shard's tick lands roughly six minutes after boot — materially slower
  than `ticker`'s own coverage, and an accepted, stated cost: `order_book` coverage was
  permanently `6 / 406` before this fix, climbing by 5,099 refusals and counting; ramping
  to `406 / 406` over several minutes is strictly better than a ceiling that never moves,
  and nothing about `level2` streaming is boot-latency-sensitive the way `ticker`'s
  starvation was.

  **`level2` no longer needs to go first on a shared socket, because there is no longer a
  shared socket.** What used to be this section — "`level2` before `ticker`, spaced by
  `@channel_spacing_ms`" — existed only because a subscribe burst on one channel could
  stall the other's `send_frame` on the *same* connection. With every socket now carrying
  exactly one channel, that specific hazard cannot occur, and `@channel_spacing_ms` is
  gone. A subscribe can still hit `:send_timeout` against its own socket's own burst — a
  `level2` socket decoding its own six-symbol snapshot, say — so the retry chain below is
  unchanged in kind; `@subscribe_retry_delay_ms` keeps its previous value (`8_000`ms) but
  is no longer *borrowed* from a channel-spacing constant, because that constant no longer
  exists to borrow it from — see its own comment.

  **An adaptive, self-shrinking shard size was considered and rejected — for now.** The
  venue's own refusal could in principle drive `@level2_pairs_per_socket` down further at
  runtime, so a wrong constant could never be silently wrong forever — the option the
  architect's own brief for this fix raised directly. It was not built: correctly
  reconciling a shard *resize*, as opposed to the shard *membership change* `reshard/1`
  already handles, needs this module to tell a live, still-subscribed shard's bookkeeping
  apart from a stale one whose symbols the venue already dropped when it refused and
  closed the connection — and getting that race wrong risks silently under- or
  double-subscribing a shard, which is a worse failure mode than the loud, honest one this
  module otherwise insists on everywhere else. Given `6` is not a guess but the one number
  already proven safe, a correct runtime resize's complexity did not clear its bar against
  a fixed, evidence-grounded constant plus the safety net that already exists:
  `Socket`'s own `error_kind/1` already classifies "too many" as `:rate_limited` and
  reports it as a `Core.Notice` on every occurrence (see `Socket`'s moduledoc), and
  `coverage_by_kind/1` already never marks a symbol covered for `:order_book` on intent
  alone — both pre-existing, verified unchanged by this fix, not new mechanism built for
  it. If `6` is ever also refused, a consumer with `subscribe_notices/1` wired up hears
  about it exactly as loudly as every other refusal in this file, and lowering the
  constant is a one-line, reviewable change rather than a runtime decision this module
  made silently on its own.

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

  `@shard_spacing_ms` staggers shard opens **relative to each other**, not relative to a
  fixed instant. A scope wide enough to need three or more shards — DpCryptoManagement's
  issue #20, 406 symbols / 5 shards, filed against real production traffic — used to
  schedule every shard past the first (the synchronous one) with the *same* fixed delay,
  so all of them opened in the same instant: exactly the connect burst this module's own
  design note above warns the venue answers with resets. Only the shard whose burst-mate
  connections lost that race ever delivered a tick; coverage sat at whatever fraction of
  one shard survived, indistinguishable from the outside from a quiet market. The
  60-second unconditional resubscribe re-issued the same burst every minute. Both paths
  now schedule each shard's turn `position * @shard_spacing_ms` after the one before it.

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

  # `level2`'s own shard size — deliberately NOT `@pairs_per_socket`. Not a rediscovered
  # venue limit either: no Coinbase documentation states one (re-checked 2026-09-06), and
  # this repo cannot probe an authenticated channel live to find one (see the moduledoc).
  # `6` is the largest `level2` subscription size this package has direct evidence the
  # venue accepts — DpCryptoManagement's own production report: 100 refused four times out
  # of four, 6 accepted once out of one. See the moduledoc for why a number strictly
  # between those two was rejected as an unlabelled guess.
  @level2_pairs_per_socket 6

  # Between opening each new socket, whichever channel it will carry. Opening several
  # connections in the same instant is a connect burst the venue answers with resets.
  @shard_spacing_ms 5_000

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
  # failure can be fixed by waiting" in the moduledoc.
  #
  # The whole retry chain for one channel subscribe must finish well inside a resubscribe
  # cycle, or its tail would stack fresh frames onto a socket the next unconditional
  # re-issue is about to hit again (see `next_resubscribe_delay/1`). Worst case:
  # `@max_subscribe_retries * @subscribe_retry_delay_ms` = 16_000ms — comfortably inside
  # the 60s default and inside any interval `next_resubscribe_delay/1` computes (which
  # only ever extends the interval, never shortens it). No per-shard channel offset to add
  # any more: each socket carries exactly one channel now, so there is no "second channel
  # on this socket" delay to stack on top.
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
  # would be feeding the counter — the open question in DpCryptoManagement's issue #22.
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
  its own, smaller size — see the moduledoc's "`level2` gets its own, smaller sockets"
  section — and has no public function of its own, the same way it has no public
  visibility anywhere else in this module.
  """
  @spec shards([String.t()]) :: [[String.t()]]
  def shards([]), do: []
  def shards(symbols), do: Enum.chunk_every(symbols, @pairs_per_socket)

  # `level2`'s own grouping — never exposed, for the same reason `shards/1` documents
  # itself as `ticker`-only above: this module's whole point is that a consumer cannot
  # tell how data arrives, and per-channel shard sizes are exactly that.
  defp level2_shards([]), do: []
  defp level2_shards(symbols), do: Enum.chunk_every(symbols, @level2_pairs_per_socket)

  # Which channels this feed carries at all, given whether it has credentials — see
  # `Socket`'s `@authenticated_channels`. A credential-less caller only ever wanted the
  # public `ticker` channel; sending a doomed `level2` subscribe would either report a
  # `credentials_required` error as a call's synchronous result (masking that `ticker`
  # works fine) or cost a wire round trip to learn what the credential's absence already
  # answers.
  defp active_channels(nil), do: ["ticker"]
  defp active_channels(_credentials), do: ["ticker", "level2"]

  # Each channel's own grouping, at its own size — see `shards/1` and `level2_shards/1`.
  defp shards_for(symbols, "ticker"), do: shards(symbols)
  defp shards_for(symbols, "level2"), do: level2_shards(symbols)

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
       # whose socket has not opened yet (still waiting out its `@shard_spacing_ms`
       # delay, or the connect failed) is simply absent — its symbols stay on whatever
       # this package's REST poll answers until the socket comes up.
       shards: %{},
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

  def handle_info({:channel_unsubscribe, socket, channel, symbols}, state) do
    if Process.alive?(socket), do: Socket.unsubscribe(socket, channel, symbols)
    {:noreply, state}
  end

  def handle_info(:resubscribe, state) do
    Process.send_after(self(), :resubscribe, next_resubscribe_delay(state))

    # Staggered the same way `reshard/1` staggers opening several new shards: re-issuing
    # every shard's subscribe in the same instant is the identical connect/subscribe
    # burst the moduledoc warns about, just recurring on this cadence instead of once at
    # boot. `ticker` shards sort first — see `shard_key_order/2` — so an already-open
    # `ticker` shard's re-issue is never pushed behind the (likely far more numerous)
    # `level2` shards'.
    state.shards
    |> Map.keys()
    |> Enum.sort(&shard_key_order/2)
    |> Enum.with_index()
    |> Enum.each(fn {{channel, _index} = key, position} ->
      %{socket: socket, symbols: symbols} = Map.fetch!(state.shards, key)

      if Process.alive?(socket) do
        Process.send_after(
          self(),
          {:resubscribe_shard, socket, channel, symbols, state.credentials},
          position * @shard_spacing_ms
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
    # connect-burst reason `@shard_spacing_ms` exists everywhere else in this module.
    retry_missing_shards(state)

    {:noreply, state}
  end

  def handle_info({:resubscribe_shard, socket, channel, symbols, credentials}, state) do
    if Process.alive?(socket) do
      Process.send_after(self(), {:channel_subscribe, socket, channel, symbols, credentials}, 0)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- internal ------------------------------------------------------------

  # A re-issue cycle is not instantaneous: every shard — `ticker` and `level2` alike, each
  # on its own socket now — is staggered `@shard_spacing_ms` apart, so the last frame of a
  # cycle goes out roughly
  #
  #     (shards - 1) * @shard_spacing_ms
  #
  # after the tick. If the timer re-fires before that, cycles overlap: frames queue behind
  # each other, `WebSockex.send_frame/2` blows its window, and the `Feed` can stop
  # answering calls entirely while it drains — a wedged feed, which is strictly worse than
  # a late resubscribe.
  #
  # DpCryptoManagement hit this in issue #22 by setting `resubscribe_interval_ms: 5_000`,
  # well below even one shard's own send window, and lost the run to it. But the same
  # failure is reachable with NO option set: the 60s default is shorter than the cycle span
  # from 13 shards upward — reachable well inside a single, wide `level2` grouping alone
  # now that it is sized at `@level2_pairs_per_socket` rather than `@pairs_per_socket` (a
  # 406-symbol universe alone needs 68 `level2` shards), so a large enough consumer walks
  # into this far sooner than before.
  #
  # The delay is therefore derived from the shard count that actually exists right now,
  # never from the configured value alone, and the extension is logged rather than applied
  # silently — a diagnostic knob whose value is quietly ignored is its own trap.
  defp next_resubscribe_delay(state) do
    shard_count = map_size(state.shards)
    span = max(shard_count - 1, 0) * @shard_spacing_ms
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
  # Staggered starting one `@shard_spacing_ms` past every already-open shard's own
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
      |> shards_for(channel)
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
        (base + position) * @shard_spacing_ms
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
  # `@shard_spacing_ms` many times over and risk a connect burst besides.
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
        |> shards_for(channel)
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
                delay: position * @shard_spacing_ms
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

  defp drop_unwanted_shards(state, existing_keys, wanted_keys) do
    %{state | shards: Map.drop(state.shards, existing_keys -- wanted_keys)}
  end

  defp touch_shard(state, key, new_shards, sync: sync?, delay: delay) do
    wanted_symbols = Map.fetch!(new_shards, key)

    case get_in(state.shards[key]) do
      nil ->
        open_shard(state, key, wanted_symbols, sync?, delay)

      %{symbols: current, socket: socket} ->
        reconcile_shard(state, key, socket, current, wanted_symbols, sync?, delay)
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

  defp reconcile_shard(state, {channel, _index} = key, socket, current, wanted, true, _delay) do
    added = wanted -- current
    removed = current -- wanted

    result =
      cond do
        not Process.alive?(socket) ->
          :ok

        added != [] ->
          result = Socket.subscribe(socket, channel, added, state.credentials)
          if removed != [], do: Socket.unsubscribe(socket, channel, removed)
          result

        removed != [] ->
          Socket.unsubscribe(socket, channel, removed)

        true ->
          :ok
      end

    {result, put_in(state.shards[key], %{socket: socket, symbols: wanted})}
  end

  # `delay` staggers this shard's frames past every OTHER shard `reshard/1` is touching in
  # the same call, the same way `open_shard/5`'s async clause already staggers opening a
  # brand-new socket — see `reshard/1`'s "position * @shard_spacing_ms" comment. Before
  # this fix `delay` was computed by `reshard/1` and then silently dropped here: a single
  # `update_symbols/2` that reshuffled several ALREADY-OPEN shards at once scheduled every
  # one of their subscribes at the same instant regardless. Because `Socket.subscribe/4`
  # blocks THIS process (via `FrameSender`, up to `WebSockex.send_frame/2`'s 5s window)
  # once `attempt_channel_subscribe/6` runs it, several such messages landing on this
  # GenServer's mailbox together serialise into back-to-back blocking sends — a socket
  # answering slowly stalls this shard's own subscribe AND every later one queued behind
  # it in the SAME mailbox, taking `coverage/1`, `subscribe/3` and every other call to this
  # `Feed` down with it for as long as the stall lasts. Staggering by `delay` spreads that
  # risk out exactly as it already is for a newly-opened shard.
  defp reconcile_shard(state, {channel, _index} = key, socket, current, wanted, false, delay) do
    added = wanted -- current
    removed = current -- wanted

    if removed != [] and Process.alive?(socket) do
      Process.send_after(self(), {:channel_unsubscribe, socket, channel, removed}, delay)
    end

    if added != [] and Process.alive?(socket) do
      Process.send_after(
        self(),
        {:channel_subscribe, socket, channel, added, state.credentials},
        delay
      )
    end

    {:ok, put_in(state.shards[key], %{socket: socket, symbols: wanted})}
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
  # Everything else (chiefly `{:credentials_required, channel}`) is a fact about the
  # request itself that no amount of waiting changes — retrying it would only loop.
  defp transient_subscribe_failure?(:send_timeout), do: true
  defp transient_subscribe_failure?({:send_exit, _reason}), do: true
  defp transient_subscribe_failure?(_reason), do: false

  defp handle_subscribe_failure(socket, channel, symbols, credentials, attempt, reason, state) do
    cond do
      not transient_subscribe_failure?(reason) ->
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

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

  `@pairs_per_socket` is **100**, carried over from the reference fix this replaces
  rather than re-derived — the number came from a real production incident, not this
  package's own probing, and is recorded as such rather than presented as freshly
  measured.

  ## `level2` before `ticker`, on the same socket

  Each shard's socket carries both channels for its own slice of symbols, `level2`
  subscribed first: it is what takes a shard from partial to full coverage, and
  subscribing it before the lighter channel means the book is already flowing by the
  time `ticker` adds its own load. The two are spaced apart on the wire — a `level2`
  subscribe triggers a full per-symbol book snapshot, and firing `ticker`'s subscribe
  into a socket still decoding that arrives as a `send_timeout` and can take the
  connection down with it.

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

  ### The backoff borrows a number this module already trusts, rather than inventing one

  A retry needs to wait out the same busy-socket condition `@channel_spacing_ms` already
  exists to wait out between `level2` and `ticker` on the same socket — so
  `@subscribe_retry_delay_ms` **is** `@channel_spacing_ms`, not a second, independently
  guessed number for the same underlying wait. `@max_subscribe_retries` is `2`: one initial
  attempt plus two retries is enough to survive one snapshot burst without turning a stuck
  socket into an unbounded loop. See the constants' own comments for the arithmetic that
  keeps the whole retry chain well inside a resubscribe cycle, so it can never stack frames
  against the unconditional re-issue documented above.

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
  to disagree; `Socket.books` for `level2` stays keyed by whatever id the venue delivers
  under, which is correct and unobservable — one maintained book per real market, whether
  one or two caller-facing names point at it, matching whichever channel delivered it
  (`ticker` via `deliver_ticker/3` or `level2` via `apply_book_event/3`/`deliver_book/3`
  in `Socket`) since both arrive here as the same `{:dp_exchange, :coinbase, payload}`
  shape and both structs carry `:symbol`.

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
  `Types.Quote` and `Types.OrderBook` both carry `:symbol`, so a `level2` book update and
  a `ticker` quote count identically toward `delivering`, and a symbol with one of the two
  dark looks exactly like a symbol with both healthy.

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
  `%Types.OrderBook{}` is `:order_book` — never off a channel name. `level2` and `ticker`
  are this venue's words for its own wire protocol and stop existing the moment a frame
  becomes a `Core.Types.*` struct; `coverage_by_kind/1` never sees them and could not leak
  them if it wanted to.

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

  @channels ["level2", "ticker"]

  # See the moduledoc: measured on the venue this package replaces, not on this one.
  @pairs_per_socket 100

  # Between opening each shard's socket. Opening several connections in the same instant
  # is a connect burst the venue answers with resets.
  @shard_spacing_ms 5_000

  # Between a shard's `level2` and `ticker` subscribes on the same socket. `level2`
  # triggers a full snapshot per symbol and the connection is busy decoding it; firing
  # `ticker` on top of that arrives as a `send_timeout`.
  @channel_spacing_ms 8_000

  # A retry waits out the same busy-socket condition `@channel_spacing_ms` already exists
  # to wait out — see the moduledoc's "a timed-out subscribe used to be thrown away"
  # section. Reusing it rather than a second, independently guessed number for the same
  # underlying wait: the thing that caused the timeout was a socket still decoding a
  # `level2` snapshot burst, and this is already the duration this module trusts to be
  # enough for that.
  #
  # Overridable via `:subscribe_retry_delay_ms`, for the same reason
  # `:resubscribe_interval_ms` is: a test proving a retry actually happens and succeeds
  # must not wait out the real, multi-second production delay to do it.
  @subscribe_retry_delay_ms @channel_spacing_ms

  # One initial attempt plus this many retries. Bounded deliberately — see "not every
  # failure can be fixed by waiting" in the moduledoc.
  #
  # The whole retry chain for one channel subscribe must finish well inside a resubscribe
  # cycle, or its tail would stack fresh frames onto a socket the next unconditional
  # re-issue is about to hit again (see `next_resubscribe_delay/1`). Worst case: the
  # channel itself can start up to `@channel_spacing_ms` after its shard's tick (there are
  # only two channels, so at most one channel-spacing delay ahead of the first), plus
  # `@max_subscribe_retries * @subscribe_retry_delay_ms` for the retries themselves —
  # 8_000 + 2 * 8_000 = 24_000ms, comfortably inside the 60s default and inside any
  # interval `next_resubscribe_delay/1` computes (which only ever extends the interval,
  # never shortens it).
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

  @spec pairs_per_socket() :: pos_integer()
  def pairs_per_socket, do: @pairs_per_socket

  @doc "The scope split into one list per socket."
  @spec shards([String.t()]) :: [[String.t()]]
  def shards([]), do: []
  def shards(symbols), do: Enum.chunk_every(symbols, @pairs_per_socket)

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

  def handle_info({:open_shard, index, symbols}, state) do
    case get_socket(state) do
      {:ok, socket, state} ->
        state = put_in(state.shards[index], %{socket: socket, symbols: symbols})
        schedule_channel_subscribes(socket, symbols, state.credentials)
        {:noreply, state}

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
        # about. `notify_shard_open_failed/3` closes that gap with the same
        # `:coverage_change` kind `notify_subscribe_failed/5` already uses for a channel
        # that never subscribed — both are "subscribed intent that did not become
        # delivery".
        Logger.warning(
          "[Coinbase Feed] shard #{index} did not open (#{inspect(reason)}) — " <>
            "its #{length(symbols)} symbol(s) stay on the internal poll only"
        )

        notify_shard_open_failed(state, index, symbols, reason)
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
    # every shard's `level2` subscribe in the same instant is the identical connect/subscribe
    # burst the moduledoc warns about, just recurring every minute instead of once at boot.
    state.shards
    |> Enum.sort_by(fn {index, _shard} -> index end)
    |> Enum.with_index()
    |> Enum.each(fn {{_index, %{socket: socket, symbols: symbols}}, position} ->
      if Process.alive?(socket) do
        Process.send_after(
          self(),
          {:resubscribe_shard, socket, symbols, state.credentials},
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

  def handle_info({:resubscribe_shard, socket, symbols, credentials}, state) do
    if Process.alive?(socket), do: schedule_channel_subscribes(socket, symbols, credentials)
    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- internal ------------------------------------------------------------

  # A re-issue cycle is not instantaneous: shards are staggered `@shard_spacing_ms` apart,
  # and within each shard the channels are staggered `@channel_spacing_ms` apart, so the
  # last frame of a cycle goes out roughly
  #
  #     (shards - 1) * @shard_spacing_ms + @channel_spacing_ms
  #
  # after the tick. If the timer re-fires before that, cycles overlap: frames queue behind
  # each other, `WebSockex.send_frame/2` blows its window, and the `Feed` can stop
  # answering calls entirely while it drains — a wedged feed, which is strictly worse than
  # a late resubscribe.
  #
  # DpCryptoManagement hit this in issue #22 by setting `resubscribe_interval_ms: 5_000`,
  # below the 8s channel spacing, and lost the run to it. But the same failure is reachable
  # with NO option set: the 60s default is shorter than the cycle span from 12 shards
  # (1,101 symbols at `@pairs_per_socket`) upward, so a large enough consumer would have
  # walked into it on defaults alone.
  #
  # The delay is therefore derived from the shard count that actually exists right now,
  # never from the configured value alone, and the extension is logged rather than applied
  # silently — a diagnostic knob whose value is quietly ignored is its own trap.
  defp next_resubscribe_delay(state) do
    shard_count = map_size(state.shards)
    span = max(shard_count - 1, 0) * @shard_spacing_ms + @channel_spacing_ms
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

  # Re-attempts opening any shard `state.wanted` implies that is not currently a key in
  # `state.shards` — see `handle_info(:resubscribe, _)` for why this exists: a shard whose
  # socket never opened has no other automatic recovery path. Computed the same way
  # `reshard/1` computes `new_shards`, so the indices agree with whatever a fresh
  # `subscribe/3` or `update_symbols/2` call would also compute for the same `wanted` set.
  #
  # Staggered starting one `@shard_spacing_ms` past every already-open shard's own
  # resubscribe slot (`map_size(state.shards)` of them, scheduled just above), so a retry
  # here never lands in the same instant as an open shard's unconditional resubscribe.
  defp retry_missing_shards(state) do
    existing = Map.keys(state.shards)
    base = map_size(state.shards)

    state.wanted
    |> MapSet.to_list()
    |> shards()
    |> Enum.with_index()
    |> Enum.reject(fn {_symbols, index} -> index in existing end)
    |> Enum.with_index()
    |> Enum.each(fn {{symbols, index}, position} ->
      Process.send_after(
        self(),
        {:open_shard, index, symbols},
        (base + position) * @shard_spacing_ms
      )
    end)
  end

  # Recomputes shards from `state.wanted` and reconciles: a shard whose symbol set
  # changed gets its socket's subscriptions brought current, a brand-new shard gets a
  # socket opened, and a shard that no longer has any symbols is dropped — its socket is
  # left to WebSockex's own lifecycle rather than torn down here, because a shard
  # reappearing moments later (a common `update_symbols` pattern) should not pay to
  # reopen a connection it only just closed.
  #
  # ## Why exactly one shard is handled synchronously
  #
  # A caller subscribing to ten symbols touches one shard and needs to know, in the
  # reply, whether that connection actually accepted the request — reporting success
  # unconditionally would produce a subscription that never delivers, indistinguishable
  # from a quiet market. A caller whose `update_symbols` spans four hundred symbols
  # touches four shards, and dialling all four inline would block the reply behind
  # `@channel_spacing_ms` several times over and risk a connect burst besides.
  #
  # So: the FIRST shard this call actually touches — the lowest index among the ones
  # newly opened or reconciled — runs inline and its outcome is the call's reply, same
  # as the single-socket design this replaces. Every other shard the same call touches
  # is staggered, exactly as a shard opened by a later, separate call would be.
  defp reshard(state) do
    new_shards =
      state.wanted
      |> MapSet.to_list()
      |> shards()
      |> Enum.with_index()
      |> Map.new(fn {symbols, index} -> {index, symbols} end)

    existing_indices = Map.keys(state.shards)
    wanted_indices = Map.keys(new_shards)
    new_indices = Enum.sort(wanted_indices -- existing_indices)

    # A shard whose whole symbol set was just removed disappears from `new_shards`
    # entirely — nothing above asked for any of its symbols any more. That must still
    # reach the venue as an unsubscribe on every symbol the shard was carrying, or the
    # venue keeps streaming them while this package's own bookkeeping has already
    # forgotten it asked to. Folded into `new_shards` as an explicit empty entry so
    # `reconcile_shard/6`'s ordinary removed-symbols path handles it — the same
    # operation, not a special case.
    vanishing_indices = existing_indices -- wanted_indices
    new_shards = Enum.reduce(vanishing_indices, new_shards, &Map.put(&2, &1, []))

    touched_indices =
      (wanted_indices ++ vanishing_indices)
      |> Enum.filter(fn index ->
        index in new_indices or shard_changed?(state, index, new_shards)
      end)
      |> Enum.sort()

    case touched_indices do
      [] ->
        state = drop_unwanted_shards(state, existing_indices, wanted_indices)
        {:ok, state}

      [primary | rest] ->
        {result, state} = touch_shard(state, primary, new_shards, sync: true, delay: 0)

        state =
          rest
          |> Enum.with_index(1)
          |> Enum.reduce(state, fn {index, position}, acc ->
            {_result, acc} =
              touch_shard(acc, index, new_shards,
                sync: false,
                delay: position * @shard_spacing_ms
              )

            acc
          end)

        state = drop_unwanted_shards(state, existing_indices, wanted_indices)
        {result, state}
    end
  end

  defp shard_changed?(state, index, new_shards) do
    case get_in(state.shards[index]) do
      nil -> false
      %{symbols: current} -> current != Map.fetch!(new_shards, index)
    end
  end

  defp drop_unwanted_shards(state, existing_indices, wanted_indices) do
    %{state | shards: Map.drop(state.shards, existing_indices -- wanted_indices)}
  end

  defp touch_shard(state, index, new_shards, sync: sync?, delay: delay) do
    wanted_symbols = Map.fetch!(new_shards, index)

    case get_in(state.shards[index]) do
      nil ->
        open_shard(state, index, wanted_symbols, sync?, delay)

      %{symbols: current, socket: socket} ->
        reconcile_shard(state, index, socket, current, wanted_symbols, sync?, delay)
    end
  end

  defp open_shard(state, index, symbols, true, _delay) do
    case get_socket(state) do
      {:ok, socket, state} ->
        state = put_in(state.shards[index], %{socket: socket, symbols: symbols})
        result = subscribe_first_channel(socket, symbols, state.credentials)
        schedule_remaining_channel_subscribes(socket, symbols, state.credentials)
        {result, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp open_shard(state, index, symbols, false, delay) do
    Process.send_after(self(), {:open_shard, index, symbols}, delay)
    {:ok, state}
  end

  defp reconcile_shard(state, index, socket, current, wanted, true, _delay) do
    added = wanted -- current
    removed = current -- wanted

    result =
      cond do
        not Process.alive?(socket) ->
          :ok

        added != [] ->
          result = subscribe_first_channel(socket, added, state.credentials)
          schedule_remaining_channel_subscribes(socket, added, state.credentials)

          if removed != [],
            do:
              Enum.each(channels_for(state.credentials), &Socket.unsubscribe(socket, &1, removed))

          result

        removed != [] ->
          channels_for(state.credentials)
          |> Enum.map(&Socket.unsubscribe(socket, &1, removed))
          |> List.last()

        true ->
          :ok
      end

    {result, put_in(state.shards[index], %{socket: socket, symbols: wanted})}
  end

  # `delay` staggers this shard's frames past every OTHER shard `reshard/1` is touching in
  # the same call, the same way `open_shard/5`'s async clause already staggers opening a
  # brand-new socket — see `reshard/1`'s "position * @shard_spacing_ms" comment. Before
  # this fix `delay` was computed by `reshard/1` and then silently dropped here: a single
  # `update_symbols/2` that reshuffled several ALREADY-OPEN shards at once scheduled every
  # one of their `level2` subscribes at the same instant regardless. Because `Socket.
  # subscribe/4` blocks THIS process (via `FrameSender`, up to `WebSockex.send_frame/2`'s
  # 5s window) once `attempt_channel_subscribe/6` runs it, several such messages landing on
  # this GenServer's mailbox together serialise into back-to-back blocking sends — a socket
  # answering slowly stalls this shard's own subscribe AND every later one queued behind
  # it in the SAME mailbox, taking `coverage/1`, `subscribe/3` and every other call to this
  # `Feed` down with it for as long as the stall lasts. Staggering by `delay` spreads that
  # risk out exactly as it already is for a newly-opened shard.
  defp reconcile_shard(state, index, socket, current, wanted, false, delay) do
    added = wanted -- current
    removed = current -- wanted

    if removed != [] and Process.alive?(socket) do
      Enum.each(channels_for(state.credentials), fn channel ->
        Process.send_after(self(), {:channel_unsubscribe, socket, channel, removed}, delay)
      end)
    end

    if added != [] and Process.alive?(socket) do
      schedule_channel_subscribes(socket, added, state.credentials, delay)
    end

    {:ok, put_in(state.shards[index], %{socket: socket, symbols: wanted})}
  end

  defp subscribe_first_channel(socket, symbols, credentials) do
    [first | _rest] = channels_for(credentials)
    Socket.subscribe(socket, first, symbols, credentials)
  end

  defp schedule_remaining_channel_subscribes(socket, symbols, credentials) do
    [_first | rest] = channels_for(credentials)

    rest
    |> Enum.with_index(1)
    |> Enum.each(fn {channel, position} ->
      Process.send_after(
        self(),
        {:channel_subscribe, socket, channel, symbols, credentials},
        position * @channel_spacing_ms
      )
    end)
  end

  # `base_delay` lets a caller stagger this shard's whole channel sequence past another
  # shard's — see `reconcile_shard/7`'s async clause. Every existing caller passes none,
  # which is `0` and reproduces the exact scheduling this had before that parameter existed.
  defp schedule_channel_subscribes(socket, symbols, credentials, base_delay \\ 0) do
    credentials
    |> channels_for()
    |> Enum.with_index()
    |> Enum.each(fn {channel, channel_index} ->
      Process.send_after(
        self(),
        {:channel_subscribe, socket, channel, symbols, credentials},
        base_delay + channel_index * @channel_spacing_ms
      )
    end)
  end

  # `level2` requires credentials — see `@authenticated_channels` in `Socket`. A
  # credential-less caller only ever wanted the public `ticker` channel anyway, and
  # sending a doomed `level2` subscribe would either report a `credentials_required`
  # error as this call's synchronous result (masking that `ticker` will work fine) or
  # cost a wire round trip to learn what the credential's absence already answers.
  defp channels_for(nil), do: ["ticker"]
  defp channels_for(_credentials), do: @channels

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
  defp notify_shard_open_failed(state, index, symbols, reason) do
    notice =
      Notice.new(:coverage_change, :coinbase,
        severity: :warning,
        message:
          "shard #{index} (#{length(symbols)} symbol(s)) did not open — " <>
            "staying on the internal poll until the next resubscribe cycle retries it",
        details: %{shard: index, symbol_count: length(symbols), reason: inspect(reason)}
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

  # `Types.Quote` and `Types.OrderBook` both carry `:symbol`; this is the one place
  # coverage tracking needs to be generic over which kind arrived.
  defp delivered_symbol(%{symbol: symbol}), do: symbol

  # The `Core.Types.*` struct names its own kind — never a venue channel name. `Socket`
  # sends exactly these two structs (plus `Notice`, matched in its own `handle_info/2`
  # clause above) into this module, so there is deliberately no catch-all: an unrecognised
  # struct here means a new payload kind was wired into `Socket` without being taught to
  # this function, and failing loudly beats silently mis-tagging its coverage.
  defp payload_kind(%Types.Quote{}), do: :quotes
  defp payload_kind(%Types.OrderBook{}), do: :order_book

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

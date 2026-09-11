# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Status: EXPERIMENTAL

Stated here rather than only per-release, because a reader arriving at a specific version
needs it as much as one reading the top.

This package has not run in production. While it is `0.x` the API may change without a
major version. Coverage is uneven by design: fakes and live public endpoints are well
covered, order placement and authenticated flows are not.

**Whenever an endpoint moves to `:proven`, the entry that does it states the evidence** —
what was run against the live venue, and when. "Marked proven" with no evidence is not an
acceptable changelog line.

## [Unreleased]

## [0.3.10] - 2026-09-11

### Added

- **`check_doc_sources.sh` now checks whether its own manifest is COMPLETE.** Everything it
  did before verified the sources that were listed; nothing verified that the list covered
  what this package's `docs/reference/` actually cites. A checker whose coverage nobody
  audits reports "all sources resolve" while saying nothing about the sources it was never
  told about.

  The gap was real: `dp_exchange_gemini` cited 22 distinct URLs and listed 12, leaving two
  genuine vendor documentation pages — the WebSocket streams introduction that
  `websocket-api-replacement.md` names as its source, and one of the four API specifications
  `endpoint-inventory.md` diffs — unchecked by anything.

  Two classes, reported separately, because only one can be judged mechanically:

  **UNLISTED** — cited on a host the manifest already names as documentation. Same vendor,
  same docs site, different page: near-certainly a source that belongs in the manifest.

  **UNKNOWN** — cited on a host the manifest does not name at all. Deliberately **not**
  assumed to be documentation, because most are not: `api.gemini.com`,
  `api.sandbox.webull.com` and `api.schwabapi.com` are venue APIs, and adding one here would
  put a live venue into a **weekly scheduled fetch**. D7 is explicit that a venue seeing a
  package poll it on a timer will rate-limit or block. These are listed for a person to
  classify and never auto-added.

  Non-blocking, like the rest of the script: it prints and does not change the exit code. An
  unlisted page is a gap in evidence, not a broken build.

- **All three of this package's scheduled checkers were run by hand for the first time, and
  they pass.** Every one of them had never executed: they are scheduled weekly for Monday
  and landed on a Tuesday, so no cron had come around. A checker nobody has watched run is a
  checker nobody has proved works — and running these found the manifest-coverage gap above,
  which is not the defect any of them was written to catch.

  No vendor drift: every cited documentation source resolves exactly as recorded, and the
  committed endpoint inventories match the vendors' current indexes.
## [0.3.9] - 2026-09-11

### Changed

- **CI runs `mix test --cover --warnings-as-errors`.** `mix compile --warnings-as-errors`
  already covered `lib/`, but test files are compiled by `mix test`, which had no such flag
  — so a compile warning in a test file was permanent and green. Together the two now mean
  no warning survives anywhere in the build.

  The argument is not tidiness. A handful of permanent warnings is exactly the noise a
  genuinely wrong one hides behind. The gap was found by running
  `script/check_dependency_floor.sh` by hand — a checker scheduled weekly that had never
  once executed, because it landed on a Tuesday and its cron is Monday — and reading what
  scrolled past. `dp_exchange_core` 0.3.2 fixes five such warnings in the shared conformance
  suite, two of which were real defects that made every venue package noisy.

  Verified by injecting an unused function into a test file and confirming the run aborts: a
  gate nobody has watched fail is a gate nobody has proved.

## [0.3.8] - 2026-09-11

### Changed

- **`dp_exchange_core` floor raised to `~> 0.3.1`.** Core 0.3.0 deleted
  `Core.DataProvider` and `Core.FeedBehaviour` — two contracts with zero implementers, one
  of which was a **second, competing definition of the venue interface** carrying every
  shape this family has since fixed (prices as strings, providers as strings, balances with
  no timestamp, a single quote timestamp, `{:error, String.t()}` flattening the
  refusal/error distinction). A venue author who found it first would have built all of
  those, plausibly, and every one would have compiled.

  **No code changes here**: this package referenced neither module. The floor moves because
  a pin of `~> 0.2.8` would not resolve 0.3.x — the pin doing its job, not a problem to
  route around — and because staying behind would leave this package on a Core that still
  ships the contradicting contract.

  Resolved and compiled against before the pin was written, per the rule this file's own
  dependency comment already records: a floor is only correct once it has been *resolved*,
  never once it has been reasoned about.

## [0.3.7] - 2026-09-11

### Added

- **This package now emits the `[:dp_exchange, :link, …]` telemetry the contract has
  documented since it was written.** `Core.Telemetry` said these are the events "every venue
  package emits"; there was not one `:telemetry.execute/3` call anywhere in the family for
  as long as the spec existed. `:telemetry.attach/4` against a name nobody emits **succeeds**
  — so a consumer wired a dashboard to it, got no error, and saw an empty panel, which reads
  as a venue with no traffic rather than as an unimplemented spec.

  `:link, :up` and `:link, :down` on the connection transitions, and `:link, :event` per
  frame with its wire size. The request and rate-limit events come free with
  `dp_exchange_core` 0.2.8, since every venue's REST goes through `Core.HttpClient` and every
  metered call through `Core.DefaultRateLimiter`.

  **The metrics channel is alongside the notice channel, never instead of it.** A
  `Core.Notice` is a condition a consumer must ACT on; telemetry is aggregate and lossy by
  design. A consumer that alarmed on a telemetry gauge would be acting on a channel
  documented as droppable, and one that graphed notices would be graphing something it is
  meant to handle.

  Two details worth stating, because both are places a plausible-looking number would have
  been wrong:

  A frame is counted **whether or not it parses**. The question the event answers is "is the
  venue sending", and a frame this package could not read is still a frame the venue sent —
  counting only what parsed would make a decoder bug here look like a silent venue.

  There is **no `:link, :reconnect_attempt`** from this package. It reconnects immediately
  and keeps no attempt counter, so the only number it could report is `attempt: 1`, every
  time — which renders a reconnect loop as an endless series of first attempts. That is
  worse than no event. `dp_exchange_schwab` tracks `login_failures` and does emit it.

### Changed

- **`dp_exchange_core` floor raised to `~> 0.2.8`**, which is where `Core.Telemetry`'s
  emitter functions live. A venue calling `:telemetry.execute/3` directly would be naming
  events by hand in five places — five chances to write `:link_up` instead of
  `[:dp_exchange, :link, :up]`, with the drift invisible, since a wrong name emits
  successfully and simply never reaches a handler — and would be using a transitive
  dependency it never declared.

## [0.3.6] - 2026-09-11

### Added

- **Back-pressure: a slow subscriber no longer gets an unbounded mailbox.** `Core.Venue`'s
  `subscribe/2` doc promised this from the day the contract was written, and no venue in
  this family implemented any of it — every one fanned out with a bare `send/2` and had
  never looked at a subscriber's mailbox. A consumer that stalled accumulated a mailbox
  until the node died, with no notice, no log line, and `coverage/1` reporting perfect
  health throughout, because the feed genuinely was delivering.

  Past a bound (default 10,000 queued messages, `:max_queue_len` at start) this feed stops
  sending to that subscriber and emits a `:degraded` notice naming it, the queue length and
  the bound — and a second `severity: :info` notice when it catches up. The pair brackets
  exactly the window a consumer has to reconcile from the pull endpoints.

  Implemented in `dp_exchange_core` 0.2.6 as `Core.Fanout`, shared rather than written five
  times. Three properties worth stating, because they are what make dropping acceptable at
  all: another subscriber that is keeping up is unaffected; `coverage/1` does not change,
  because it reports what the *venue* delivered to this package and not what this package
  forwarded; and **notices are never subject to the bound**, since the notice saying a
  subscriber is being dropped must not be the first casualty of that same subscriber being
  dropped.

  See `usage-rules.md`, "A slow subscriber gets dropped, and told".

### Changed

- **`dp_exchange_core` floor raised to `~> 0.2.6`, and this one is hard.** `Feed` calls
  `Core.Fanout.max_queue_len!/2` at `init/1` and `Core.Fanout.deliver/4` on every payload.
  Against a lower Core this package does not misbehave, it fails to compile — which is the
  good outcome.

- **The pid-or-registered-name subscriber resolution moved to `Core.Fanout.resolve/1`.** All
  five venues had written it identically since DpCryptoManagement's issue #15; the data path
  and the notice path now share one definition, so they cannot drift into disagreeing about
  what counts as a reachable subscriber.

## [0.3.5] - 2026-09-10

## [0.3.4] - 2026-09-10

### Fixed

- **`coverage/1` kept answering `:stream` for symbols the dropped link had been delivering,
  and this package carried the written argument for why that was fine.** `socket.ex` said
  `delivering` is left alone because a symbol that was streaming is "reasonably still
  covered a moment ago" until the resubscribe timer revives it *"or its own staleness ages
  it out of whatever freshness a caller applies downstream"*. That last clause was the one
  holding the argument up, and it was false: `coverage/1` returns `%{symbol() => route()}`
  and exposes no timestamp, so there is no freshness a caller can apply. The comment
  deferred to a mechanism that does not exist.

  Meanwhile `handle_disconnect/2` returns `{:reconnect, state}`, so the socket *process*
  survives a transport drop and no `:EXIT` ever reaches `isolate_crashed_shard/5` — the one
  path that did clear delivery records. A reconnect that restored the socket while the venue
  silently failed to restore some symbols left those symbols reported as `:stream`
  indefinitely: the 325-subscribed/174-delivering incident this callback was written for.

  `Socket` now reports which link dropped — beside the `:link_down` notice, not inside it,
  because a socket pid is this package's wiring and has no business in a `Core.Notice` that
  fans out to consumers — and `Feed` narrows coverage to exactly that shard's symbols and
  that shard's channel's kind. A `level2` drop does not erase a symbol's still-healthy
  `ticker` quote, the same isolation a crash already got. The shard keeps its entry and its
  socket, because that socket is reconnecting rather than dead.

  `dp_exchange_core` 0.2.5 writes the rule into `Core.Venue`'s `coverage/1` doc — observation
  is scoped to the current transport session — and records why it cannot be carried by a
  conformance assertion. All four streaming venues in the family had this wrong in the same
  way and are fixed in the same batch.

- **No published version was attributable to a changelog entry (dp-exchange-core issue
  #32).** Every entry in this repository's `CHANGELOG.md` sat under `## [Unreleased]` — in
  the **published tarball**, since `CHANGELOG.md` ships inside it — so a consumer could not
  tell which version introduced a breaking change, or whether they had already taken one.

  That mapping is load-bearing here rather than cosmetic. This family signals a breaking
  change with a **minor bump**, and those changes are repeatedly a refusal tuple or struct
  gaining a field: invisible to the compiler, and invisible to a test that pins the old
  shape. The reporting consumer's written upgrade procedure is *"read `CHANGELOG.md` for a
  `### Changed — BREAKING` section, then grep for every clause matching the old shape"* —
  which needs version → change. Without it, `### Changed — BREAKING` says *that* the shape
  changed and never whether they already have it.

  They gave two incidents from the same three days, and the difference between them is the
  whole argument: `dp_exchange_gemini` 0.1.42's refusal-shape change was found **after
  shipping**, by reading a fix comment, while `dp_exchange_webull` 0.4.0's was caught
  **before** — because that entry happened to name the version in its prose.

  **Two halves, because fixing only one would have let it recur immediately:**

  - **Going forward**, the release pipeline cuts a `## [x.y.z] - YYYY-MM-DD` heading itself,
    in the publish job and **before `mix hex.publish`** — a heading added after the upload
    would describe a tarball nobody can read.
  - **Retroactively**, the accumulated block now sits under a `## [<version>] and earlier`
    heading. Attributing each of ~1,600 lines to the exact release that carried it is
    archaeology; this restores the one fact a consumer needs from it — that none of it is
    pending — which is what the reporter suggested.

  The issue measured five packages, from their `deps/`. `dp_exchange_schwab` has the same
  defect and is not one of their dependencies, so it could not appear in their table: six
  instances, all fixed here.


## [0.3.3] and earlier - 2026-09-10

**Everything below this line is published.** Entries were accumulated under
`[Unreleased]` from the first release to `0.3.3`, so no reader could tell shipped work
from pending — dp-exchange-core issue #32. Attributing each entry to the exact version
that carried it would be archaeology across hundreds of releases; this heading restores
the one fact a consumer actually needs from it, which is that none of it is pending.

Releases from here on cut their own `## [x.y.z]` heading at publish time, so this is
the last block that will ever need a range.

### Documentation

- **`usage-rules.md` now answers the question a consumer actually has after 0.2.0: when is
  `venue_time` `nil` here?** The migration note said what the fields mean; it did not say
  what this venue does with them, which is the part a caller writes a branch for.

  **Never**, on this venue: every `Quote` and `OrderBook` parses a time the venue sent and
  fails closed when it cannot, so a `nil` branch here is dead code.

### Changed — BREAKING

- **`Core.Types.Quote` and `Core.Types.OrderBook` no longer carry `:timestamp`.** They carry
  **`:venue_time`** (the venue's own, `nil` where the venue publishes none) and
  **`:observed_at`** (when this package read it, always present). Requires
  `dp_exchange_core ~> 0.2.1`; this package's own version takes a minor bump to signal it.

  `:timestamp` was documented as the venue's own and "never invented", and two packages in
  this family could not keep that promise, because the frames they decode carry no venue time
  at all. With one field their only options were to lie or drop real data, and they lied.

  **This venue always had a venue time to give**, on every `Quote` and `OrderBook` it
  builds, so `:venue_time` carries exactly what `:timestamp` did and `:observed_at` is new
  information rather than a replacement. Nothing this package reports became less precise.

  The full reasoning, the three options weighed and the consumer's own argument for this one
  are in `dp_exchange_core`'s
  `docs/design/closed/2026-09-09_venue-time-and-observed-time.md`, announced and answered as
  dp-exchange-core issue #31. `Trade`, `Fill`, `Balance` and `OrderBookDelta` are unchanged.

### Added

- **`:channels` — `level2` can be opted out of (issue #1).** `active_channels/1` hardcoded
  both channels and ignored its argument, so a consumer that reads quotes and routes
  order-book depth over REST had no way to decline the book and paid for it anyway.

  The measured cost, from the consumer who filed it: at 406 pairs and
  `@default_level2_pairs_per_socket` of 30, **14 `level2` sockets** opened and maintained on
  top of the 5 `ticker` shards actually read — and **1,577,001 `OrderBookDelta` frames**
  decoded and delivered in a single boot for a payload with no wired consumer. Ignoring them
  on receipt saved nothing: the sockets were open and the frames were parsed before delivery
  either way.

  ```elixir
  children = [{DpExchange.Coinbase, credentials: creds, channels: [:quotes]}]
  ```

  The vocabulary is `capabilities().streamable`'s data kinds rather than this venue's
  channel strings, because `streamable: [:quotes, :order_book]` is what a consumer reads to
  decide — and it already read as though either could be requested alone. **Omitting the
  option changes nothing**, which is why the whole existing suite passed untouched.

  Two deliberate limits: the option **narrows, never widens** — `level2` is authenticated
  here, so a credential-less feed still carries `ticker` alone whatever it asks for, rather
  than producing a doomed subscribe. And an **empty list is refused at `init/1`**, because a
  feed subscribing to nothing reports permanent zero coverage, which is indistinguishable
  from a venue outage. An unknown kind fails there too, rather than being silently dropped.

### Added

- **`script/check_endpoint_inventory.sh`** — diffs the vendor's published Advanced Trade
  REST endpoint pages against `docs/reference/coinbase/endpoints-enumerated.tsv` weekly,
  via `.github/workflows/inventory-check.yml`. One HTTP request: this venue publishes no
  Advanced Trade specification, but its `sitemap.xml` lists one page per endpoint, so the
  set of those pages *is* the index.

  Deliberately **not** re-deriving the enumerated file. That file's method — reading each
  page's own `pageMetadata.openapi` field — meant fetching 806 pages, which is a reasonable
  thing to do once by hand and a rude thing to do to a vendor every week.

  The mechanism is the one `dp_exchange_core`'s vendor-change design doc settled on: across
  five vendors a *changelog* diff caught nothing and an **index diff** was the only thing
  that ever fired. It has since found a rate-limit table on `developer.webull.com` that had
  existed for weeks behind a five-times-too-permissive ceiling, and a withdrawn WebSocket
  channel on `developer.gemini.com`. Run against this venue it reports **51 endpoint pages,
  unchanged** — a clean baseline, which is the other thing a check is for.

### Documentation

- **"The vendor's rate-limit page could not be located" was a statement about the
  searcher, not the vendor — and it is now corrected with a real search behind it.**
  `capabilities/0`'s ceiling provenance said the page could not be found. That was true of
  three URL guesses and false of Coinbase: `docs.cdp.coinbase.com/sitemap.xml` lists 2,357
  pages, **eleven** of which are rate-limit pages, and they were listed there the whole
  time.

  All **84** Advanced Trade documentation pages were then fetched and searched. **Exactly
  one** carries any rate-limit text: the WebSocket page, at *8 per second per IP* for
  connections and unauthenticated messages alike. So the honest claim is much stronger than
  the old one — **there is no published Advanced Trade REST limit** — and it is the claim
  worth re-testing when the docs change, rather than an admission of not having looked.

  The ceilings themselves are **unchanged and still rank 3**: inherited from the prior
  adapter, not doc-derived (there is no document) and not measured (measuring a rate
  ceiling means deliberately exceeding a third party's). New reference file
  `docs/reference/coinbase/rest-rate-limits.md` records the method and the negative result
  so the next reader can re-run it rather than re-guess it.

  **Why this was worth doing at all**: the identical sitemap search on
  `developer.webull.com` found a per-endpoint rate-limit table that had existed for weeks
  while this family declared a ceiling five times too permissive there, on a venue whose
  documented penalty is a temporary IP block. "We could not find it" earns a second look.

- **The 8-per-second-per-IP figure is now cited by URL and watched.** It is load-bearing —
  `Feed`'s `@shard_spacing_floor_ms` of 125 ms is derived straight from it — and it now
  names the page it comes from and has a row in `doc-sources.tsv`, so a change to it is
  caught by the weekly check rather than by someone re-reading the comment.

### Fixed

- **Reads now carry `@call_timeout` explicitly, exactly as writes already did.** `coverage/1`,
  `coverage_by_kind/1`, `status/1` and `wanted/1` took `GenServer.call/2`'s implicit five
  seconds while every write named a generous one — the same asymmetry that turned a bounded
  delay into a dead caller in issue #28. Second line of defence, never the fix: a read that
  has to queue behind something should wait for it, not die of it.

- **The alias-catalogue fetch blocked every read on this Feed — dp-exchange-core issue
  #28's failure, on this venue.** `handle_info(:fetch_alias_map, …)` read the venue's whole
  `/market/products` catalogue over HTTP **inline**, and with `Core.HttpClient`'s documented
  defaults (30_000 ms per attempt, 3 attempts) that blocked this GenServer for up to about
  **ninety seconds**. `coverage/1` and `coverage_by_kind/1` are plain `GenServer.call/2`s on
  the five-second default, so a health check landing during the fetch did not wait, it
  **exited**, taking a consumer that reads it from its own `handle_call/3` with it.

  **Found by sweeping for the class rather than by it failing here** — the #30 reporter
  named the shape ("work done in the process that owes a reply") while describing something
  else, and this family has paid for it three times already (#16, #23, #28).

  The fetch now runs in a task and its result arrives as a message. A second
  `:fetch_alias_map` tick while one is in flight is dropped rather than starting a second
  catalogue read: two would race to write `state.alias_map`, with the loser silently
  overwriting the winner, and would double a request this venue's limiter is sized for one
  of. Exceptions are converted inside the task, because `Task.async/1` links and an
  unconverted raise would arrive as an `{:EXIT, …}` with no clause for it — leaving the
  in-flight marker pinned and every later tick dropped forever.

### Documentation

- **`Credentials`' moduledoc now says that the redaction wrap lives in `child_spec/1`, and
  that bypassing `child_spec/1` bypasses it.** Requested by the consumer who verified the
  dp-exchange-core #29 fix and then went looking for their canary in their own supervisor's
  state — and found it. Their supervision code builds the child spec itself
  (`start: {__MODULE__, :start_feed, [module, opts, pairs]}`) for a legitimate reason: a
  `Core.PollingFeed`-shaped facade defaults `subscriber` to `self()`, which resolves to the
  *supervisor* when `start_link/1` is called from `init/1`, so a different delivery target
  can only be set at `start_link` time. On that path `child_spec/1` never runs, their
  supervisor stores the raw map, and OTP renders the live key on the next crash exactly as
  before. **Upgrading does not fix it, because nothing from this package is on that path.**

  No code change: `wrap/1` and `wrap_opt/1` were already public, which was all that path
  needed. What was missing was anyone saying so — the natural assumption, "upgraded,
  therefore redacted", is wrong there, and assertion 22 cannot see it because it asks about
  `child_spec/1`'s own rendering. `dp_exchange_core`'s `usage-rules/auth.md` carries the
  full version, including the reshaping case that bit them: a host mapping its own key
  names into a venue's and returning a bare map re-introduces the leak in its own code,
  downstream of anything a package can reach.

### Fixed

- **Credentials were written to the log in cleartext by any crash — dp-exchange-core issue
  #29.** A supervisor stores the `{module, :start_link, [opts]}` MFA its child spec names,
  and OTP writes that argument list through `inspect/1` into the `Start Call:` line of the
  report it logs on **any** child termination. `:credentials` arrived as a plain map, so
  every crash printed the live secret in full. It needs no unusual conditions, it lands in
  ordinary application logs — the artifact most likely to be shipped to an aggregator or
  attached to a bug report — and it defeats credential hygiene upstream of it: a consumer
  can hold the key encrypted at rest and still have it written out in the clear. The
  reporting consumer found live keys this way and nearly pasted them into a GitHub issue
  while reporting a different bug.

  `child_spec/1` now wraps `:credentials` with `DpExchange.Coinbase.Credentials.wrap_opt/1`, and
  **the placement is the fix**: wrapping in `start_link/1` or `init/1` does nothing,
  because by then the supervisor above has already captured the raw list. Redacting the
  value rather than setting the `:sensitive` process flag is deliberate — that flag
  suppresses the whole report, including the stack trace that made the unrelated bug
  diagnosable. This keeps the report and removes only the secret. `dp_exchange_core`'s
  conformance suite gains **assertion 22** for exactly this, so it cannot come back here or
  arrive in a new venue.

### Added

- **`script/check_doc_sources.sh` and `docs/reference/coinbase/doc-sources.tsv`** — a weekly,
  non-blocking check that every vendor documentation page this package cites still resolves
  the way it did when a person read it. It records status and redirect destination and does
  **not** follow redirects or diff content: a permanent redirect is itself the change notice
  (this family lost a streaming API to one, announced by nothing else), while content
  diffing a rendered docs site would be red every week for reasons that are never the reason
  we care about. Built after auditing what would have caught each way five vendors'
  documentation turned out to be wrong — across that whole sample a *changelog* diff caught
  nothing, and an *index* diff was the only mechanism that ever fired. It earned itself
  immediately: on its first run in `dp_exchange_webull` it caught a cited page that 404s, and
  pulling that thread found a rate ceiling five times too permissive against that venue's own
  per-endpoint table. Scheduled Mondays 09:20 UTC via
  `.github/workflows/doc-sources-check.yml`, never on push, never in the publish chain.
  Documentation sites only — never a venue API, which tier 2's never-on-a-schedule rule
  still forbids.

  Three pages are tracked here, including the candles endpoint behind the `FOUR_HOUR`
  incident — a width the venue served and the adapter silently substituted `1h` for.

### Changed

- **`@default_shard_spacing_ms`: `5_000` → `1_000` — closes
  `docs/design/ideas/shard-spacing-headroom.md`, moved to
  `docs/design/closed/2026-09-09_shard-spacing-headroom.md` with this outcome.** The old
  value was inherited, unexamined, from the reference fix this package replaced — never
  derived from anything about this venue, the same way `@pairs_per_socket` (100) still is.
  Coinbase's own Advanced Trade rate-limits page documents WebSocket connections at 8 per
  second per IP, converting directly to a floor of `ceil(1_000 / 8)` = `125`ms; `5_000`ms
  was roughly forty times more conservative than that floor required.

  `1_000`ms is one connection per second — an 8x margin under the documented floor, not the
  floor itself (`500`ms, a 4x margin, was also considered and set aside for the larger
  one). The extra margin beyond the documented rate alone is deliberate: Webull's shards
  crash-looped this same week once abandoned sessions accumulated against an undocumented
  five-connection ceiling on that venue, and Coinbase documents a rate, not a concurrency
  cap — no concurrency cap is documented for it either, but "no documented cap" is not "no
  cap." At `1_000`ms, only a handful of this module's own connects are ever simultaneously
  mid-handshake for the 406-symbol/19-shard scope `feed.ex`'s own moduledoc discusses,
  against roughly two dozen that would be in flight at once at the bare `125`ms floor.
  Reasoned entirely from Coinbase's own documented rate-limits page — no live probe was
  run, per this repo's own testing-tier rules for a pure connect-rate number that already
  converts to an exact floor with nothing left to bisect.

  All four call sites that read `shard_spacing_ms` were traced before choosing: the
  initial connect stagger and `retry_missing_shards/1`'s reopen stagger both open
  brand-new sockets, a direct fit for the documented floor; the unconditional 60-second
  resubscribe walk staggers frames onto already-open sockets, kept on the same number both
  because Coinbase's own rate-limits page states its 8/second/IP ceiling covers connects
  and messages together and because `Socket.subscribe/4` blocks the `Feed` `GenServer`
  regardless of what the venue does with the frame; `next_resubscribe_delay/1` is a
  derived floor that has to track whatever the resubscribe walk actually uses. One number
  continues to do all four jobs — see `feed.ex`'s own moduledoc, "one spacing, several
  jobs," for the full reasoning kept alongside the code.

  For the 406-symbol scope, boot-to-full-`level2`-coverage drops from 90 seconds at the
  old default to 18 seconds at this one (a fivefold improvement — the 90-second figure
  itself corrects an earlier moduledoc approximation, `(14 - 1) * shard_spacing_ms`, that
  omitted the 5 `ticker` shards staggered ahead of `level2` in the same sequence; the true
  span is `(shard_count - 1) * shard_spacing_ms` over all 19 touched shards, verified
  against `reshard/1`'s actual position math). **This is a behaviour change for any
  consumer that has not set `shard_spacing_ms` explicitly**: this feed now reaches full
  coverage noticeably faster after boot and after any event that reopens shards. Pass
  `shard_spacing_ms: 5_000` to keep the old, more conservative pacing.

### Fixed

- **`Auth.jwt/2`'s two-minute CDP token expiry (`now + 120`) had no citation anywhere** —
  correct, but unlabelled, in a file where every other numeric venue claim carries one.
  Found by a family-wide sweep for the `@pairs_per_socket`/`@shard_spacing_ms` defect
  class this package's own `Feed` moduledoc already documents. Coinbase's own JWT
  Authentication page states "your JWT is only valid for a period of 2 minutes," and
  separately that this is the SDK samples' *default* rather than a server-enforced
  ceiling — now `docs/reference/coinbase/jwt-auth.md`, cited from `Auth`'s own `@doc`.
  No value changed.

- **BREAKING: `capabilities/0` declared `has_staking: false` (the default — the field was
  never set) while `stake/3` and `unstake/3` were already `:experimental` and genuinely
  reach Coinbase Prime.** Found by `dp_exchange_core`'s conformance-coverage audit, which
  added a cross-check (`Capabilities.new/1`, assertion 2 in the shared suite) requiring
  `has_staking` to agree with the six staking endpoints it summarises — the same rule
  already applied to `supports_order_preview`/`supports_order_replace`. Against Core
  0.1.71 this package's own contract suite failed 23 of 42 tests, every one of them the
  same `ArgumentError` raised inside `capabilities/0` itself, not 23 independent defects.
  Confirmed rather than assumed which side was wrong: `DpExchange.Coinbase.Prime`'s nine
  endpoints are real paths against `api.prime.coinbase.com`, signed with Prime's own HMAC
  scheme, reached from `stake/3`, `unstake/3` and this module's own
  `query_transaction_validators/3`, `claim_rewards/4`, `staking_status/4`,
  `unstake_status/4` and `preview_unstake_wallet/6` — not documentation describing a
  capability nobody wired up. `has_staking` is now `true`, at the same `:experimental`
  maturity as the rest of this `:0.x` package: the paths are read from Prime's own
  documentation, not probed live — this repository holds no Prime credential, and D7 tier
  4 (money-moving) is answered in production by a consumer, never by a test here.
  `measured_against` says so explicitly. **This is a behaviour change for a consumer
  routing on `has_staking`**: it used to read `false` and now reads `true`, honestly,
  for a venue that has always been able to move money into and out of a staked position
  through this package. `get_staking_rates/1`, `get_staking_balances/1`,
  `get_staking_rewards/1` and `get_staking_history/1` stay `:unsupported` in
  `venue_does_not_serve/0` — that reasoning is about their own shape (no published rate
  schedule, a status endpoint naming one wallet rather than every position, a rewards
  claim being a write not a report, no history endpoint at either scope) and `has_staking`
  becoming `true` does not reopen it. The same defect class already fixed in
  `dp_exchange_gemini` (`has_staking: false`/`supports_margin: false` beside six staking
  and three margin endpoints already `:experimental`).

- **BREAKING: three defects in `level2`'s unsubscribe-before-subscribe reconcile, all
  found by re-tracing the mechanism as a whole rather than as the sequence of fixes that
  built it, none caught by the existing suite.** (1) A vanishing shard's stranded
  unsubscribe could be recorded and discarded in the same `reshard/1` call —
  `drop_unwanted_shards/3` dropped `state.pending_unsubscribes[key]` unconditionally for
  every shard no longer wanted, including one `strand_unsubscribe/7` had just populated
  moments earlier, or one an in-flight deferred reconcile would populate a moment later —
  silently contradicting the notice text's own promise that it would be "picked back up
  on the next unconditional resubscribe cycle." (2) An ORDINARY reconcile
  (`subscribe/2`, `unsubscribe/2`, `update_symbols/2`) never consulted
  `state.pending_unsubscribes` at all — only the 60-second `:resubscribe` tick did — so a
  shard carrying one unconfirmed release could accept a plain additive subscribe for an
  unrelated new symbol on the very next ordinary call, the "quiet overflow"
  DpCryptoManagement's own probe 2 describes, reached through the path this whole design
  exists to close. (3) `isolate_crashed_shard/5`'s reopen and an ordinary reconcile's own
  recovery of the same now-missing shard key could race: the deferred
  `{:open_shard, _, _}` handler always opened a fresh socket unconditionally, so whichever
  attempt's `put_in` ran last won `state.shards[key]`'s slot and the other's socket —
  still alive, still linked, still holding a live venue subscription — was leaked, never
  referenced by this module again. `drop_unwanted_shards/4` now only drops a vanishing
  shard whose release is confirmed clear; `reconcile_shard_in_place/8` folds
  `pending_unsubscribes` into what it treats as "current" on every reconcile, not only the
  60-second cycle; `handle_info({:open_shard, _, _}, _)` now no-ops if the key already
  exists rather than opening a second socket. Breaking in the narrow sense that a shard
  whose vanishing release is still pending, or whose newly-added symbol was withheld
  behind one, now behaves differently (correctly) than before — no public API changed.

- **A crash of `Feed` or `Socket` printed the CDP `api_key`/`api_secret` pair in
  cleartext, in OTP's own crash report.** Both processes hold `:credentials` for their
  entire lifetime — `Feed` to keep resharding and resubscribing, `Socket` to sign every
  authenticated `subscribe/4` — and both stored it as a bare map field in `GenServer`/
  `WebSockex` state. OTP's default crash report prints a process's state in full on
  termination; a plain map prints every key it holds, secrets included. Verified by
  crashing an equivalent process holding `%{api_key: "...", api_secret: "..."}` as a bare
  state field and reading the resulting log line back — the key pair came back in
  cleartext. `Process.flag(:sensitive, true)` was tried as an alternative and does not
  help: the same crash, with the flag set, printed the same cleartext state; it disables
  tracing, not crash-report formatting. Now both processes wrap the pair in
  `DpExchange.Coinbase.Credentials`, a struct whose `Inspect` is derived with `except:`
  naming both fields, at the point credentials enter state — nowhere else in either
  module changes, because a struct is a map and `Auth.jwt/2`'s
  `%{api_key: k, api_secret: s} = credentials` still binds the real values inside the one
  function that has to sign with them. Re-verified against a real crash of the new shape:
  the log line now reads `credentials: #DpExchange.Coinbase.Credentials<...>`. See
  `Credentials`'s moduledoc for the full mechanism, including why it also closes a second
  leak (a `FunctionClauseError`'s printed argument list goes through the same `Inspect`
  protocol as a crash report's state).

- **A shard's socket crashing took the whole `Feed` down with it, silently discarding
  every subscription this feed had ever been given.** `Socket.start_link/1` runs inside
  `Feed`'s own `handle_call`/`handle_info` (`get_socket/1`), which links every shard's
  socket to `Feed` the way `start_link` always does. `Feed` never called
  `Process.flag(:trap_exit, true)`, so an abnormal socket exit — a decode bug raising
  inside a WebSockex callback, or anything else that kills the socket pid — sent an
  untrappable `EXIT` signal along that link and crashed `Feed` too. `DpExchange.
  Coinbase.Supervisor` then restarted `Feed` from the *static* `opts` it was given at
  tree-start, which never carry a consumer's later `subscribe/2` calls: one shard's bug
  cost every symbol this feed was ever asked for, not just the shard that broke. Found by
  a 2026-09-07 supervision audit — proven by linking a real process into a running `Feed`
  the way `get_socket/1` does and killing it with `Process.exit(pid, :kill)` (not
  `:normal`, which a non-trapping process ignores), which crashed `Feed` before this fix
  and does not after.

  `Feed` now traps exits and isolates a crashed socket to the one shard it belonged to:
  only that shard's symbols lose coverage, only the `data_kind()` that shard's channel
  carries is cleared from `coverage/1`/`coverage_by_kind/1` (a `level2` crash no longer
  erases a symbol's still-healthy `ticker` quote), a `:link_down` `Core.Notice` reports
  the crash, and the shard reopens immediately rather than waiting out the next
  `:resubscribe` tick (up to 60s by default). Every other shard, on other sockets, is
  untouched.

- **BREAKING: `supported_order_types` and `supported_time_in_force` were both `[]` while
  `{:place_order, 3}` is `:experimental` and `Rest.order_configuration/1`'s own
  `@configurations` cross-product builds three order types across four time-in-force
  values.** `Capabilities.new/1` validates the *contents* of these lists but never that a
  venue with an active `place_order/3` declared anything, so two empty lists passed every
  check. Now `supported_order_types: [:market, :limit, :stop_limit]` and
  `supported_time_in_force: [:ioc, :fok, :gtc, :gtd]` — read directly off
  `@configurations`, not invented. `:stop` and `:post_only` are deliberately absent:
  the venue's cross-product has no `:stop` entry (only `:stop_limit`) and Advanced Trade's
  order endpoint has no post-only flag. Found by a cross-package audit;
  `dp_exchange_robinhood` defaulted the same two fields the same way for the same reason.

- **`child_spec/1` did not declare `type: :supervisor`, so OTP defaulted it to `:worker`**
  — which also defaults `:shutdown` to `5_000`ms instead of `:infinity`. A consumer
  terminating this child gave the whole nested tree (socket shards, rate limiter, and
  everything under them) only five seconds to shut down gracefully before `:kill`, rather
  than letting it unwind on its own terms. Invisible to any single-package review, and
  found only by diffing `child_spec/1` across all five venue packages against each other;
  `dp_exchange_schwab` was the only one that already declared it.

- **`get_top_of_book/2` answered a missing local credential with `{:refused, :missing_credentials}`** — in the real `Rest` client and in `Fake` alike — even though the credential never left this process and nothing at Coinbase ever saw a request to decline. `DpExchange.Core.Venue`'s own moduledoc reserves `:refused` for the venue's own permanent word about a request it actually received; a locally-detected precondition is an `:error`. Found by a cross-package audit: Gemini, Robinhood and Schwab's real facades already used `{:error, {:missing_credentials, venue}}` for this exact condition — this package and Schwab's `Fake` (see that package's own changelog) were the two hold-outs. Now `{:error, {:missing_credentials, :coinbase}}`, matching the rest of the family.

- **A credential that could not sign produced an unauthenticated request that was actually
  sent — on write endpoints, `place_order/3` included.** `Auth.rest_headers/4` was written
  as `Core.HttpClient`'s 4-arity auth hook, which may only return a header list and has no
  way to say "abort, do not send". So on a signing failure it returned the content-type
  header alone and documented that "the caller decides whether an unauthenticated request
  is acceptable". **No caller ever decided**: `Rest.request/5` and `Rest.json_request/5`
  both handed the result straight to `HttpClient.request/5` without checking whether an
  `Authorization` header came back.

  For a public market-data `GET` that was harmless — Coinbase serves those anonymously.
  For `json_request/5` there is no public path: every caller of it is a write, so a
  malformed `api_secret` turned a live order into an unauthenticated POST that the venue
  answered with an opaque `401`, which reads as a credential problem *at Coinbase* rather
  than a malformed key here. That is precisely the failure the function's own moduledoc
  existed to prevent, produced by the mechanism documenting it.

  `Auth.rest_headers/4` now returns `{:ok, headers} | {:error, reason}` and both request
  paths gate on it with `with`, the way every other venue package in this family already
  gated on its own `Auth.headers`. The `nil`-credentials branch is unchanged and is not
  this case: a call made deliberately without credentials still takes the public path.

  The test suite was green throughout, because the fixtures used an `api_secret` of
  `"-----BEGIN EC PRIVATE KEY-----"` — unparseable, and therefore never signing anything.
  Every fixture now carries a real 32-byte Ed25519 seed, so the suite exercises the
  signing path it was previously bypassing.

- **`Auth.jwt/2` raised `KeyError` on credentials it could not read**, rather than
  refusing by name. It read `credentials.api_key` unconditionally, so `nil`, `%{}` or a
  map assembled with a typo'd key crashed inside signing — reachable from every write
  endpoint through `Rest.json_request/5`, which carries no `nil` guard of its own, and
  from `Feed`'s unattended alias-map fetch. It now answers
  `{:error, {:missing_credentials, :coinbase}}`, the shape the other four venue packages
  in this family return for the same condition.

- **4xx statuses were recovered by searching the error message for `"404"`**, which was
  wrong in both directions. `Core.HttpClient`'s own moduledoc names that exact expression
  as the reason its `raw_status: true` option exists:

  - **False positive** — any 4xx whose *body* contained `"404"` (an order id, a price, an
    embedded vendor code) became `{:refused, :not_listed}`: permanent, never retried, for
    something that may have been transient.
  - **False negative** — a `400`, `401` or `403` contains no `"404"`, so a bad request or
    a **rejected credential** fell through to `{:error, message}` and read as
    possibly-transient. A rotated key was retried instead of refused.

  `Rest` now passes `raw_status: true` and matches the status exactly, as the other four
  venue packages already did. `404` remains `{:refused, :not_listed}`; `400`/`401`/`403`
  are now `{:refused, {:venue_error, status, message}}` carrying the venue's own words.

  One existing test asserted `{:error, _}` for a rejected credential while its own name —
  and `test_connection/2`'s moduledoc — both said refusal. Both were right; the assertion
  was pinning the bug.

### Changed

- **`capabilities/0` now declares `authenticated_streamable: [:order_book]`.** It was left
  at its `[]` default, which reads as "no streamed kind here needs a credential". That is
  not true: `Socket`'s `@authenticated_channels` names `level2`, and `Feed` subscribes
  `["ticker"]` without credentials and `["ticker", "level2"]` with them — so an anonymous
  consumer gets quotes and no book. A host asking whether it needed a credential before it
  could stream book data was told no, and would have learned otherwise from a book stream
  that never arrived.

### Added

- **`level2_pairs_per_socket` is now a supervision option**, not only the internal
  `@default_level2_pairs_per_socket` constant it defaults to:

  ```elixir
  children = [{DpExchange.Coinbase, credentials: my_credentials(), level2_pairs_per_socket: 25}]
  ```

  Default is unchanged — **30**, DpCryptoManagement's own live bisection against the real
  venue on 2026-09-06 (`n = 6/12/25/30` accepted, `n = 31/35/50/100` refused; adopted as
  the constant in `9139881`) — the measurement is not being re-opened, only made
  adjustable. A value below `1`, or a non-integer, fails `Feed.start_link/1` at start with
  an `ArgumentError` rather than being coerced. A value above `30` is honoured, not
  capped — with a `Logger.warning` naming the measured ceiling, its date, and the concrete
  risk: an oversized `level2` subscribe is refused by the venue WHOLESALE, losing that
  shard's entire coverage — and the socket SURVIVES the refusal (measured 2026-09-07, see
  the "corrected claim" entry below), which makes it quieter than a disconnect, not
  louder: no link-down, no reconnect, just a shard that silently never delivers.
  Capping it would have quietly defeated the option's own purpose, which is letting a
  consumer absorb a venue-side ceiling change without a package release; this repo has no
  way to verify such a change itself (tier-3, authenticated, live probing is out of scope
  for this repo — see the testing strategy). The default is deliberately **not** shrunk
  for headroom: `30` is the actual, located boundary, not a value merely bounded from
  below, and a consumer wanting margin below it can pass a smaller value themselves.
  `ticker`'s own 100-per-socket size gets no equivalent option — it has no known ceiling
  to tune against. See `feed.ex`'s own moduledoc, `"level2_pairs_per_socket — a
  supervision option"`, and `usage-rules.md` for the full reasoning
  (`DistortionPoint/dp-exchange-core` issue #22).

- **`shard_spacing_ms` is now a supervision option**, not only the internal
  `@default_shard_spacing_ms` constant it defaults to — the delay between opening each
  successive shard's socket, whichever channel it carries, and the same delay
  `reconcile_shard/7` now applies when reconciling several already-open shards in one
  `update_symbols/2` call:

  ```elixir
  children = [{DpExchange.Coinbase, credentials: my_credentials(), shard_spacing_ms: 1_000}]
  ```

  Default is unchanged — **5,000ms**, inherited from the reference fix this package
  replaced, the same way `@pairs_per_socket` (100) is. A negative value, or a
  non-integer, fails `Feed.start_link/1` at start with an `ArgumentError`, the same shape
  as `level2_pairs_per_socket`; `0` is NOT refused — `Process.send_after/3` accepts it
  without complaint, so there is nothing mathematically broken about it, only extreme (a
  connect burst, the exact hazard this whole file otherwise staggers to avoid).

  Coinbase's own Advanced Trade rate-limits page states WebSocket connections are limited
  to 8 per second per IP, which converts directly into a floor of `125`ms
  (`ceil(1_000 / 8)`) on this package's own connects. A value below that floor is
  honoured, not refused — this package cannot verify whether a faster pace is safe for a
  given consumer's own network position — but it logs a `Logger.warning` naming the
  documented floor, its source, and the concrete risk: connects tighter than the venue's
  own stated per-IP rate risk the connect-burst resets this package's own moduledoc opens
  with. See `feed.ex`'s own moduledoc, `"shard_spacing_ms — a supervision option"`, for
  the full reasoning, including why the 5,000ms default is left unmoved here even though
  it is roughly forty times more conservative than the documented floor requires
  (`docs/design/ideas/shard-spacing-headroom.md` records that as a non-blocking
  discovery, not acted on).

  This option exists first for this package's own test suite: five sharding tests in
  `feed_test.exs` existed to prove staggering happened and could previously only do that
  by waiting out the real production delay — 45 of the suite's roughly 51 seconds, across
  five tests. They now inject a small value and prove the same relative ordering and that
  a real delay was applied, rather than sleeping through the production default.

### Changed

- **BREAKING: `Socket` no longer maintains a `level2` order book. An `update` frame now
  delivers `dp_exchange_core`'s new `Types.OrderBookDelta`, not a full `Types.OrderBook`.**
  A consumer that used to receive a rebuilt `Types.OrderBook` on every `l2_data` frame —
  including a single-row `update` — now receives a `Types.OrderBook` only on `snapshot`
  (once per subscribe/resubscribe) and a `Types.OrderBookDelta` on every `update`: the
  venue's own changed rows, in the venue's own order, both sides interleaved exactly as
  the frame carried them, in a flat `levels :: [{side, price, quantity}]` list rather
  than split into `bid_levels`/`ask_levels`. **A consumer wanting a maintained book now
  builds and holds it itself.** This is not presented as a performance improvement — it
  is the removal of state this package was never supposed to hold. See
  `dp_exchange_core`'s `docs/design/closed/2026-09-06_stop-maintaining-books-in-packages.md`.

  **Why:** holding the book cost 65–110 ms per delta at the book size DpCryptoManagement
  measured live for `BTC-USD` (~22,800 bid / ~21,100 ask levels, issue #22), later
  optimised to ~6.6 ms — but that work ran on the same single-threaded process
  responsible for `WebSockex.send_frame/2`, so a socket busy rebuilding a book it was
  never asked to keep could not service its own sends, which is the `:send_timeout`
  behind issue #22. Maintaining state this package was not supposed to hold is what broke
  the connections it was supposed to keep; this change removes the work rather than
  making it faster a second time.

  **A `quantity` of zero still means the level ceased to exist, not a price of zero** —
  carried through completely unresolved now, since resolving it would itself be
  state-keeping.

  **Reconnect reconciliation is now the consumer's job, not this package's.** A dropped
  and resumed connection does not promise the deltas after it are contiguous with the
  deltas before it. `subscribe_notices/1`'s existing `:link_down`/`:link_up` pair
  brackets where a gap may fall; neither that notice nor anything else reconstructs a
  missing delta. The correct response to `:link_up` is to re-pull `get_order_book/2`
  (unaffected by this change) or accept the venue's own fresh `snapshot` on resubscribe —
  not to keep applying deltas across a gap. Coinbase's `level2` channel publishes no book
  sequence number, so `:sequence` on both types is always `nil` here.

  `Socket`'s `books` state, `apply_book_event/3`, `apply_book_row/2`, `update_level/4`,
  `remove_level/3`, `deliver_book/3` and `price_key/1` are all gone, along with
  `bench/order_book_resort.exs`, which benchmarked work that no longer exists.
  `Feed.payload_kind/1` now maps `%Types.OrderBookDelta{}` to `:order_book`, the same
  `data_kind()` a full `%Types.OrderBook{}` gets — `coverage_by_kind/1` answers "is book
  data arriving", not "in what shape", and the struct type itself already tells a caller
  which shape it is holding.

  **Also dropped, deliberately, as part of the same change:** the exact-scaled-integer
  precision check `price_key/1` used to enforce (refusing a price with more than 8
  decimal digits) existed only to support the `:gb_trees` ordering key that mechanism
  needed — it was never an independent business rule. Sorting a snapshot's own rows via
  `Decimal.compare/2` needs no such key and has no rounding step to guard against, so a
  price at any precision the venue sends now passes through unchanged, the same as every
  other decimal field this module decodes. Likewise, two numerically-equal,
  differently-scaled prices in one snapshot (`"1.5"` and `"1.50"`) are no longer folded
  into one last-write-wins level — that folding was an accidental side effect of the old
  map-keyed implementation's own key, never a documented venue behaviour (unlike the
  8-decimal `quote_increment` finding, this had no live measurement behind it), and
  silently choosing a winner between two rows is itself the kind of substitution this
  family refuses. Both rows now pass through as the venue sent them.

### Added

- **Five of Coinbase Prime's nine staking endpoints are now reachable from the facade
  — `dp_exchange_core`'s new "internal wiring" conformance assertion (assertion 16)
  caught them as built and never called from this package's own `lib/`.**
  `DpExchange.Coinbase.query_transaction_validators/3`, `staking_status/4`,
  `unstake_status/4`, `claim_rewards/4` and `preview_unstake_wallet/6` now delegate
  straight to the matching `DpExchange.Coinbase.Prime` function, the same pattern
  `stake/3` and `unstake/3` already used for the other four. None of these map onto a
  `dp_exchange_core.Venue` callback — `staking_status` answers a narrower question than
  `get_staking_balances/1` would, `claim_rewards` is a write where that callback wants a
  read, and `query_transaction_validators`/`preview_unstake_wallet` have no generic
  analogue at all — so they are Coinbase-specific facade functions, the same shape as
  the existing futures and portfolio extras (`list_futures_positions/1`,
  `get_portfolio_breakdown/3`, and friends). `venue_does_not_serve/0`'s own
  documentation already claimed these were "reachable as `Prime.X`"; that claim is now
  true through the facade as well, not only by reaching past it into an internal module.

- **`coverage_by_kind/1` implemented — Coinbase is the motivating case for
  `dp_exchange_core` 0.1.48's new optional callback.** `coverage/1` answers "is
  anything arriving for this symbol" by counting any payload at all, so a `level2`
  book update counted identically to a `ticker` quote. That blindness is not
  hypothetical: `level2` delivered upward of 11,000 frames across 406 subscribed
  symbols while `ticker` stayed dark on all but a handful, and `coverage/1` still
  answered `:stream` for all 406 — correct by its own definition, and exactly why
  DpCryptoManagement's issues #20 and #22 stayed unpinned for days.

  `Feed`'s `delivering` map now tracks `%{symbol => %{kind => timestamp}}` instead of a
  bare timestamp, keyed off which `Core.Types` struct actually arrived
  (`%Types.Quote{}` → `:quotes`, `%Types.OrderBook{}` → `:order_book`) — never off this
  venue's own channel names, which stay internal. `coverage_by_kind/1` on
  `DpExchange.Coinbase` and `DpExchange.Coinbase.Fake` both satisfy the union
  invariant `dp_exchange_core`'s conformance suite now checks whenever a venue exports
  this callback: the symbol keys across every kind exactly match `coverage/1`'s own
  keys, and every kind reported is one `capabilities().streamable` declares. The fake
  reports everything under `:quotes` only, honestly — `subscribe/2` never synthesises
  an order book, and claiming `:order_book` coverage it cannot back would be the
  "differently capable" divergence this fake's own moduledoc forbids.

  Bumped `dp_exchange_core` from `~> 0.1.36` to `~> 0.1.48` to pick up the callback.

- **`Fake` wired to `Core.FakeInjection` — DpCryptoManagement's issue #14.** Every
  function with a real success path (not an unconditional `Venue.not_supported()`) now
  checks a queued or always-set outcome first: `get_price/2`, `get_top_of_book/2`,
  `get_historical_prices/4`, `get_order_book/2`, `get_trades/2`, `quantization/1` and
  `close_position/3` support per-symbol targeting; every other real function (bulk
  reads, account/portfolio/conversion calls, order placement, cancel/get/list, previews
  and edits) supports whole-call injection. `subscribe/2`, `unsubscribe/2` and
  `update_symbols/2` are deliberately not wired — each takes a symbol list in one call,
  which whole-call injection cannot express partial failure for; neither is `coverage/1`
  or `subscribe_notices/1`, both local bookkeeping that always succeeds by construction.

  **No credential-bypass mode here.** Unlike `DpExchange.Robinhood.Fake` (the reference
  implementation), this fake has no central credential check to bypass — most functions
  never inspect `credentials` at all, an existing gap this wiring does not change.
  See `docs/design/2026-09-04_webull-sharding-and-fake-injection.md` §3.6/§3.7 in
  `dp-exchange-core`.

- **`get_market_overview/1` and `list_instruments/1` are implemented —
  DpCryptoManagement's issue #10.** Both sat behind `Venue.not_supported()`, one filed as
  a genuine venue absence (`@venue_does_not_serve`) with no per-item comment explaining
  why, against `get_symbols/1` already calling the exact bulk endpoint
  (`/products`/`/market/products`) that carries all of it. Live-verified: the response
  Coinbase actually returns names `price`, `price_percentage_change_24h`, `volume_24h`,
  `high_24h`, `low_24h`, `status` and `product_type` per product, and `get_symbols/1` kept
  only `product_id`. Both new functions read the same response `get_symbols/1` already
  fetches — via a shared `fetch_products/1` — rather than a second request.

### Removed

- **`Feed.pairs_per_socket/0` and `SymbolFormat.mapping/0` deleted — both were public
  getters over a module attribute with no caller anywhere in this package's own `lib/`,
  the other shape
  assertion 16 exists to catch.** `Feed`'s own moduledoc already says sharding details
  "never reach the facade" — `@pairs_per_socket` is consulted directly by `shards/1`,
  the function that actually shards, and stays; the accessor was consulted only by a
  test asserting the same number `shards/1`'s own tests already prove through behaviour.
  `SymbolFormat.mapping/0`'s doc claimed it existed "so the conformance suite can drive
  `CanonicalPair` with it," but `dp_exchange_core`'s conformance suite calls only
  `to_canonical_symbol/1` and `to_exchange_symbol/1` (the actual behaviour callbacks) —
  it never called `mapping/0`, and neither did anything else outside this package's own
  test suite. **Breaking**, for the two functions removed; neither was part of the
  `Venue` behaviour or documented as consumer-facing in `usage-rules.md`.

### Fixed

- **Corrected claim: a single oversized `level2` subscribe does not close the socket. It
  is refused wholesale, and the socket survives — which is worse to detect, not better.**
  Same issue #22. The `level2_pairs_per_socket` warning and
  `docs/reference/coinbase/level2-session-limit.md` used to leave this open: the
  2026-08-26 incident recorded the refusal closing the socket, but the 2026-09-07
  cumulative-overage probe (see the entry below) showed a refusal that did NOT close it —
  and nobody had re-run the *single*-oversized shape since 2026-08-26 to know whether that
  distinction mattered. **DpCryptoManagement ran it, 2026-09-07:** one socket,
  `Socket.subscribe/4` for `n = 30` (accepted, `books=30`), then `n = 60` and `n = 120`
  (both REFUSED — `rate_limited`, `books=0`, nothing delivering), in both ascending and
  largest-first order; `Process.alive?/1` stayed `true` through a 40-second drain after
  every refusal, no `:DOWN` on a monitor, either ordering.

  The refusal is wholesale (the whole shard's coverage is lost, not truncated to the
  first 30) and the socket survives (no disconnect at all) — the identical shape the
  cumulative-overage probe already showed, so the two readings this package could not
  choose between turn out to be the same behaviour. The 2026-08-26 incident record is
  kept, dated, as unexplained rather than overturned: this measurement could not
  reproduce it, and neither this package nor DpCryptoManagement knows why. **The risk is
  restated as more dangerous to notice, not less:** a closed socket announces itself
  through a disconnect and a reconnect; a refusal on a socket that stays alive announces
  nothing beyond the `:rate_limited` `Core.Notice` `Socket`'s `error_kind/1` already
  emits — liveness looks perfect, and the oversized shard simply never delivers.
  `coverage/1` / `coverage_by_kind/1` are the only things that reveal it, unchanged by
  this correction: both already report only symbols that actually delivered a payload.

  The consumer's first attempt at this probe hit a harness defect worth recording for
  future probing with this package's own `Socket`: tearing a socket down with
  `Process.exit(socket, :normal)` is ignored by a process not trapping exits, so
  "closed" sockets stayed alive and leaked into the next attempt's count; fixing that to
  `:kill` then killed the probe itself, because `Socket.start_link/1` links the socket to
  its caller — `Process.unlink/1` first was needed. Recorded, dated and attributed, in
  `docs/reference/coinbase/level2-session-limit.md`.

  `lib/dp_exchange/coinbase/feed.ex`'s moduledoc (the `level2_pairs_per_socket` section
  and its `validate_level2_pairs_per_socket!/1` warning text), `usage-rules.md`, and
  `docs/reference/coinbase/level2-session-limit.md` are all updated; no code behaviour
  changed, only the documented and logged claim. No new `Core.Notice` was added:
  `Socket`'s existing `:rate_limited` notice already names the venue's own refusal
  message verbatim, which already carries this specific cause — a second notice would
  duplicate one already firing.

- **`Socket` full-re-sorted BOTH sides of the maintained level2 book on EVERY `l2_data`
  frame, including an `update` changing a single price level** —
  `dp_exchange_core`'s `docs/design/2026-09-06_order-book-resort-cost.md`. Measured at
  the book size DpCryptoManagement reported live for `BTC-USD` (issue #22, ~22,800 bid
  / ~21,100 ask levels): one update frame cost 62–110 ms across repeated runs in this
  repo (`bench/order_book_resort.exs`) — a ceiling of roughly 9–16 book updates/second,
  maximum, on a socket a shard shares across up to 100 symbols. Stated as a hypothesis
  in the design, not a conclusion here: this is very likely a major part of why
  `ticker` starves whenever `level2` is delivering broadly in #22, since the
  single-threaded socket could never idle long enough to service the `ticker`
  subscribe inside `FrameSender`'s 5-second window — but that causal claim is only
  confirmed by this fix changing behaviour on their node, not by anything measured
  here.

  Each side's `%{Decimal => Decimal}` map is now a `:gb_trees` tree keyed by the price
  scaled to an exact integer (`10^8` — verified 2026-09-06 against Coinbase's own
  public `GET /api/v3/brokerage/market/products`: the smallest published
  `quote_increment` across all 931 products is `0.00000001`, 8 decimal places, and no
  product's own `price` field carries more precision than that either), carrying the
  original `Decimal` as the tree's value. Delivery is now an ordered traversal —
  `Enum.sort_by/3` no longer runs anywhere in the per-frame path. Measured against the
  same book size, repeated runs in this repo: the same one-update-frame cost fell to
  0.9–2.9 ms (roughly 345–1075 updates/second, maximum), and the isolated bids-only
  sort/traversal fell from 49–83 ms to 0.5–6.2 ms. Run
  `mix run bench/order_book_resort.exs` to reproduce on any machine.

  A price that cannot be represented exactly at that scale is refused and reported
  through the same `:data_quality` notice path as any other unparseable row, rather
  than rounded — no real Coinbase price has needed this path so far, but the family's
  own rule against silently substituting a nearby value applies here too. One
  behaviour is deliberately NOT identical to the map-keyed implementation: two
  numerically-equal, differently-scaled price strings (`"1.5"` and `"1.50"`) used to
  become two map entries — two "levels" at one price, because `%Decimal{}` structs
  compare unequal by field even when `Decimal.equal?/2` says they are the same number
  — and now collapse into one, last-write-wins. That was a latent defect in the
  map-keyed version, found and fixed here rather than a behaviour changed as a side
  effect; everything else observable — order, `Decimal` values, count, the
  `Core.Types.OrderBook` struct itself — is unchanged, and is asserted so against a
  reference reimplementation of the old approach in `socket_test.exs`.

- **The alias-map fetch added for issue #22 was throttled by the caller's OWN rate
  limiter at boot and never retried, disabling attribution for the life of the process —
  DpCryptoManagement's issue #26, a regression in a fix this package shipped.**
  `Feed`'s default `alias_map_source` called `Rest.get_alias_map/1` without
  `rate_limit_blocking: true`, so it went through fail-fast `check/3` instead of blocking
  `acquire/3`. The fetch is scheduled off the first `subscribe/3`, which for any real
  consumer **is** boot — the single most contended moment for their own limiter
  (universe discovery, catalogue reads and market overviews all landing at once) — so it
  was scheduled into exactly the window most likely to throttle it. One throttled call
  there, on code that never retried, was permanent: `state.alias_map` stayed `%{}` for
  the life of the process. Measured live: 406 pairs requested as `-USDC`, delivered as
  `-USD`, overlap 5 — `coverage_by_kind/1` and the consumer's own tracker each reporting
  a truthful, and wildly different, count, precisely the situation the issue #22 fix
  existed to end.

  **This is the third instance of one family-wide pattern** — `dp_exchange_robinhood`'s
  issue #16, this package's own issue #23 sweep, and now this: a background call with
  nothing waiting on it, failing instead of waiting, while `Core.HttpClient`'s own error
  message names the fix in its text ("callers that can wait should set
  `rate_limit_blocking: true`"). The issue #23 sweep audited every REST call site in this
  package and missed this one, because the alias-map fetch's own HTTP path was mistaken
  for its sibling WebSocket resubscribe path, which genuinely has no rate-limited replay
  to default. That recurrence is worth more than any one of the three individual fixes:
  the same shape of gap keeps landing at the one call site nobody thought to re-check.

  Three changes, all in `Feed`:

  1. `rate_limit_blocking: true` is now set unconditionally on the fetch, by a new
     `default_alias_map_source/2` that also forwards `:limiter`, `:plug`, `:timeout`,
     `:retry_attempts`, `:retry_delay` and `:weight` from `start_link/1`'s own `opts` —
     the same allowlist shape `Rest`'s own request pipeline uses.
  2. Blocking removes the self-throttle as a failure mode but not every failure: the
     limiter's own bounded wait can still time out. `transient_alias_map_failure?/1`
     classifies that one case as worth retrying — the identical request can reasonably
     succeed once the bucket has drained further — and treats everything else (an
     unrecognised response shape, a refused request, an unclassified reason) as
     permanent, matching `transient_subscribe_failure?/1`'s own default-to-permanent
     stance one section up. Retries are bounded (`@max_alias_map_retries`, backed off by
     `@alias_map_retry_delay_ms`, both overridable for a test's benefit) rather than
     looped forever.
  3. **The degraded-attribution notice was unreceivable by construction, also part of
     issue #26.** The fetch is scheduled from `subscribe/3`; a consumer calling
     `subscribe_notices/1` afterward — the ordinary sequence — could register only after
     the fetch had already failed and fanned out to zero subscribers. A notice
     announcing a *persistent* degraded state that can only ever fire in the one window
     before anyone could be listening is worse than no signal: it looks like a working
     alarm that never rings. Fixed by replay, not by moving the emission earlier (this
     file already learned that moving-the-window lesson once, with
     `next_resubscribe_delay/1`'s per-tick storm): `alias_map_status` and the reason that
     produced it now persist in state, and `subscribe_notices/1` replays the identical
     notice to a newly-registered subscriber whenever it finds the state already
     `:unavailable` — once per new registration, never on a timer, and never re-sent to a
     subscriber who already has it.

  New tests in `feed_test.exs` drive the real fetch pipeline end-to-end for the first
  fix — a real, named `Core.DefaultRateLimiter` with its sole token already spent, behind
  a fake `:plug` response, proving `rate_limit_blocking: true` actually reaches
  `Core.HttpClient` rather than merely surviving being typed into an allowlist — plus the
  transient-retries-and-succeeds, permanent-fails-once, bounded-exhaustion and
  late-notice-subscriber cases, all against the default `alias_map_source` codepath or a
  controlled stand-in, none against a guessed `Process.sleep/1` duration.

- **An empty `pricebooks` array from `/best_bid_ask` was read as the venue naming a
  product not listed, and there is no evidence this venue has ever said that this way —
  audited alongside DpCryptoManagement's issue #25 (`dp_exchange_robinhood`'s confirmed
  instance of the same substitution).** `get_top_of_book/2`'s `{"pricebooks" => []}` clause
  turned a 200 with an empty array into a permanent `{:refused, :not_listed}` — permanent
  because `Core.PollingFeed` reports a refusal once and never retries it.

  Probed live 2026-09-06 against the closely related, unauthenticated
  `/market/product_book` (same pricebook data, one product per call instead of a batch): a
  product this venue has never listed answers `404 {"error":"NOT_FOUND","error_details":
  "valid product_id is required"}`; a product it delisted but still recognises
  (`/market/products/{id}` still answers 200) answers a *different* `404
  {"error":"NOT_FOUND","error_details":"no pricebook found"}`. Neither is a 200 with an
  empty array, and no online product checked (923 listed, spanning the lowest-volume
  pairs) ever returned one either. This venue's own convention for "no book" is a
  distinguishable non-2xx statement. `/best_bid_ask` takes a *list* of `product_ids` and
  answers one pricebook per product it can — an ordinary batch-API shape is to omit an
  entry it cannot answer rather than fail the whole request, which collapses "never
  listed" and "listed but delisted" (two states the sibling endpoint tells apart) into one
  indistinguishable silence, and says nothing about a real, momentarily bookless product
  either.

  The empty-array clause now returns `{:error, :empty_result}` — retryable, the same shape
  a 500 already produces. A genuine venue statement (a 404, this venue's own convention)
  still reaches `{:refused, :not_listed}` through the existing `classify/1` path, which
  this change does not touch. New tests in `rest_test.exs` and `order_book_test.exs` cover
  both: an empty array is retried, and a genuine 404 is still refused.

- **A timed-out channel subscribe was logged and thrown away — no retry until the next
  60s tick reproduced the identical failure, DpCryptoManagement's issue #22.**
  `FrameSender`'s own moduledoc says the whole point of turning a `send_frame` exit into
  `{:error, :send_timeout}` is that a slow socket becomes "a failed batch, which a caller
  can report and retry" — the retry half of that design was never wired into `Feed`. A
  `level2` subscribe triggers a full per-symbol book snapshot; the socket is
  single-threaded and cannot service the next `send_frame` while decoding it, so firing
  `ticker`'s subscribe `@channel_spacing_ms` later still landed inside that window on a
  100-symbol shard and blew the hardcoded 5s send window. Dropped, forever, since nothing
  re-attempted it before the next resubscribe cycle recreated the same busy socket.

  Measured live across a real ~400-symbol consumer, five boots over roughly 5.5 hours —
  the exact inversion this predicts:

  | state | quotes (`ticker`) | order_book (`level2`) |
  |---|---|---|
  | broken (4 boots) | ~5 / 406 | ~406 / 406, 11,000+ frames |
  | healthy (1 boot) | 400 / 406 | 6 / 406 |

  When `level2` got through broadly, its opening snapshot burst starved `ticker`; when
  the venue refused most `level2` subscriptions outright (its own per-session stream
  limit — see the "sharded" section above), `ticker` had the socket to itself and got
  everything. A lone `:send_timeout` on a `ticker` subscribe was also observed directly
  in an earlier run.

  `{:error, :send_timeout}` and `{:error, {:send_exit, reason}}` are now retried —
  transient, since the identical request can reasonably succeed once a busy or briefly
  gone socket catches up. `{:error, {:credentials_required, channel}}` is not: no amount
  of waiting supplies a credential that was never given, and it fails loudly on the first
  attempt instead of looping. The backoff reuses `@channel_spacing_ms` rather than a
  second, independently guessed number for the same busy-socket wait, bounded to two
  retries (three attempts total) — the whole chain resolves in at most 24s, well inside
  even the 60s default resubscribe cycle, so it can never stack fresh frames against the
  unconditional re-issue. Exhausting the retries, and the permanent-error path, both now
  emit a `Core.Notice` of kind `:coverage_change` in addition to the existing log — a
  channel that never subscribed is exactly the invisible half-dead feed this issue is
  about, and a `Logger.warning` alone gave a consumer no facade-level way to see it. A
  socket that dies between attempts is re-checked, not assumed alive, and simply stops
  the chain rather than sending into a corpse.

  Deliberately unchanged: `@channels` order (`level2` before `ticker`) and
  `@channel_spacing_ms` itself. Subscribing the lighter channel first is a plausible
  additional fix, but it is unmeasured and changing two things at once would make the
  next measurement uninterpretable — raised separately with the consumer instead.

- **`:rate_limit_blocking` was unreachable on every REST call this package makes —
  family-wide gap, DpCryptoManagement's issue #23.** `Core.HttpClient.check_rate_limits/1`
  reads this option to choose `acquire/3` (wait for capacity) over fail-fast `check/3`,
  and its own error message on a self-inflicted throttle tells a caller to set it — but no
  caller could, on this venue: `Rest.request/5`, `Rest.json_request/5` and
  `Prime.request_opts/1` all stripped it from their forwarded-options allowlist before it
  ever reached `Core.HttpClient`. The same defect (`dp_exchange_webull`'s issue #23,
  `dp_exchange_robinhood`'s issue #16) audited across the rest of the family; this venue
  was one of four still carrying it.

  All three allowlists now forward `:rate_limit_blocking`, proven with a recording rate
  limiter that records which of `acquire/3` / `check/3` was actually called — not merely
  that the keyword survives the allowlist. **Not defaulted anywhere in this package**,
  unlike `dp_exchange_webull`'s `Feed` and `dp_exchange_robinhood`'s `Feed`: this venue's
  own periodic resubscribe (`DpExchange.Coinbase.Feed`'s unconditional 60s re-issue) sends
  WebSocket frames, not HTTP, so there is no rate-limited background replay here to justify
  choosing a default on a caller's behalf. A caller that wants blocking opts in explicitly.

- **A resubscribe interval shorter than one re-issue cycle wedged the feed — including
  the 60s DEFAULT, past twelve shards.** A cycle is not instantaneous: shards are
  staggered `@shard_spacing_ms` apart and each shard's channels `@channel_spacing_ms`
  apart, so the last frame goes out about `(shards - 1) * 5_000 + 8_000` ms after the
  tick. If the timer re-fired before that, cycles overlapped, frames queued behind each
  other, `WebSockex.send_frame/2` blew its window, and the `Feed` stopped answering calls
  entirely — `:sys.get_state/1` timing out. A wedged feed is strictly worse than a late
  resubscribe.

  Found by DpCryptoManagement while running the diagnostic added in the previous release
  (issue #22): they set `resubscribe_interval_ms: 5_000`, below the 8s channel spacing,
  and lost the run to it. They reported it against themselves rather than against the
  option, which is how it got looked at properly — because checking it showed **the same
  failure was reachable with no option set at all.** The 60s default is shorter than the
  cycle span from twelve shards (1,101 symbols at `@pairs_per_socket`) upward, so a large
  enough consumer would have walked into it on defaults alone. The knob exposed a limit
  the default already had.

  The next delay is now derived from the shard count that actually exists at each tick,
  never from the configured value alone, and an extension is **logged** rather than
  applied silently — a diagnostic knob whose value is quietly ignored is its own trap.
  Nothing changes for any interval that was already comfortable.

- **`get_top_of_book/2` could never work without credentials, and the facade said
  otherwise — family-wide defect sweep, Coinbase B1.** Unlike every sibling market-data
  reader in `Rest`, this one call is hardcoded to `/best_bid_ask` with no
  `/market/best_bid_ask` branch. Re-verified live 2026-09-05: authenticated is `401`, and
  the public path a caller would expect by analogy is `404` — there is no public form to
  fall back to, so inventing one would have been exactly the "nearby substitute" this
  family refuses. Fixed by checking for credentials up front and returning
  `{:refused, :missing_credentials}` before sending anything, rather than surfacing the
  venue's `401` as an opaque error. `DpExchange.Coinbase`'s moduledoc and
  `capabilities/0`'s `credential_benefit` comment both claimed "the same market data is
  served publicly" without qualification — true of every other endpoint, false of this
  one — and both now name the exception. `usage-rules.md` carried the identical claim and
  is corrected the same way, since it ships inside the Hex tarball and is what a
  consuming agent reads.

- **`apply_book_row/2` silently dropped a `level2` row it could not parse — family-wide
  defect sweep, Coinbase B2.** Every other decode-failure path in `Socket`
  (`deliver_ticker/3`, `deliver_book/3`) reports a `:data_quality` notice through
  `report_quality/2`; this one returned the maintained book unchanged with no signal,
  against the module's own stated discipline ("a payload that did not parse is reported,
  not swallowed and not fatal"). Concrete cost: `new_quantity: "0"` is how the venue
  signals level *removal*, so an unparseable quantity silently ignored could leave a
  stale price level in the maintained book indefinitely with nothing indicating why.
  `apply_book_row/3` now threads `state` through and reports a `:data_quality` notice for
  an unparseable `price_level`/`new_quantity` and for a row missing those keys entirely —
  the connection is still never torn down over one bad row.

- **`Socket.start_link/1` inherited WebSockex's own connect/recv timeouts by accident —
  family-wide defect sweep, Coinbase B4.** No `:socket_connect_timeout` or
  `:socket_recv_timeout` was set, so WebSockex supplied its own defaults — measured in
  the vendored dependency, `deps/websockex/lib/websockex/conn.ex:10-11`: `6_000` ms
  connect, `5_000` ms recv. That matters specifically because `Feed`'s `open_shard/5`
  synchronous branch calls `Socket.start_link/1` from **inside** a `handle_call/3`, and
  `Feed`'s own `@call_timeout` is `@frame_window_ms * 3` = `15_000` ms — a named, shared
  process, so every other consumer's `subscribe/2`, `unsubscribe/2`, `update_symbols/2`
  and `coverage/1` call queues behind that one call. The inherited defaults alone
  (`6_000 + 5_000 = 11_000` ms) would burn roughly three-quarters of that budget on the
  TCP connect and the handshake recv **alone**, against an unreachable or black-holing
  venue, before a single subscribe frame is sent. The margin was never chosen; it was
  whatever the dependency happened to default to.

  Fixed by setting both explicitly at `3_000` ms each (`6_000` ms total), chosen
  deliberately against `Feed`'s `15_000` ms budget — leaving roughly `9_000` ms of the
  same call for the socket to send at least one subscribe frame (capped at `Feed`'s own
  `5_000` ms `@frame_window_ms`) plus ordinary `GenServer` overhead. No failure
  semantics changed: `start_link/1` still returns `{:error, reason}` synchronously
  exactly as before, so the synchronous-primary-shard design is unchanged bit for bit —
  only the margin after a slow or absent venue does. A caller passing either key in
  `opts` still overrides it. The merge is factored into a small `@doc false`
  `connection_opts/1` so a regression test can pin both the defaults and the override
  precedence without opening a real socket.

- **The venue rewrites an aliased product id on delivery, and streaming passed the
  rewritten id straight through — DpCryptoManagement's issue #22.** Measured live
  2026-09-05 against `wss://advanced-trade-ws.coinbase.com`: subscribing `ticker` to
  `["XLM-USDC", "AVAX-USDC"]` — sent exactly as asked, both real, listed products —
  delivers every frame tagged `XLM-USD` and `AVAX-USD` instead; the venue's own
  subscription acknowledgement even echoes the rewritten names back
  (`"ticker" => ["XLM-USD", "AVAX-USD"]`), not the ones actually sent. This is the
  venue's own declared behaviour, not a guess: the same public, unauthenticated
  `/market/products` catalogue this package already reads for `get_symbols/1` and
  `list_instruments/1` names it directly — on this date, 112 of the first 114 USDC
  products carried a non-empty `alias` naming their `-USD` counterpart. On a settled
  DpCryptoManagement node running 0.1.17 with 406 pairs requested, this was the same
  defect wearing two faces: 174 of the 406 *requested* pairs delivered nothing under the
  name asked for, while 401 pairs *never requested* were decoded and stored under a name
  nobody subscribed.

  Fixed in `Feed`, not `Socket`: `Socket` still decodes and delivers under whatever
  `product_id` the venue actually sent, unchanged. `Feed.handle_info({:dp_exchange,
  :coinbase, payload}, state)` now resolves a delivered id against `Rest.get_alias_map/1`
  — the venue's own declared relationship, fetched **once**, asynchronously, the first
  time `subscribe/3` or `update_symbols/2` runs (never per frame, never per subscribe;
  see `Feed`'s moduledoc for why it is not read from `init/1` or inline in the
  triggering call) — and delivers under every name in `wanted` that names the same
  market: the caller's own requested name, and its alias where the caller subscribed to
  that instead. A caller subscribed to both receives both, from one delivered frame.
  `coverage/1` needed no code change to become honest, since it already reports
  whatever key delivery is recorded under.

  **A catalogue that cannot be fetched degrades rather than guesses.** A failed fetch
  delivers under the venue's own id — today's pre-fix behaviour — and reports exactly
  once, as a `:data_quality` notice naming the failure, that attribution is degraded and
  why. Munging `-USDC` into `-USD` was considered and rejected: it would be exactly the
  "nearby substitute" this family forbids, and wrong for any pair the venue does not
  alias — nothing here assumes the suffix relationship holds in general, and the fix
  reads only the venue's own `alias` field.

  Regression tests in `feed_test.exs` drive the proven mechanism directly — a subscribe
  to the alias form receiving frames tagged with the canonical form delivers under the
  alias form; `coverage/1` lists what was requested; both names subscribed both receive
  one delivered frame; a catalogue fetch failure delivers under the venue's id plus the
  degraded notice, never a guessed mapping; the fetch happens once regardless of how many
  subscribes or delivered frames follow — and `rest_test.exs` covers `get_alias_map/1`
  itself against a catalogue shaped like the live response captured while proving this.

- **`Supervisor`'s own rate limiter was configured from `public_ceiling` unconditionally,
  contradicting `capabilities/0`'s own documented promise that credentials buy the higher
  ceiling.** `capabilities/0` states outright: *"Pass credentials and this package uses
  the authenticated path, which has the higher ceiling."* `Rest`'s request paths honour
  that — but `Supervisor`'s `init/1` started `DefaultRateLimiter` from `caps.public_ceiling`
  (3 req/s) for every instance, credentialed or not, so a consumer supplying credentials
  got the documented 10 req/s from the venue and a third of that from this package's own
  throttle regardless — a mechanism silently disagreeing with the declaration it exists to
  encode, per this module's own moduledoc rule. `limits/1` now reads `opts[:credentials]`
  (the same opts `Feed` reads it from) and configures the bucket from
  `authenticated_ceiling` when a non-empty credential map was given, `public_ceiling`
  otherwise. New tests in `supervisor_test.exs` prove both ceilings actually reach the
  running limiter, and that an empty `%{}` does not buy the higher one.

- **A shard whose socket failed to open at all was silent at the facade — no
  `Core.Notice`, only a `Logger.warning` that never crosses it.** Every shard beyond the
  first opens asynchronously; when its `Socket.start_link/1` failed (a transient connect
  refusal, a timeout), `handle_info({:open_shard, _, _}, _)` logged and stopped, leaving
  those symbols silently absent from `coverage/1` with nothing telling a consumer why —
  the exact "silent half-dead feed" this module's own moduledoc is about, and worse than
  the channel-subscribe case one section up, which already got a `:coverage_change`
  notice for the identical shape of fact (subscribed intent that did not become
  delivery). Now emits one, through the same `notify_shard_open_failed/3` path.

  **Worse: a shard that failed to open had no automatic recovery path at all.** The
  unconditional `:resubscribe` tick only ever walked `state.shards` — a shard whose
  socket never opened is not a key in it, so the tick had nothing to re-issue for it, and
  the only thing that would ever reconsider it was a fresh `subscribe/3` or
  `update_symbols/2` call, which may never come for a consumer whose scope is stable
  after boot. `retry_missing_shards/1` closes this: on every `:resubscribe` tick, any
  shard `state.wanted` still implies but `state.shards` has no entry for is retried on
  the same unconditional cadence an already-open shard's subscriptions are re-issued on,
  staggered past them by the usual `@shard_spacing_ms`. New tests in `feed_test.exs`
  cover both: the notice on a failed open, and the tick recovering a shard that never
  opened.

- **Reconciling more than one ALREADY-OPEN shard in a single `update_symbols/2` call
  dropped the stagger between them — only a brand-new shard's connect was staggered.**
  `reshard/1` computes `position * @shard_spacing_ms` for every shard beyond the
  synchronous primary and hands it to `touch_shard/4`, but `reconcile_shard/6` (an
  existing, already-open shard) never received it — every already-open shard a single
  call touched had its `level2` subscribe scheduled at the identical instant regardless
  of position. This is not the connect burst `@shard_spacing_ms` was written against (no
  new socket opens here), but a related hazard: `Socket.subscribe/4` blocks THIS `Feed`
  process — via `FrameSender`, up to `WebSockex.send_frame/2`'s 5s window — for as long
  as its target socket takes to acknowledge, and several such messages landing in this
  process's single mailbox together serialise into back-to-back blocking sends, capable
  of stalling `coverage/1` and every other call to this `Feed` for as long as the
  slowest one takes. `reconcile_shard/7` now receives and applies the same `delay`
  `open_shard/5` already did. A new test in `feed_test.exs` proves it with two live
  sockets recording arrival time: touching two already-open shards in one call now
  delivers their first frames `@shard_spacing_ms` apart, not together.

- **`Fake`'s `get_top_of_book/2` ignored `opts[:credentials]` entirely,
  making the fake MORE capable than the real venue on the one call where that gap
  matters.** `Rest.get_top_of_book/2` refuses `{:refused, :missing_credentials}` before
  sending anything when given none — `/best_bid_ask` has no public form on this venue,
  confirmed live (`401` authenticated, `404` at the `/market/...` path a caller would
  expect). The fake answered `{:ok, %Types.TopOfBook{}}` regardless, so a consumer's test
  written without credentials would pass against the fake and refuse identically in
  production — precisely the silent "differently capable" divergence this module's own
  moduledoc says it exists to prevent (*"Six were loud... Three were silent, and those
  are the ones this is designed against"*). The fake now refuses the same way, gated on
  the same field. New tests in `fake_test.exs` and an updated one in
  `fake_injection_test.exs` (which previously called it with no credentials at all and
  got away with it) cover both branches.

- **`level2` and `ticker` shared one shard size, and the venue's own `level2` ceiling is
  well under it — DpCryptoManagement's issue #22 continuing, not reopened.** The `ticker`
  starvation fixed earlier in this file (the timed-out-subscribe retry entry above) is a
  separate, already-closed incident in the same file; this is a second, independent
  defect the sharding line above deliberately left unchanged pending a separate
  measurement ("Deliberately unchanged: `@channels` order... raised separately with the
  consumer instead"). That measurement is this entry.

  A consumer's real 406-symbol universe, on sixteen otherwise-healthy boots (0
  `send_timeout`, 406/406 `quotes` coverage): `shards/1` at the old shared
  `@pairs_per_socket` (100) split it `[100, 100, 100, 100, 6]`, and `level2`'s subscribe
  was refused on every 100-symbol shard — `"too many L2 streams requested in a single
  session"`, 5,099 times — while the six-symbol shard's was not.
  `coverage_by_kind/1` answered `order_book: 6` throughout: exactly the tail shard's own
  count, pinning the cause on shard size rather than the connection, the alias fix, or
  `ticker` (which has no such ceiling and was unaffected on the same boots).

  No Coinbase documentation states a per-session `level2` product ceiling — re-checked
  2026-09-06 against the Advanced Trade channels reference, connection overview and
  rate-limits page (which states an `8`-per-second-per-IP connect/message rate, not a
  subscription count), and the older Exchange product's separate rate-limits page (which
  states a different, inapplicable number: 10 duplicate subscriptions to the same
  product-channel pair, not the count of distinct products, and for a product this
  package does not speak). This package cannot narrow it by probing the venue either:
  `level2` is authenticated, and this repo's own testing strategy draws tier 3
  (authenticated, live) as needing credentials this repo must never hold — the same line
  that already keeps this repo off order placement.

  `level2` now gets its own shard grouping, at its own, independent size —
  `@level2_pairs_per_socket`, `6` — rather than sharing `@pairs_per_socket` (100, still
  `ticker`'s own size, unchanged) with `ticker`. `6` is not a rediscovered venue limit;
  it is the largest `level2` subscription size this package has direct evidence the venue
  accepts, taken from the production numbers above (100 refused four times out of four, 6
  accepted once out of one) rather than guessed at some unverified point between them.
  Every shard, either channel, now opens its own dedicated, single-channel socket — for
  the 406-symbol universe above, 5 `ticker` sockets (unchanged) plus 68 `level2` sockets
  (`ceil(406 / 6)`), 73 total against 5 before, affordable now that removing in-package
  `level2` book maintenance (the change above this one) cut per-frame decode cost roughly
  tenfold.

  Every new socket — either channel — is staggered on one `@shard_spacing_ms` sequence
  with every touched `ticker` shard ordered ahead of every touched `level2` shard, so
  `ticker`'s own boot-time coverage stays exactly as fast as before this change while
  `level2`'s far more numerous shards ramp in behind it — for the 406-symbol universe,
  roughly six minutes for the last `level2` shard, against a ceiling that previously never
  moved at all. `@channel_spacing_ms` — the wait between `level2` and `ticker` sharing one
  socket — is deleted along with the shared-socket design it existed for; no socket
  carries two channels any more, so the busy-decoding hazard it guarded against cannot
  occur. `@subscribe_retry_delay_ms` keeps its value (still `8_000`ms) on its own
  reasoning rather than borrowing from a constant that no longer exists.

  An adaptive shard size, driven down at runtime by the venue's own refusal so a wrong
  constant could never be silently wrong forever, was considered and not built:
  correctly telling a live shard's bookkeeping apart from a stale one the venue already
  emptied on refusal is real complexity with its own correctness risk (silently under- or
  double-subscribing a shard), and did not clear its bar against a fixed,
  evidence-grounded constant plus the safety net that already existed and needed no
  change — `Socket`'s `error_kind/1` already classifies "too many" as `:rate_limited` and
  reports it as a `Core.Notice` on every occurrence, and `coverage_by_kind/1` already
  never marks a symbol covered for `:order_book` on subscribed intent alone. Both are
  verified unchanged by this fix. If `6` is ever also refused, a consumer with
  `subscribe_notices/1` wired up hears about it exactly as loudly as any other refusal in
  this file, and lowering the constant is a one-line change rather than a runtime
  decision made silently.

  New tests in `feed_test.exs` pin the structural fix: a credentialed feed given a symbol
  count that fits in one `ticker` shard splits it into two `level2` shards, with the
  `ticker` shard chosen as the call's synchronous primary; a credential-less feed never
  opens a `level2`-keyed shard at all. The 12-shard resubscribe-floor test is now a
  13-shard one, and its expected numbers drop the deleted `@channel_spacing_ms` term —
  both mechanical consequences of this change, not new behaviour of their own.

- **`@level2_pairs_per_socket` was `6` — a conservative lower bound, correctly labelled as
  one — and the real boundary is now measured: `30`. Same issue #22, continuing.** `6` was
  never a rediscovered venue limit; it was the largest size this package had any positive
  evidence for at the time, with `100` (refused) as the nearest known failure and nothing
  in between actually tried. This package still cannot bisect a live, authenticated
  `level2` session itself — that is tier 3, a line this repo does not cross for any
  endpoint. **DpCryptoManagement can, and did**, on 2026-09-06 (issue #22): a fresh
  socket per attempt, never reused, against their real 406-symbol scope —
  `n = 6/12/25/30` accepted, `n = 31/35/50/100` refused, confirmed by interleaving two
  runs back to back and by a contamination check (re-running `n=6` and `n=30` immediately
  after a refusal run, both still accepted, ruling out probe-induced saturation as the
  cause). `30` is the largest value with positive evidence of acceptance, `31` the
  smallest with positive evidence of refusal — the boundary itself, not merely a
  known-good far below a known-bad. See `docs/reference/coinbase/level2-session-limit.md`
  for the full method and attribution.

  For DpCryptoManagement's 406-symbol universe this is 14 `level2` sockets instead of 68
  (19 total instead of 73) and roughly 70 seconds to full `order_book` coverage instead of
  about six minutes — the same staggered, `ticker`-first connect sequence as before, just
  markedly shorter because far fewer sockets need it.

  **A second question this raises got checked directly, not left open by omission.** The
  consumer's harness used a fresh socket per attempt *specifically* to keep cumulative
  session state out of its own result, which means it cannot say whether Coinbase's
  ceiling counts concurrently-held products or every distinct product a session has ever
  carried. Checked against this package's own code: `reconcile_shard/7` used to subscribe
  a shard's newly-added symbols onto whatever socket that shard already had open, and a
  `MapSet`'s enumeration order being a function of its current keys (not insertion order)
  means ordinary universe churn — not only a caller literally adding a symbol — routinely
  hands an already-open `level2` shard products it has never carried before. At `6` this
  had enormous headroom; at `30`, aimed at a now-exact boundary, it had none: the very
  first churn past a full shard could have pushed one socket's *lifetime* subscription
  count to 31 even though its concurrent membership never left 30. Fixed by replacing the
  socket instead of mutating it whenever a `level2` shard's membership would grow
  (`reconcile_shard/7`'s `"level2"` clause, `replace_level2_shard/7`,
  `terminate_socket/1`) — a shard that only loses symbols keeps its existing socket, since
  removal cannot grow that count, and `ticker` is unaffected, since it has no known
  ceiling to protect. This makes "should never be over the ceiling" hold unconditionally,
  concurrently and cumulatively, per socket, regardless of which of Coinbase's two
  possible countings turns out to be real.

  **One axis is still genuinely open and was not fixed here.** The unconditional
  60-second resubscribe re-issues a shard's unchanged symbols to its already-subscribed
  socket forever, which would feed an *attempt-counted* ceiling if Coinbase has one — this
  is the same open question `Feed`'s `@default_resubscribe_interval_ms` comment already
  named before this investigation, and this investigation did not close it. Two specific
  probes that would are recorded in `docs/reference/coinbase/level2-session-limit.md`,
  for whichever party next holds the credential to run them.

  **DpCryptoManagement also reported a refusal that was not always a clean gate** — some
  oversized subscribes delivered 1,300+ books alongside their `rate_limited` notice rather
  than refusing outright, once even at `n=31`, the smallest over-the-boundary value. This
  does not move the boundary (every `n ≥ 31` refused, every `n ≤ 30` did not) and has no
  explanation from either party; it is recorded, dated and attributed, as an unexplained
  venue characteristic in `docs/reference/coinbase/level2-session-limit.md`, not
  rationalised into a theory neither party has evidence for. This package should never
  itself trigger it — every `level2` subscribe it sends carries at most 30 symbols by
  construction, before and after this fix — and `coverage/1` / `coverage_by_kind/1` need
  no change to stay honest if it ever does: both are built entirely from symbols that
  actually delivered a payload, and a `Core.Notice` never touches that bookkeeping.

  New tests in `feed_test.exs` pin both the number and the fix: `35` symbols (rather than
  `10`) now produces two `level2` shards at `30`/socket; a `level2` shard engineered to be
  missing symbols its own fresh chunking would include is replaced — old socket killed,
  new one recorded, target set intact — while one only losing symbols keeps its existing
  socket; `ticker` given the identical setup keeps mutating in place; the deferred
  (non-primary-shard) replace path is driven directly, including the stale-message guard
  and a replacement socket that fails to open.

- **The socket-replacement fix directly above is superseded: the question it hedged
  against is now measured, and the hedge was more expensive than the answer required.**
  Same issue #22, continuing. `9139881` replaced a growing `level2` shard's socket outright
  because this package could not tell whether Coinbase's per-session ceiling counted
  concurrently-held products or every distinct product a session had ever carried — a real
  open question at the time, and a full reconnect (fresh snapshot, coverage gap) was the
  cost of not guessing wrong either way.

  **DpCryptoManagement answered it directly, 2026-09-07: three probes, each on ONE socket,
  using raw `Socket.subscribe/4` — deliberately not `Feed`/`update_symbols/2`, so the
  result is evidence about the venue's own accounting, not this package's dedup.** The same
  30 products re-sent ~60s apart 14 times (~13 minutes): all accepted, `books=0` on every
  repeat — repeats do not accumulate, which also directly answers the "attempt-counting"
  open question from the previous entry (the unconditional 60-second resubscribe does not
  feed a cumulative counter, at any shard size). A different 30 products on the same
  socket without unsubscribing the first batch: `cumulative=60` — REFUSED, but the socket
  stayed alive and the first batch kept delivering (27/30 still ticking); only the second,
  unreleased batch was rejected. Four batches of 30, each unsubscribing the previous batch
  first: all four accepted, fresh snapshot each time — 120 distinct products through one
  socket, never more than 30 live at once. **The ceiling is 30 CONCURRENT products per
  session, not 30 over a session's lifetime**, and `unsubscribe` releases budget the venue
  actually honours.

  `reconcile_shard/7`'s `"level2"` clause and `replace_level2_shard/7` are gone.
  `reconcile_shard_in_place/7` now handles both channels, all three shapes a shard's
  membership can change (only losses, only gains, both), on the shard's EXISTING socket:
  `removed` is unsubscribed before `added` is subscribed, and the subscribe never goes out
  until the unsubscribe has returned `:ok` (retried on a transient send failure with the
  same bounded backoff a channel subscribe already gets — `attempt_channel_reconcile/6`,
  `handle_unsubscribe_failure/8` — with `added` withheld, not sent anyway, if the retries
  exhaust). The order is load-bearing: probe 3 above works BECAUSE the departing batch's
  slots were freed before the arriving batch was requested; probe 2 is the identical
  operation in the other order and was refused, quietly — the socket stayed alive and
  already-flowing symbols were unaffected, with only the newly-requested ones silently
  missing. Shrinking before growing keeps a socket's transient concurrent count bounded by
  `max(length(current), length(wanted))`, never more than `level2_pairs_per_socket`,
  including mid-reconcile, not only at rest.

  **What guarantee this package actually has is stated plainly, not assumed generous.**
  `Socket.subscribe/4` and `Socket.unsubscribe/3` both block on `FrameSender`'s synchronous
  `WebSockex.send_frame/2` call, so ordering the two calls in code orders the two frames on
  the wire; TCP delivers one connection's bytes in the order they were written, and nothing
  in any probe has ever shown Coinbase reordering two frames on one connection. But
  `Socket.unsubscribe/3`'s `:ok` means the frame was handed to the connection, never that
  the venue has finished releasing the departing slots — this protocol gives no
  acknowledgement frame for an unsubscribe to wait on. This package relies on frame order,
  not a confirmed venue-side state transition, and says so in `feed.ex`'s own moduledoc
  ("unsubscribe before subscribe") rather than rounding the guarantee up. One gap stays
  open and disclosed: a permanently stranded unsubscribe (every retry exhausted) is not
  itself retried by the next resubscribe cycle, which only re-issues a plain `subscribe` —
  closing that would need a cross-cycle retry ledger judged not to clear its own complexity
  bar against how narrow the gap is.

  `docs/reference/coinbase/level2-session-limit.md` records all three probes, dated and
  attributed, and marks the cumulative-vs-concurrent and attempt-counting questions
  resolved. **One thing is explicitly NOT resolved and is recorded as open, not decided
  either way:** the `level2_pairs_per_socket` warning and the reference doc both used to
  state that an oversized subscribe "closes the socket and loses that shard's entire
  coverage" — probe 2 above shows a *cumulative* overage refusal that did NOT close the
  socket. The original 2026-08-26 incident recorded socket closure for what may be a
  different case (a *single* oversized subscribe, not cumulative overage), and the
  consumer has offered to test the single-oversized case specifically; until that runs,
  both observations are stated and the conflict is left open, and the warning text states
  the worse of the two outcomes as the risk to plan for rather than asserting it as
  certain. *(That test ran the same day — see the "Corrected claim" entry above this
  section for the result: refused wholesale, socket survives, same as probe 2.)*

  New tests in `feed_test.exs` replace the socket-replacement suite: a growing `level2`
  shard reconciles on its existing socket (never replaced, never killed); a shard that
  both loses and gains sends the unsubscribe frame before the subscribe frame, on both the
  synchronous (primary-shard) and deferred (async) reconcile paths; a shard reconciling
  losses and gains together never reports more live products than its own shard size at
  any point a fake venue-tracking socket observes, including mid-reconcile; a transient
  unsubscribe failure is retried and the subscribe stays withheld until it succeeds; an
  unsubscribe that exhausts its retries withholds the subscribe entirely and reports a
  `:coverage_change` notice naming both the departing and withheld-arriving counts.

- **The fix directly above left its own gap: a permanently stranded unsubscribe was
  dropped from this package's own bookkeeping, not merely from the venue.** Traced by
  the coordinator against the actual code, not taken on the summary above's word:
  `reconcile_shard_in_place/7` recorded `state.shards[key].symbols = wanted`
  unconditionally on both its sync and deferred clauses, regardless of whether the
  underlying unsubscribe ever succeeded. The WITHHELD `added` side already recovered —
  the 60-second cycle re-issues `state.shards[key].symbols`, which is `wanted` — but the
  STRANDED `removed` side did not: nothing re-issued the unsubscribe, and this module's
  own bookkeeping had already stopped tracking it as owed. Left alone this degrades into
  the exact failure this whole file exists to prevent — the venue's live count sitting at
  `old ∪ wanted`, eventually exceeding the shard's cap, refusing every later subscribe for
  that shard quietly (DpCryptoManagement's own probe 2 — socket alive, existing symbols
  still flowing, new ones silently absent) — and the `added` recovery makes it WORSE, not
  better, by continuing to push subscribes into a budget the stranded slots guarantee
  cannot fit.

  Closed using the machinery already there, per the coordinator's own instruction, not a
  new subsystem: `state.pending_unsubscribes` (`%{{channel, index} => [symbol, ...]}`) is
  written by `strand_unsubscribe/7` whenever a reconcile gives up on releasing some
  `removed` symbols — the synchronous clause's single failed attempt (no retry chain of
  its own, so it strands immediately) and the deferred clause's exhausted retry chain
  alike — and read back by `handle_info(:resubscribe, _)` on the identical unconditional
  cadence `retry_missing_shards/1` already uses to recover a shard whose socket never
  opened at all; that function's own comment states the governing principle this reuses
  word for word. Each tick now sends `{:channel_reconcile, key, socket, channel, pending,
  symbols, credentials}` per shard — the shard's own pending entry as `removed`, its WHOLE
  current membership (not a delta) as `added` — through the SAME `attempt_channel_reconcile/6`
  an ordinary reconcile already runs, so the retried release precedes that shard's
  resubscribe on the same tick for the identical reason it precedes one anywhere else in
  this file. For the ordinary case (nothing pending) this costs nothing beyond what a
  plain `Socket.subscribe/4` already cost, since `unsubscribe_step/3` short-circuits an
  empty list without sending anything.

  `clear_pending_unsubscribe/3` removes only the symbols a successful send actually
  covered (`pending -- removed`, not the whole key), so an unrelated, still-outstanding
  stranding on the same shard survives a different one clearing. `strand_unsubscribe/7`
  is symmetric — it merges, never overwrites. `drop_unwanted_shards/3` now also drops a
  shard's pending entry the moment the shard itself is dropped, since
  `handle_info(:resubscribe, _)` walks `Map.keys(state.shards)` specifically and would
  otherwise retry nothing for a key that no longer exists there — this is what keeps
  `state.pending_unsubscribes` bounded by currently-open shards carrying an unresolved
  stranding, not by this module's all-time history of failures. A symbol churned out
  (stranding it) and back into the same shard before the next tick is not a hazard either:
  `added` is always the shard's whole current membership, so the same reconcile's own
  subscribe puts it right back if still wanted, in order, costing at most one redundant
  frame pair.

  **What was deliberately not built, and why, argued rather than assumed:** correlating a
  stranding to a specific socket's own reconnect. A reconnect gets a fresh venue session,
  releasing every stranded slot on the old one whether this package notices or not — but
  `Socket` holds no shard-correlating identity in its `:link_up`/`:link_down` notices by
  design (its own moduledoc: "`Socket` holds no book to key by anything"), and WebSockex's
  reconnect keeps the same pid, so pid identity cannot substitute. Building that
  correlation would widen `Socket`'s own contract for a case whose cost, left alone, is
  bounded: a stale entry retried against a fresh session sends one wasted `unsubscribe`
  (assumed idempotent-safe against an unsubscribed symbol, consistent with but not
  independently measured against this family's stated subscribe-idempotency assumption —
  labelled a gap, not hidden as a certainty) and is immediately followed, same reconcile,
  by a subscribe of the shard's whole current membership — self-correcting the same tick,
  never leaving the shard short a wanted symbol.

  **`transient_frame_failure?/1`'s real reach, stated rather than assumed generous:**
  `Socket.unsubscribe/3` builds no JWT and checks no credentials, so it has no analogue of
  a subscribe's `{:credentials_required, channel}` — its only two possible failure shapes,
  `:send_timeout` and `{:send_exit, reason}`, are both already classified transient. The
  non-transient `cond` branch in `handle_unsubscribe_failure/8` therefore does not fire
  against the real venue today; "permanently stranded" is reached, in practice, only by
  EXHAUSTING the bounded retry chain against a socket that keeps failing to send without
  ever actually dying (`Process.alive?/1` staying `true` throughout — a genuinely dead
  socket short-circuits every reconcile path before reaching this branch, matching every
  other dead-socket guard in this module). The non-transient branch is kept anyway, wired
  to identical behaviour, for the same "do not assume a shape that happens to hold today"
  reason `handle_subscribe_failure/6` keeps its own — a two-branch `cond` reusing one
  existing helper, not new machinery for a case argued, not merely assumed, to be
  effectively unreachable.

  New tests in `feed_test.exs`: the resubscribe tick retries a shard's pending unsubscribe
  before it resubscribes and a successful retry clears it; a retry that also fails leaves
  the entry in place for the next cycle; a synchronous (primary-shard) unsubscribe failure
  is stranded rather than dropped; dropping a shard entirely also drops its own pending
  entry.

### Documentation

- **CLAUDE.md claimed this package parses Coinbase's `cb-after` / `cb-before`
  rate-limit headers; it deliberately does not, and never has.** Those are pagination
  cursors, not rate-limit data, and Coinbase publishes no `x-ratelimit-*` or
  `retry-after` either — measured live 2026-08-28. A prior adapter's parser keyed off
  the cursor headers and returned three hardcoded constants labelled as measurements
  (`remaining: 100`, `limit: 100`, a reset time one minute out); porting it would have
  been exactly the fabrication this family refuses — recorded in
  `docs/reference/coinbase/reconciliation.md` §5.5, which CLAUDE.md's own claim
  contradicted. Corrected to state what actually happens: nothing is parsed, and
  `Core.HttpClient`'s generic parser correctly answers `nil`.

- **`docs/reference/coinbase/endpoint-inventory.md` still listed `/best_bid_ask` and
  `/product_book` as not implemented — family-wide defect sweep, Coinbase B3.** Both were
  implemented and declared `:experimental` in `capabilities/0` well before this release;
  the note was never updated when they shipped, which is part of why B1's missing
  public/private branch on `/best_bid_ask` went unnoticed. Both endpoints are now marked
  `✓` in the endpoint list, the stale "absent" note is corrected, and the newly measured
  fact from B1 is recorded where this file's other live measurements live: `/best_bid_ask`
  has no public form, verified live 2026-09-05, unlike `/product_book`, whose
  `market/product_book` twin is real and public.

- **`usage-rules.md`'s "Streaming" section never said which symbol a delivered frame
  carries, and never mentioned `resubscribe_interval_ms` at all — family-wide defect
  sweep, Coinbase B5.** Both are consumer-facing behaviour a subscribing agent needs to
  act on correctly, and this file — the one that ships inside the Hex tarball and is not
  the README — was silent on both. The alias-attribution fix above changes what symbol
  arrives on every streamed frame; `resubscribe_interval_ms` has been a real `Feed`
  option, forwarded straight through from `{DpExchange.Coinbase, resubscribe_interval_ms:
  ms}`, since the resubscribe-wedge fix above added it, and neither fact was checkable
  from the shipped docs. Added two sections: one stating a delivered frame is tagged
  with the symbol the caller subscribed to, never the venue's rewritten alias, including
  the degraded-attribution fallback and its `:data_quality` notice; one documenting
  `resubscribe_interval_ms`'s 60,000 ms default, how to set it, and that a value below
  one full re-issue cycle for the current shard count is silently clamped to the
  computed floor and logged rather than honoured.

- **README's endpoint counts were stale.** It read "46 are declared `:experimental` and
  41 `:unsupported`" with "38" of those the venue's own absence. Run against the real
  `capabilities/0` (`mix run -e`, 2026-09-05): **48 `:experimental`, 39 `:unsupported`**,
  of which **37** are `venue_does_not_serve/0` (the other 2 are `@not_ported`,
  `get_funding/2` and `get_contract_stats/2`). Corrected to the measured numbers rather
  than re-guessed.

- **`frame_sender.ex`'s moduledoc claimed `WebSockex.send_frame/2` has "no way to
  override" its 5-second timeout.** The vendored websockex 0.5.1 exposes `send_frame/3`
  with a timeout argument, so the claim was wrong. `FrameSender.send/3` still calls the
  2-arg form, so nothing about the actual timeout behaviour changes here — see the design
  doc's deferred section for why a longer timeout is a decision for later, not a
  drive-by alongside this correction.

- **Every `ticker` frame from the real venue failed to decode — 0 `Quote`s delivered,
  ever, against live Coinbase, for the entire life of this package.** Surfaced while
  chasing DpCryptoManagement's issue #22: a live test against 60 non-aliased, canonical
  `-USD` symbols captured 500+ consecutive `data_quality` notices and zero `Quote`s in a
  20-second window. `build_quote/2` read `ticker["time"]` — a field that does not exist
  on the row. Confirmed against Coinbase's own CDP API reference for the `ticker`
  channel, independently, twice: the timestamp lives on the *message envelope*
  (`"timestamp"`, one per frame), never on the individual `tickers` row. Every hand-built
  test fixture in this package — including the ones ported from the host adapter's own
  test suite (`baseline_test.exs`, "Phase 5.7") — encoded the identical wrong assumption,
  which is why this passed every test ever written against it and only ever failed
  against a genuine live socket. `dispatch/2` now reads the envelope's own `timestamp`
  and threads it down to `build_quote/3`; the per-row field is gone.

  Applied the same fix to `l2_data`/`OrderBook`, which had a related but different
  defect: `deliver_book/2` didn't read *any* venue timestamp — it substituted
  `DateTime.utc_now/0` unconditionally, which is the exact substitution this file's own
  moduledoc already named as wrong for the ticker path (`Core.Types.Quote`'s "never
  substitute now" principle) while doing it anyway one function down. `deliver_book/3`
  now reads the same envelope `timestamp` and fails closed if it's absent, same as
  `build_quote/3` — the maintained book state still updates either way, only the
  outgoing delivery is withheld.

  **Does not, on its own, explain why `level2`/`OrderBook` delivered zero data in any of
  the three live tests run while chasing #22** — the old `DateTime.utc_now/0` fallback
  always succeeded, so this was never why level2 was silent there. That remains open.

- **A `level2` capacity refusal from the venue was reported as `:credentials_rejected`
  — DpCryptoManagement's issue #22, filed as a suspected regression of #20.** Coinbase
  answers both a genuine auth failure and "too many L2 streams requested in a single
  session" through the identical `{"type":"error","message":...}` frame shape.
  `Socket.dispatch/2` collapsed both into `:credentials_rejected` — the shape the
  original stub-token incident produced — which sent a consumer that finally wired
  `subscribe_notices/1` looking for a broken credential that was never broken. Now
  classified by message content: a capacity refusal reports `:rate_limited`, Core's own
  kind for pressure rather than identity: everything else keeps the original
  `:credentials_rejected` behavior.

  **This does not, on its own, explain or fix why 4 of 5 shards deliver nothing.** #20's
  fix addressed a genuine, confirmed bug (an unstaggered connect burst) but issue #22's
  live evidence — the refusal persisting unchanged across 15+ minutes and two clean
  restarts, with every socket healthy and connected — describes a *permanent* per-shard
  rejection, not the *transient* reset #20 targeted. Whether Coinbase enforces `level2`
  session capacity per account rather than per connection, which would make multi-socket
  sharding for this channel fundamentally incompatible with this venue regardless of
  spacing, is not something this repository can verify without live credentials. Left
  open pending that evidence.

- **A scope wide enough to need three or more shards opened them all in the same
  instant instead of staggered, and 60-second resubscribes re-issued the same burst
  every minute — DpCryptoManagement's issue #20, a real ~406-symbol/5-shard production
  scope where 4 of 5 shards (400 symbols) never delivered a single tick while the fifth
  did.** `reshard/1` scheduled every shard past the synchronous first one with the
  *same* fixed `@shard_spacing_ms` delay rather than one increasing per shard, so all of
  them opened together — exactly the connect burst this module's own moduledoc already
  named as the failure the venue answers with resets. Only a suite exercising three or
  more shards could have caught it; the existing test only ever covered two (one
  synchronous, one staggered), where a single fixed delay is indistinguishable from a
  correct one. Fixed by scheduling each shard's turn `position * @shard_spacing_ms`
  after the one before it, applied to both the initial open and the unconditional
  60-second resubscribe. A regression test now exercises three shards.

- **`Feed.fan_out/2` crashed on a subscriber registered by name — DpCryptoManagement's
  issue #15.** `subscribe/2`'s `to:` option accepts any value, and `fan_out/2` called
  `Process.alive?/1` on it directly — which only accepts a pid and raises on anything
  else. A consumer registering itself under a name (ordinary OTP practice) and handing
  that name to `to:` crash-looped the whole `Feed` GenServer on every delivery. Fixed by
  resolving a subscriber (pid or name) to a pid first, treating an unregistered name the
  same as a dead pid: silently skipped, never a crash.

- **`feed_test.exs`'s own fake sockets never answered `WebSockex.send_frame/2`'s
  internal `:gen.call`, silently turning several tests into a real, load-dependent race
  against two independent ~5-second timeouts** (WebSockex's own hardcoded one and
  `:sys.get_state/1,2`'s default) rather than a fast, deterministic assertion — the
  file's slowest tests ran 5–15 real seconds each and occasionally lost the race outright
  under load from the rest of the suite. Not flakiness to route around: traced to a
  root cause and fixed there. One fake now replies immediately per `:gen`'s own reply
  protocol (removing the stall entirely); the other, which intentionally models a socket
  whose frames fail, now fails **immediately** rather than by never replying. Full
  `feed_test.exs` run time: ~45s → ~3s.

- **`to_order/1` read both `Order.quantity` and `Order.filled_quantity` from the same
  venue field — DpCryptoManagement's issue #12.** `order["filled_size"]` populated both,
  so a fetched order's `remaining_quantity` (quantity minus filled) was always zero, even
  for a genuinely open, partially-filled order — a correctness bug for anything
  reconciling open-order state. `quantity` now reads the venue's own record of what was
  requested, from `order_configuration`'s leaf `base_size` — the same field
  `closing_configuration/1` already reads for a closing order's size, on the same
  response envelope. A quote-sized market order's leaf carries `quote_size` instead, with
  no rate here to convert it, so `quantity` is `nil` rather than a guess in that case.

### Added

- **`level2` is subscribed and decoded — `streamable` gains `:order_book`.** The channel
  was recognised and had working auth machinery since an earlier release but was never
  actually requested; `capabilities/0` said `[:quotes]` while the code that would have
  served `:order_book` sat unused. `Socket` now maintains a real per-symbol book —
  snapshot then patched by `update` deltas, `new_quantity: "0"` removing a level — and
  delivers `Core.Types.OrderBook` sorted best-price-first on every change, matching this
  family's existing convention (see Schwab's book services) of emitting on every venue
  frame rather than throttling client-side.

- **Sharded — this venue's whole subscription no longer runs on one socket.** Measured
  2026-08-27 against a live ~400-symbol universe: a `level2` subscribe over the venue's
  real per-session limit gets `"too many L2 streams requested in a single session"` and
  the socket closes, a total data gap rather than degraded coverage — 355 of 405 pairs
  went stale, 1,480 refusals in one log window. `Feed` now opens one socket per 100
  symbols (the number from that incident, carried over rather than re-derived), spaced
  to avoid a connect burst, `level2` subscribed before `ticker` on each and the two
  spaced apart so a snapshot decode in progress does not turn a `ticker` subscribe into
  a `send_timeout`.

- **A reconnect now resubscribes.** WebSockex reconnects a dropped socket on its own and
  leaves it subscribed to nothing — silently, since a connected socket receiving
  nothing looks the same as a quiet market. `Feed` re-issues every shard's current
  subscriptions on a 60-second timer, unconditionally; the reference implementation this
  replaces lost a venue's entire coverage to exactly this gap for roughly forty minutes
  before anyone noticed the chart had gone flat.

- **`level2` is skipped for a credential-less subscriber rather than failing loudly for
  no reason.** It requires a credential and `ticker` does not; a caller with no
  credentials only ever wanted the public channel, and sending a doomed authenticated
  subscribe would either surface `credentials_required` as this call's synchronous
  result — masking that `ticker` works fine — or cost a wire round trip to learn what
  the credential's absence already answers.

### Documentation

- **The `:unsupported` list is now split.** `venue_does_not_serve/0` names the 38 endpoints
  that are Coinbase's own absence — staking reads, the one-step convert, funding rails,
  option chains, watchlists — each with the source and date behind it; three
  (`get_funding/2`, `get_contract_stats/2`, `list_instruments/1`) stay under `@not_ported`
  because they are the venue's surface and this package's backlog, not the venue's gap.
  Robinhood found four callbacks mislabelled the other way; this pass checks Coinbase's own
  list rather than assume it was filed correctly the first time.
- **`README.md` states what the contract covers** — 46 of 87 callbacks `:experimental`, and
  points at `negative-claims.md` for every absence's source.
- **`docs/reference/coinbase/endpoint-inventory.md`'s counts refreshed.** It read "everything
  authenticated is absent" until this release, which had been true at capture and stopped
  being true as this package grew — the vendor-side numbers had not moved, this package's
  coverage of them had, and the section conflated the two.

### Documentation

- **Every negative this package makes is audited** —
  `docs/reference/coinbase/negative-claims.md`, twelve claims with the source and date
  consulted for each. Nine hold; **three were wrong**, and all three for the same reason:
  each was a true statement about one endpoint restated as a claim about the venue.

  `supports_order_preview: false` and `supports_order_replace: false` were assumed without
  reading the list the endpoints are on — the second mattered more, because it told a caller
  to cancel and re-place, opening a window in which no order is live. And
  `get_trade_volume/2`'s "Advanced Trade does not aggregate" was read off
  `/products/volume-summary`, which is *market* volume and a different question.

  The check that would have caught all three is the one the table now enforces: **name the
  endpoint you looked at, and the date.**

- **`usage-rules.md` gains the surface this release added** — the two accounts a futures
  position is margined from, Prime's separate host and credential triple, convert's absent
  expiry, portfolios as addresses, and the fee/volume pair.

- **`AGENTS.md` gains a pointer** to this package's own `usage-rules.md`, so a reader who
  opens the generated file knows where the package's rules actually are.

### Changed

- **Core dependency moves to `~> 0.1.36`**, and `place_orders/3` is declared **absent with
  the reason**: this venue places one order per request. A batch is one request the venue
  accepts or rejects as a unit, and a caller placing several here calls `place_order/3`
  several times and reconciles the outcomes itself.

### Added

- **Key permissions and the server clock** — `get_roles/1`, `get_server_time/1` and a
  `test_connection/2` that is no longer declared absent.

  **`can_transfer` is a separate permission from `can_trade`**, and a key routinely holds one
  and not the other. Asking is cheaper than discovering a missing one from a refused
  withdrawal. The response also names **the portfolio the key is scoped to**, which is where
  a caller finds out whose balance it has been reading.

  **`test_connection/2` asks two different questions and picks by what it was given.**
  Without credentials it reads the public clock — reachability alone. With them it reads the
  key's permissions, which fails if the key is wrong and answers what the key can do if it is
  right. An unreachable venue and an unaccepted key are different problems.

  `get_server_time/1` returns the venue's own map **undiffed**. The difference a caller cares
  about is against its own clock at the moment it asked, and computing it inside the package
  would hide the round trip in the number. It is worth reading at all because this venue's
  JWT window is two minutes: a host clock further out than that produces authentication
  failures that look like a credential problem.


- **Convert, portfolios and the transaction summary** — the last ten Advanced Trade
  endpoints in the coverage plan's Phase 11.

  **Convert is the facade's only two-step operation, and Advanced Trade states no expiry at
  all.** `expires_at` is `nil`, which means "not stated" and never "open-ended": a caller
  committing a lapsed quote can be filled at the *current* rate rather than refused, which is
  the dangerous outcome because the operation looks like it succeeded and every number is
  real. `commit_conversion/2` and even `get_conversion/2` **re-ask for both accounts** — the
  venue's own rule, unusual for a read — and this package fills neither in: a conversion
  committed against accounts the caller did not name happens between the wrong two balances.
  A status this package does not know maps to `nil`, never the nearest one.

  **A portfolio is an address, not a value.** `list_portfolios/1` returns them,
  `get_portfolio_breakdown/3` returns what is *inside* one — a different and much larger
  answer — and `create_account/1` and `rename_account/3` reach the portfolio endpoints,
  because Advanced Trade has no notion of creating an *account*. **Deleted portfolios stay in
  the listing**: the venue keeps them because old orders still name their ids, and filtering
  them out would make a historical id look like one that never existed.

  **`get_trade_volume/2` was declared absent on a claim that was wrong.** This package held
  that "Advanced Trade does not aggregate" the account's own volume; the transaction summary
  does, in `volume_breakdown` per volume type with `advanced_trade_only_volume` and
  `coinbase_pro_volume` beside it. The claim had been made from the *market* volume
  endpoint's absence, which answers a different question. The two account totals ride
  alongside the breakdown rather than being folded in: the venue documents the first as
  non-inclusive of the second, so adding either to the breakdown double counts.

  `get_fees/2` carries **both** `fee_tier` and `fee_tier_without_promotion` — they differ
  while a promotion is running, and it can end between two calls — and keeps the tax's
  `INCLUSIVE`/`EXCLUSIVE` flag, because the same rate quoted either way is a different amount
  of money.


- **US derivatives — the nine CFM endpoints.** `get_positions/1` and
  `list_futures_positions/1`, `get_futures_position/3`, `get_futures_balance_summary/2`,
  the three sweep calls, and the three intraday-margin calls.

  **Two accounts, and the balance summary names both.** Futures margin from an account held
  with Coinbase Financial Markets; spot sits in one held with Coinbase Inc. `cfm_usd_balance`
  is the first, `cbi_usd_balance` the second, `total_usd_balance` the pair — and a caller
  sizing a futures position against the total is sizing against money that is not there.
  Every amount keeps its `currency`; flattening it off is how two currencies get added.

  **`:realised_pnl` is `nil` on a `Types.Position` from this venue, and that is not an
  omission.** Coinbase publishes `daily_realized_pnl` — what the position realised *today* —
  and no lifetime figure. Putting a daily number in a field that means the position's answers
  a different question under the same name: a caller summing it across reads counts one day
  repeatedly. The daily figure is not discarded — `list_futures_positions/1` returns the
  venue's own row, where it keeps its own name, along with `expiration_time`, which
  `Types.Position` has no place for either because a future expires and a perpetual does not.

  **A sweep is scheduled, not settled.** `schedule_futures_sweep/2` queues a move out of the
  futures account and `list_futures_sweeps/2` reports the queue; a listed sweep has not
  happened. **Omitting the amount sweeps every available excess dollar** — the venue's
  documented default, stated here because a caller reading a missing amount as "nothing"
  would move the lot. `cancel_futures_sweep/2` cancels *the* pending sweep and takes no id.

  **`INTRADAY_MARGIN_SETTING_UNSPECIFIED` is not `_STANDARD`.** It is the venue declining to
  say, and mapping it to the safer-sounding value would assert a setting the account may not
  have. The venue's own strings are returned and required on the way in, with no default:
  `UNSPECIFIED` is a value in the enum, and choosing it for a caller would set the account to
  something it did not ask for.

  `get_current_margin_window/2` carries both kill-switch flags. An account that believes it
  is on intraday margin while the switch is enabled has more leverage in its plan than in its
  account.

  `supported_instrument_types` gains `:future`. `:perp` stays absent: Advanced Trade's
  perpetuals are the INTX endpoints, which are `APPROVED-SKIP` as deprecated, and declaring a
  surface this package does not reach would be a claim about the venue standing in for one
  about the package.


- **Coinbase Prime custodial staking** — `DpExchange.Coinbase.Prime`, all nine endpoints,
  with `stake/3` and `unstake/3` now live on the facade.

  **A different product, host and signing scheme.** Everything else in this package talks to
  `api.coinbase.com/api/v3/brokerage` and signs a CDP JWT; Prime talks to
  `api.prime.coinbase.com/v1` and signs an HMAC under an access key, a passphrase and a
  signing key that Advanced Trade neither issues nor accepts. Two of the three credentials
  is `{:error, :missing_prime_credentials}` rather than a request that is signed and wrong.

  **These are not the CDP Staking API.** Those seven are on-chain: they take a wallet
  address and return **unsigned transactions for the caller to sign and broadcast**.
  Reaching them through `stake/3` would be this family's recurring failure at its most
  expensive — a caller believing it had staked while holding a transaction nobody sent.

  **Two scopes, and this package picks neither for you.** Prime publishes every staking
  operation across a portfolio and again on one wallet, and the two are not interchangeable:
  a portfolio-scoped unstake redeems across every wallet in the portfolio. `stake/3` and
  `unstake/3` follow only what the caller said — a `:wallet_id` means the wallet, its
  absence means the portfolio — and `opts[:portfolio_id]` is required, refused as
  `{:error, :missing_portfolio}` before a request is made.

  Four callbacks stay declared **absent with the reason**: Prime publishes no rate schedule
  and no staking history at either scope; `staking/status` names one wallet and is not
  "every staked position, one per asset" (reachable as `Prime.staking_status/4`); and
  `claim_rewards` is a write that moves accrued rewards, not a report of what accrued.

  **Nothing here has been run against Prime.** The paths are read from the vendor's pages on
  2026-08-31 — thirteen pages, nine endpoints, four pairs documenting one path under two
  names — and the signing scheme from Prime's authentication documentation. This repository
  holds no Prime credential and money-moving endpoints are answered in production, not by a
  test here. Responses come back as the venue's own maps for the same reason: a
  `Types.StakingBalance` built from an unverified field name is a plausible number in the
  wrong field.


- **Payment methods and the internal move**: `list_payment_methods/2`,
  `get_payment_method/3` (`GET /payment_methods`, `GET /payment_methods/{id}`) and
  `transfer_internal/4` (`POST /portfolios/move_funds`).

  **A payment method's flags disagree with each other.** Each row carries `verified`,
  `allow_deposit` and `allow_withdraw`, and a method verified for deposit is routinely not
  verified for withdrawal. Rows stay the venue's own maps and no "usable" boolean is
  synthesised from them — collapsing the flags is what makes a caller move fiat through a
  method the venue refuses.

  **`get_payment_method/3` is the read; the listing is a snapshot.** A method's state
  changes without the account doing anything, and selecting the row out of an earlier
  listing answers with whatever was true when that listing was taken.

  **`transfer_internal/4` moves nothing off Coinbase** — no chain, no address, no network
  fee. Both portfolio uuids are required and neither is defaulted: a move missing either is
  `{:error, :missing_portfolio}` before a request is made, because the alternative is
  shifting funds between portfolios the caller never named. The amount is sent in full
  notation, since `Decimal.to_string/1`'s scientific form is not a number this venue reads.

### Changed

- **Core dependency moves to `~> 0.1.33`**, and with it twelve callbacks are now declared
  rather than missing. Nine are declared **absent with the reason**, checked against the
  venue's own reference on 2026-09-01: Advanced Trade publishes no allowlist
  (`request_approved_address/4`, `remove_approved_address/3`), no networks list
  (`list_networks/2`), no fiat registration (`add_payment_method/2`), no fee promotions
  (`list_fee_promos/1`), no FX publication (`get_fx_rate/3`), no notional valuation
  (`get_notional_balances/3`) and no custody product (`list_custody_fees/2`).

  **`get_transactions/2` is absent for a different reason worth stating.**
  `/transaction_summary` exists and is *not* it: that endpoint reports what the account
  traded in a window and what it cost, not an enumeration of deposits, fees and
  adjustments. Returning it here would have answered a different question while looking
  like this one.


- **`quantization/1` — what the venue will actually accept**, and `Rest.get_product/2` for
  the whole record. Both were `:unsupported`.

  **The venue names four increments and they are not interchangeable.** `quote_increment`
  bounds the *price* and `base_increment` the *quantity*; a caller rounding a price to the
  base increment produces an order the venue rejects on a field it did not name. Both
  minima are carried too — `base_min_size` is units and `quote_min_size` is cash, and a
  market order sized in cash is bounded by the second where a limit order in units is
  bounded by the first.

  `status` is the venue's own word, unmapped: a boolean would lose the difference between a
  product that is paused and one that is gone.

- **`get_symbols/1` reads the authenticated catalogue when a credential is present.** Third
  and last of the public/private path corrections — the book, the candles and now the
  product list were all reading `/market/…` regardless.


- **`get_trades/2` — the public tape.** `get_price/2` already reads this payload and keeps
  only the newest print, because a `Quote` has room for one price; the rest were discarded
  at the boundary. This returns them.

  Not `get_trade_history/2`, which is the credential's own fills. `broken` is `false` on
  every print — the ticker publishes no bust flag, and a venue with nothing busted reports
  nothing busted.


- **`get_historical_prices/4` reads the authenticated candles path when a credential is
  present.** The venue publishes the same candles twice — `/market/products/…` public and
  `/products/…` for a credential — and this always called the public one, so a caller
  holding a credential was silently forgoing whatever the authenticated view adds. Same
  correction as the product book.

- **`get_order_book/2` — depth, which this package declared `:unsupported`.**
  `GET /product_book` for a credential and `/market/product_book` without one — the venue
  publishes the same book twice, and reading the public one while holding a credential
  would silently forgo whatever the authenticated view adds. The venue's `limit` and
  `aggregation_price_increment` are passed
  through.

  **Both sides come back as the venue ordered them.** Re-sorting would hide a venue that
  sent a crossed or out-of-order book, which is exactly the thing worth seeing.

  **A book the venue did not date is refused.** A depth snapshot carrying the client's clock
  cannot be told apart from a current one, and a stale book read as current is the most
  expensive wrong number here. `sequence` stays `nil` — the endpoint publishes none, and a
  caller must not learn to detect stream gaps from a REST book.

### Fixed
- **`get_top_of_book/2` now carries the sizes.** It read `/products/{id}/ticker`, which
  publishes `best_bid` and `best_ask` and nothing about how much is there — so `bid_size`
  and `ask_size` were `nil` on every response.

  That `nil` was honest and it was avoidable: the venue publishes `/best_bid_ask`, whose
  pricebook carries the size at each level. **A price without a size is half a top of
  book** — a caller sizing against the best bid needs to know whether there is 0.01 there
  or 40, and `nil` gave it no way to ask.

  An empty side is still `nil` rather than zero: one side of a book can genuinely be empty,
  and zero would claim someone is quoting nothing at a price of nothing.


- **`get_trade_history/2` — past fills.**

  **`trade_type` is not decoration.** Regular fills carry `FILL`; the venue also emits
  `REVERSAL`, `CORRECTION` and `SYNTHETIC` for adjusted ones, and a reversal is not a trade
  that happened. `Core.Types.Fill` has no field to say which is which, so summing a mixed
  list produces a position and a cost basis that are both wrong and both plausible. This
  returns **only `FILL` rows by default**, and `opts[:trade_types]` widens it — returning
  all four under a type that cannot distinguish them would be a substitution, and refusing
  them entirely would hide corrections the venue made.

  A fill the venue did not date is **refused**, not stamped with the local clock: a fill is
  an event at a moment, and a client timestamp places it wrongly in a history while looking
  entirely reasonable.

  `fee_currency` is `nil` rather than the pair's quote guessed from the symbol — a fee can
  be charged in a third asset and often is. `UNKNOWN_LIQUIDITY_INDICATOR` maps to `nil`,
  because neither `:maker` nor `:taker` is an honest answer to the venue saying it does not
  know.

  Filters go to the venue rather than being applied to the page it returned, and the walk
  follows `cursor` to a page bound.


- **`get_balances/2` and `get_accounts/2`.** The package could not say what the credential
  holds.

  **The venue reports `available_balance` and `hold` and no total.** The total here is
  their sum — arithmetic on two numbers the venue stated, not an estimate — and it is `nil`
  when either is missing rather than the other one alone. "Available 1.25, total unknown"
  and "total equals available" are different claims, and a consumer sizing against the
  second when the first is true trades against money that is held.

  **The endpoint pages, at 49 by default and 250 at most, and this follows the cursor.** A
  caller reading one page holds some of its balances with nothing to say which are missing,
  and every number on that page is real — which is what makes stopping there worse than
  failing. `@max_account_pages` bounds it, so a server that always says `has_next` errors
  rather than looping inside a facade call.

  `get_accounts/2` is separate because an account is more than a number: a caller routing an
  order needs the uuid and the platform, and a caller sizing one needs the balance.
  Collapsing them would lose the first. `opts[:uuid]` reads the single-account endpoint.

  `:timestamp` is when the request was made — a balance has no venue event time.


- **`convert/4` and `get_trade_volume/2` (Core 0.1.22) are declared unsupported, with the
  reasons checked.** Advanced Trade's convert is the **two-step** form —
  `POST /convert/quote`, `POST /convert/trade/{id}`, `GET /convert/trade/{id}` — which is
  `quote_conversion/4` and friends, scheduled separately. The one-step `POST /conversions`
  belongs to the **Exchange** API, a different product this package does not reach.
  `/products/volume-summary` is market volume and lives there too; `get_trade_volume/2`
  asks what *this account* traded, which Advanced Trade does not aggregate.

- **`preview_replace/4` and `close_position/3`.** Two documented endpoints this package had
  no facade for.

  `POST /orders/edit_preview` prices an amendment before it is made. It is not
  `preview_order/3` with an order id: the venue prices the amendment against the resting
  order's own state, including whatever of it has already filled, and its response carries
  `average_filled_price` and `order_margin_total` — numbers a fresh order does not have.
  It takes the same `:price` / `:quantity` change set `replace_order/4` does and refuses
  anything else before the request.

  `POST /orders/close_position` flattens a position by having the venue place the closing
  order. **The returned `Order` carries no side.** The venue never states one, and it
  worked the side out from a position this package did not read — filling in `:sell`
  because closing is usually selling is wrong exactly where it matters, on a short. The
  order type, time in force and size *are* read, from the `order_configuration` the venue
  echoes back, and a configuration key this package does not recognise leaves them `nil`
  rather than picking the nearest.

### Fixed

- **`cancel_all_orders/2` is declared unsupported, with the reason checked.**
  `POST /orders/batch_cancel` takes an explicit `order_ids` list — it is the endpoint
  `cancel_order/3` already uses, one id at a time. There is no "cancel everything" call
  here, and assembling one from `get_orders/2` plus a batch would be N partial outcomes
  with no way to reach an order that appeared between the listing and the cancel.

- **BREAKING: `get_historical_prices/4` returns `Core.Types.Candle`. It was returning
  `Quote`s with `price: close`.**

  The venue sends open, high, low and close for every bar. Three of them were discarded
  here, at the boundary, where no caller could see it happen — and everything that came out
  was a real number, so nothing looked wrong. A caller reading `price` was holding one
  corner of a bar with no way to learn it.

  **This is the same defect the coverage plan's 2.10 found in Schwab**, with the same
  reasoning behind it, still live here after that one was fixed. The fake had it too: it
  returned `get_price/2`'s `Quote`, so the suite agreed with the bug it existed to catch.

  Bars now carry all four prices and `:opened_at` — the venue's own bucket start, used
  as-is. A bar the venue did not date is refused with `:missing_venue_timestamp` rather
  than stamped with the local clock, which would place it wrongly while looking right.


### Fixed
- **This package claimed the venue has no order preview and no atomic replace. It has
  both.** `supports_order_preview` and `supports_order_replace` were declared `false` on
  those claims, and neither was checked against the venue's reference. Coinbase publishes
  `POST /orders/preview` and `POST /orders/edit`; both flags are now `true` and both
  endpoints are implemented.

  The replace claim was the worse of the two. Its moduledoc called
  `supports_order_replace: false` "a claim about **risk** rather than convenience", because
  cancel-then-replace opens a window in which no order is live. The risk was real and the
  claim was wrong: **the package was describing a hazard it was creating by not implementing
  the endpoint that avoids it.**

### Added
- **`preview_order/3`** builds the same `order_configuration` as `place_order/3`, so a
  preview is a preview of the order that would actually be sent. **A `200` carrying a
  populated `errs` is a refusal** — returning it as a successful preview would tell a caller
  its order is fine when the venue has already said otherwise. A `warning` is passed through
  and does *not* make it a refusal.
- **`replace_order/4`** edits price or size in place. **Any other change is refused rather
  than dropped**: a caller trying to change the side is describing a different order, and
  editing only the price would leave it holding one it did not ask for. The venue's edit
  response carries no order body, so the order is **read back** rather than reconstructed
  from the request — reporting what was asked for as though the venue had confirmed it is
  the mistake this whole contract is written against.

### Added
- **`cancel_order/3`, `get_order/3`, `get_orders/2`.** The order lifecycle, where there was
  none.

  **Cancellation is a batch endpoint that refuses per order.** `POST /orders/batch_cancel`
  answers with a `results` array carrying its own `success` and `failure_reason` per id, so
  a `200` says nothing about whether anything was cancelled. A batch of one is still a
  batch. An order already filled comes back as a **refusal**, not an `:ok` — "I cancelled
  it" and "it was not there to cancel" are different facts, and a caller retrying on the
  second is chasing nothing.

  **`CANCEL_QUEUED` maps to `:open`, not `:cancelled`.** An order accepted for cancellation
  is still live until the venue says otherwise; reporting it gone invites a second order for
  the same exposure.

  **A status, side, order type or time-in-force this package does not recognise is `nil`,
  never the nearest atom.** A venue adding a word later produces an absent field rather than
  a plausible wrong one.

  `get_orders/2` filters at the venue rather than in this package — a client-side filter
  over one page would silently drop matching orders sitting on the next. **It returns one
  page and does not follow the cursor**, which is stated rather than left for a caller to
  discover while reconciling.
- **`place_order/3`.** This venue could not place an order; it can now.

  Coinbase names the order type and the time-in-force in a **single key** —
  `limit_limit_gtc`, `market_market_ioc`, `stop_limit_stop_limit_gtd` — and the set of names
  is sparse. There is no `limit_limit_ioc`, no `market_market_gtc`.

  **A pair the venue does not name is refused before the request is sent.** Sending
  `{:limit, :ioc}` as `limit_limit_fok` would place an order that fills-or-kills where the
  caller asked for immediate-or-cancel, and every field in the request would look right.

  Three further refusals rather than defaults: a limit without a price, a stop-limit without
  a stop price, and a market order sized in neither base nor quote. `post_only` is omitted
  when unset rather than sent as `false`, because silence is not a decision to take
  liquidity.

  A `200` carrying `success: false` is a **refusal**, not a placed order.

  `client_order_id` is the venue's idempotency key: a caller's own is passed through, and a
  v4 UUID is generated from the VM's CSPRNG when absent.

### Added
- `DeprecatedEndpointsTest` — fails the build if any code path constructs one of Coinbase's
  six vendor-deprecated INTX endpoints. They are absent today; nothing kept them absent.
- `docs/reference/coinbase/endpoints-enumerated.tsv` and a rewritten inventory: the documented
  surface is **712 REST operations and 46 socket channels**, enumerated endpoint by endpoint
  from all 806 reference pages, replacing a page count. **Deribit alone was recorded as 37 and
  is 115** — Coinbase renders it as twelve sibling trees with no `deribit` in their paths.
- Prime's custodial staking enumerated: **13 documentation pages, 9 endpoints**, four pairs
  being duplicate pages for one path.

### Added
- Repo scaffold from the DpExchange standard; extraction pinned to the host's
  `553fa787` with its working-tree state recorded, since the Coinbase subtree was dirty
  at extraction time.

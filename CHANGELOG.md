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

### Added

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

### Fixed

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

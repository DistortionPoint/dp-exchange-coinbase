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

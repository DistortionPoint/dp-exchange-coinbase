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

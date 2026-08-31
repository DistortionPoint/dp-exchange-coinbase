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

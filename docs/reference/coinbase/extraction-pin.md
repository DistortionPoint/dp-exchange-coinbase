# Extraction pin — the exact host state this package was extracted from

Recorded 2026-08-28T14:19:09Z at Phase 5.2 (D19).

The host is under active development, so a commit alone does not identify what was
read: **the working tree was dirty at extraction time**, and the uncommitted changes
are part of what was extracted. Both are recorded.

## Commit

```
repository: dp_crypto_management
branch:     master
HEAD:       553fa787ad36d7b962d51e90ae965bfa0e801b64
committed:  2026-08-25T13:16:32-05:00
subject:    feat(influx): write stream — 42% of all price data is currently being discarded
```

## Working-tree state of the Coinbase subtree

**Dirty.** Six tracked files modified and one test file untracked. Content hashes of
what was actually read, so a later drift check can tell a real change from a rebase:

| File | Git state | SHA-256 of the file as read |
|---|---|---|
| `lib/dp_crypto_management/connectors/exchanges/coinbase/feed.ex` | `M` | `39109428039542b5…` |
| `lib/dp_crypto_management/connectors/exchanges/coinbase/feed/coordinator.ex` | `M` | `da86a45c79805b94…` |
| `lib/dp_crypto_management/connectors/exchanges/coinbase/provider.ex` | `M` | `20fe46a9a134fe20…` |
| `lib/dp_crypto_management/connectors/exchanges/coinbase/websocket_provider.ex` | `M` | `64c5c50ccf77e804…` |
| `test/dp_crypto_management/connectors/exchanges/coinbase/coinbase_websocket_provider_coverage_test.exs` | `M` | `6b9c2d21ef530e0e…` |
| `test/dp_crypto_management/connectors/exchanges/coinbase/coinbase_websocket_provider_extra_test.exs` | `M` | `6af4be036a0b38cb…` |
| `test/dp_crypto_management/connectors/exchanges/coinbase/feed_test.exs` | `??` | `722e290f7edb6165…` |

## Every file in scope, clean or not

| File | Lines | SHA-256 |
|---|---:|---|
| `feed.ex` | 181 | `39109428039542b5…` |
| `coordinator.ex` | 311 | `da86a45c79805b94…` |
| `provider.ex` | 1508 | `20fe46a9a134fe20…` |
| `symbol_format.ex` | 33 | `fbbc12cd79b153d1…` |
| `websocket_provider.ex` | 1292 | `64c5c50ccf77e804…` |

## Test corpus in scope

| File | Lines |
|---|---:|
| `coinbase_provider_additional_test.exs` | 511 |
| `coinbase_provider_boost_test.exs` | 167 |
| `coinbase_provider_coverage_test.exs` | 505 |
| `coinbase_provider_test.exs` | 234 |
| `coinbase_provider_v2_test.exs` | 421 |
| `coinbase_websocket_provider_comprehensive_test.exs` | 670 |
| `coinbase_websocket_provider_coverage_test.exs` | 456 |
| `coinbase_websocket_provider_extra_test.exs` | 762 |
| `coinbase_websocket_provider_test.exs` | 533 |
| `coinbase_ws_boost_test.exs` | 242 |
| `feed_test.exs` | 120 |

## How to drift-check before publishing (Phase 5.10)

Against the commit:

```bash
git log 553fa787ad36d7b962d51e90ae965bfa0e801b64..HEAD -- lib/dp_crypto_management/connectors/exchanges/coinbase/
```

Against the tree, which the commit range cannot see:

```bash
shasum -a 256 lib/dp_crypto_management/connectors/exchanges/coinbase/*.ex
```

A hash that changed on a file recorded dirty above means the uncommitted work moved
on after extraction — which the commit range will not show, because it was never
committed in the first place.

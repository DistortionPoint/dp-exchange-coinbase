# Every negative this package makes, and what was checked

**Audited 2026-09-01.** A negative is any statement that the venue *lacks* something: a
`:unsupported` declaration, a "there is no…", a "does not support…". §0's rule says a value
must never be substituted for a missing one; this is the same rule pointed at documentation.
**An unverified negative is a substitution exactly like an invented value.**

Two of this package's negatives turned out to be wrong, both found by this audit's own plan,
and both for the same reason: **the claim was made from the wrong endpoint's absence.**

## Sources

| source | what it is | read |
|---|---|---|
| **inventory** | `docs/reference/coinbase/endpoints-enumerated.tsv` — every documented endpoint, method and path from each page's own `pageMetadata.openapi` | 2026-08-31 |
| **pages** | `docs.cdp.coinbase.com/api-reference/advanced-trade-api/…`, rendered and read | 2026-09-01 |
| **Prime** | the Prime API's own pages, `docs/reference/coinbase/endpoint-inventory.md` §"Prime custodial staking" | 2026-08-31 |

## The negatives

| claim | verified against | verdict |
|---|---|---|
| No allowlist, no networks list, no fiat registration | pages, 2026-09-01 | **holds.** Addresses are managed in Coinbase's own interface; there is no path taking a network |
| No `get_transactions/2` | pages, 2026-09-01 | **holds, and the near miss is recorded.** `/transaction_summary` exists and is *not* it — it reports what the account traded in a window and what that cost, not an enumeration of deposits, fees and adjustments |
| No fee promotions, no FX publication, no notional valuation, no custody product | pages, 2026-09-01 | **holds** |
| No staking on Advanced Trade | inventory | **holds for Advanced Trade, and is not a claim about the venue.** Coinbase **Prime** publishes nine custodial staking endpoints, and this package now reaches them — see `DpExchange.Coinbase.Prime` |
| No one-step `convert/4` | inventory | **holds.** Advanced Trade publishes the two-step form (`/convert/quote`, `/convert/trade/{id}`), which is `quote_conversion/4` and friends and is implemented. The one-step `POST /conversions` belongs to the **Exchange** API, a different product |
| No batch order placement | pages, 2026-09-01 | **holds.** `POST /orders` takes one order; `/orders/batch_cancel` is a batch *cancel*, which destroys rather than creates |
| No bulk cancel-everything | pages | **holds.** `batch_cancel` takes an explicit `order_ids` list — it is the endpoint `cancel_order/3` already uses, one id at a time |
| `:perp` not supported | inventory | **holds for this package.** Advanced Trade's perpetuals are the `intx/*` endpoints, which are `APPROVED-SKIP` as deprecated. Declaring `:perp` would be a claim about the venue standing in for one about the package |
| **`supports_order_preview: false`** | pages | **WAS WRONG, corrected.** The venue publishes `/orders/preview` |
| **`supports_order_replace: false`** | pages | **WAS WRONG, corrected, and it mattered more than the first.** The venue publishes `/orders/edit`. The false claim told a caller to cancel and re-place, which opens a window in which no order is live — the package was describing a risk it was creating by not implementing the endpoint that avoids it |
| **`get_trade_volume/2` — "Advanced Trade does not aggregate"** | pages, 2026-09-01 | **WAS WRONG, corrected.** `/transaction_summary` carries `volume_breakdown` per volume type, plus `advanced_trade_only_volume` and `coinbase_pro_volume`. The claim had been made from `/products/volume-summary`'s absence, which is *market* volume — a different question |
| No public market data without a credential | pages | **holds.** The `/market/*` paths exist but this package signs everything; the declaration says `credential_benefit` rather than claiming the venue is closed |

## The pattern in all three mistakes

**Each was a true statement about one endpoint, restated as a claim about the venue.**
`/products/volume-summary` is market volume, so "no volume endpoint" was read off the wrong
one. Preview and edit were assumed absent without reading the list they are on. Prime's
staking was invisible because the search was scoped to Advanced Trade.

The check that would have caught all three: **name the endpoint you looked at, and the date.**
That is what this table is for.

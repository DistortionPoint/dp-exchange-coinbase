# Coinbase — endpoint inventory

**Source**: `docs.cdp.coinbase.com/sitemap.xml`, enumerated 2026-08-31; methods and paths
read from the vendor's own reference navigation. **Primary vendor documentation only.**

## The wider Coinbase surface — 712 REST operations and 46 socket channels

**Enumerated 2026-08-31, endpoint by endpoint.** This supersedes the page counts an earlier
version of this file carried. `api-reference` holds **806 pages**; 806 pages is not 806
endpoints, and the difference is now measured rather than estimated.

**Method.** Every page's own method and path are in its `pageMetadata.openapi` field, so all
806 were fetched and that field read. **Pages with no such field are index and guide pages** —
that is how the endpoint count is separated from the page count, rather than by guessing.
Two products publish machine-readable specs instead and were counted from those.

| product | REST operations | source |
|---|---|---|
| v2 (App API) | **195** | 146 `rest-api` + 49 `webhooks` |
| prime-api | **123** | per-page |
| Deribit | **115** | `coinbase-deribit-app-api/adv-starbase-openapi.json` |
| exchange-api | **87** | per-page |
| international-exchange-api | **60** | per-page |
| advanced-trade-api | **51** | per-page — **matches the hand count below exactly** |
| derivatives-api | **49** | `derivatives-api/rest-api/cde-spec.json` |
| rest-api (CDP platform) | **25** | onramp/offramp 11, staking 7, smart contracts 4, addresses 3 |
| business-api | **7** | per-page |
| **REST total** | **712** | |

| socket surface | channels | source |
|---|---|---|
| Deribit | **37** | `adv-starbase-asyncapi.json` |
| Advanced Trade | **9** | `advanced-trade-asyncapi.json` |
| **socket total** | **46** | |

**758 operations in all**, from 806 documentation pages. The full list with methods and
paths is committed beside this file as `endpoints-enumerated.tsv`.

### Advanced Trade at 51 is the check on the method

The per-page extraction returns **51** for `advanced-trade-api`, which is exactly the count
this file arrived at by hand. That agreement is the reason to trust the other eight numbers,
which were produced the same way and were never counted by hand.

### What is in scope, after D7 and D1

- **−11 onramp/offramp** — embedding a buy flow in a third party's app, `APPROVED-SKIP` (D7)
- **−6 INTX** — vendor-deprecated, `APPROVED-SKIP` (D1)

**695 REST operations and 46 socket channels are in scope.**

### Deribit is not where its name is

Only 38 pages sit under `coinbase-deribit-app-api`. Its API is rendered as twelve *sibling*
trees with no `deribit` in their paths — `trading`, `market-data`, `block-rfq`, `block-trade`,
`account-management`, `subscription-management`, `session-management`, `combo-books`,
`supporting`, `json-rpc-api`, `authentication`, `networks` — all of which render from
`adv-starbase-openapi.json` and use Deribit's JSON-RPC method names (`private-buy`,
`public-get_book_summary_by_currency`). An earlier count put Deribit at 37; **it is 115 REST
operations and 37 socket channels.**

**Counting a venue by URL prefix is as unreliable as counting it by product page.** The
vendor's information architecture is not the venue's capability model.

### Re-capturing the wider surface

```
curl -s https://docs.cdp.coinbase.com/sitemap.xml \
  | grep -oE '<loc>[^<]+' | sed 's|<loc>||' | grep '/api-reference/'
```

Then fetch each page and read `pageMetadata.openapi`; absent means an index page. The two
spec files are fetched directly:

```
/api-reference/coinbase-deribit-app-api/adv-starbase-openapi.json    # Deribit REST
/api-reference/coinbase-deribit-app-api/adv-starbase-asyncapi.json   # Deribit sockets
/api-reference/derivatives-api/rest-api/cde-spec.json                # derivatives REST
/api-reference/advanced-trade-api/advanced-trade-asyncapi.json       # AT sockets
```
### Staking is a separate product, and the venue does support it

An earlier pass of the coverage analysis searched Advanced Trade for staking endpoints,
found none, and concluded that Coinbase does not stake through its API. **That was wrong** —
it scoped the question to one product and drew a conclusion about the venue. Coinbase
publishes a dedicated **Staking API**:

```
POST  build a new staking operation
GET   get the latest staking operation
GET   get staking context
GET   fetch staking rewards
GET   fetch historical staking balances
GET   list validators
GET   get validator by id
```

Prime carries a further **13** staking endpoints (stake, unstake, delegate, claim rewards,
staking and unstaking status, preview unstake, list transaction validators), and Exchange
carries **3** stake-wrap endpoints for wrapped assets.

This matters beyond Coinbase: the closed extraction plan deferred the staking *functions*
until "more than one venue's implementation in hand", and on the evidence above the
precondition is met — Gemini's six plus Coinbase's seven.

## Counts

**Re-checked 2026-09-03. The table below is what this section read until this release, and
it was wrong by then — not because the venue count moved, but because this package did.**
It said "everything authenticated is absent" on a package that by 2026-09-01 implemented 46
of the contract's 87 callbacks, most of them authenticated. The fix is not a fresh page
capture — Advanced Trade's operation count has not moved — it is stating what changed on
this side of the boundary, which a vendor capture cannot do for itself.

**Current, from `capabilities/0`, checked 2026-09-03**: 46 `:experimental`, 41
`:unsupported`, of which 38 are the venue's own absence — see `negative-claims.md` — and
3 are genuinely not yet ported (`get_funding/2`, `get_contract_stats/2`, `list_instruments/1`).

The vendor-side counts below are unchanged since the original capture and still describe
Advanced Trade's own surface, not this package's coverage of it — read the two separately.

| | endpoints | in this package |
|---|---|---|
| Advanced Trade REST (`/api/v3/brokerage`) | **51** | **implements the callbacks that map onto it — see `capabilities/0` for the current count, not a number frozen at capture time** |

| group | endpoints | in this package |
|---|---|---|
| orders | 9 | most — place, get, cancel, list; no batch-place, batch has no atomic multi-cancel beyond the venue's own |
| futures (CFM) | 9 | not ported — `list_instruments/1`-adjacent |
| public | 6 | quotes, top of book, trades |
| products | 6 | symbols, instrument metadata |
| portfolios | 6 | not ported (`list_portfolios/1`) |
| perpetuals (INTX) | 6 | 0 — **vendor-deprecated**, and `supported_instrument_types` deliberately excludes `:perp` for it |
| convert | 3 | 0 — **the venue's absence**, not this package's; see Notes |
| payment methods | 2 | 0 — **the venue's absence** |
| accounts | 2 | balances |
| fees | 1 | 0 — read separately from `get_trade_volume/2`, which is now implemented |
| data API | 1 | 0 |

## Endpoints

`✓` marks what this package implements today.

```
  DELETE /api/v3/brokerage/cfm/sweeps
  DELETE /api/v3/brokerage/portfolios/{portfolio_uuid}
  GET /api/v3/brokerage/accounts
  GET /api/v3/brokerage/accounts/{account_uuid}
✓ GET /api/v3/brokerage/best_bid_ask
  GET /api/v3/brokerage/cfm/balance_summary
  GET /api/v3/brokerage/cfm/intraday/current_margin_window
  GET /api/v3/brokerage/cfm/intraday/margin_setting
  GET /api/v3/brokerage/cfm/positions
  GET /api/v3/brokerage/cfm/positions/{product_id}
  GET /api/v3/brokerage/cfm/sweeps
  GET /api/v3/brokerage/convert/trade/{trade_id}
  GET /api/v3/brokerage/intx/balances/{portfolio_uuid}
  GET /api/v3/brokerage/intx/portfolio/{portfolio_uuid}
  GET /api/v3/brokerage/intx/positions/{portfolio_uuid}
  GET /api/v3/brokerage/intx/positions/{portfolio_uuid}/{symbol}
  GET /api/v3/brokerage/key_permissions
✓ GET /api/v3/brokerage/market/product_book
✓ GET /api/v3/brokerage/market/products
  GET /api/v3/brokerage/market/products/{product_id}
✓ GET /api/v3/brokerage/market/products/{product_id}/candles
✓ GET /api/v3/brokerage/market/products/{product_id}/ticker
  GET /api/v3/brokerage/orders/historical/batch
  GET /api/v3/brokerage/orders/historical/fills
  GET /api/v3/brokerage/orders/historical/{order_id}
  GET /api/v3/brokerage/payment_methods
  GET /api/v3/brokerage/payment_methods/{payment_method_id}
  GET /api/v3/brokerage/portfolios
  GET /api/v3/brokerage/portfolios/{portfolio_uuid}
✓ GET /api/v3/brokerage/product_book
  GET /api/v3/brokerage/products
  GET /api/v3/brokerage/products/{product_id}
  GET /api/v3/brokerage/products/{product_id}/candles
✓ GET /api/v3/brokerage/products/{product_id}/ticker
  GET /api/v3/brokerage/time
  GET /api/v3/brokerage/transaction_summary
  POST /api/v3/brokerage/cfm/intraday/margin_setting
  POST /api/v3/brokerage/cfm/sweeps/schedule
  POST /api/v3/brokerage/convert/quote
  POST /api/v3/brokerage/convert/trade/{trade_id}
  POST /api/v3/brokerage/intx/allocate
  POST /api/v3/brokerage/intx/multi_asset_collateral
  POST /api/v3/brokerage/orders
  POST /api/v3/brokerage/orders/batch_cancel
  POST /api/v3/brokerage/orders/close_position
  POST /api/v3/brokerage/orders/edit
  POST /api/v3/brokerage/orders/edit_preview
  POST /api/v3/brokerage/orders/preview
  POST /api/v3/brokerage/portfolios
  POST /api/v3/brokerage/portfolios/move_funds
  PUT /api/v3/brokerage/portfolios/{portfolio_uuid}
```

## Notes

**The `market/` prefix is the public variant.** `/market/products/{id}/ticker` needs no
credential; `/products/{id}/ticker` is the account-scoped equivalent and 401s without one.
This package implements both forms of ticker and the public forms of products and candles.

**`/best_bid_ask` and `/product_book` are both implemented, and this note was stale.** It
previously said both were absent from this package, which was true when written and had
not been re-checked since; `get_top_of_book/2` and `get_order_book/2` are both
`:experimental` in `capabilities/0` today, not `:unsupported`.

**`/best_bid_ask` has no public form — measured live 2026-09-05, and this is the
exception in this table.** Every other endpoint above with a `market/` twin genuinely
serves both; this one does not:

    GET /api/v3/brokerage/best_bid_ask?product_ids=BTC-USD         -> 401
    GET /api/v3/brokerage/market/best_bid_ask?product_ids=BTC-USD  -> 404 Route Not Found

`get_top_of_book/2` therefore requires credentials and fails closed
(`{:refused, :missing_credentials}`) rather than sending an unauthenticated request that
would come back as an opaque 401. `/product_book` is not the same case: `market/product_book`
is real and public, and `get_order_book/2` reads it exactly like every other
public/private pair in this table.

**INTX perpetuals are marked deprecated by the vendor.** Implementing a surface being
removed is a question for the architect, not a decision to take here.

## Re-capturing

```
curl -s https://docs.cdp.coinbase.com/sitemap.xml | grep -oE '<loc>[^<]+' | sed 's|<loc>||' \
  | grep '/api-reference/advanced-trade-api/rest-api/'
```

Any single reference page carries the full navigation, so one fetch yields every
method-and-path pair:

```
grep -oE '(GET|POST|PUT|DELETE) +/api/v3/brokerage[a-zA-Z0-9_/{}]*' <page.html> | sort -u
```


## Prime custodial staking — 13 pages, 9 endpoints

Read 2026-08-31. This is the surface that makes Coinbase a *custodial* staking venue
comparable to Gemini; the CDP Staking API's 7 are on-chain and a different capability.

```
POST /v1/portfolios/{pid}/staking/initiate                            portfolio scope
POST /v1/portfolios/{pid}/staking/unstake                             portfolio scope
POST /v1/portfolios/{pid}/staking/transaction-validators/query        portfolio scope
POST /v1/portfolios/{pid}/wallets/{wid}/staking/initiate              wallet scope
POST /v1/portfolios/{pid}/wallets/{wid}/staking/unstake               wallet scope
POST /v1/portfolios/{pid}/wallets/{wid}/staking/unstake/preview       wallet scope
GET  /v1/portfolios/{pid}/wallets/{wid}/staking/unstake/status        wallet scope
POST /v1/portfolios/{pid}/wallets/{wid}/staking/claim_rewards         wallet scope
GET  /v1/portfolios/{pid}/wallets/{wid}/staking/status                wallet scope
```

**Thirteen pages, nine endpoints.** Four pairs document the same path under two names:
`claim-wallet-staking-rewards-alpha` = `request-to-claim-rewards-for-a-staked-wallet`;
`request-to-stake-currency-in-a-portfolio` = `request-to-stake-currency-portfolio`;
`request-stake-or-delegate` = `request-to-stake-or-delegate-a-wallet`;
`request-to-unstake-currency-across-a-portfolio` = `request-to-unstake-currency-portfolio`.

**Every operation exists at two scopes** — across a portfolio, or on one wallet. Gemini has
no equivalent split, so a shared `stake/3` has to decide which scope it means.

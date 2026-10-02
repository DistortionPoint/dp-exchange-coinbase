# Spec-example fixtures

Every fixture here is derived from Coinbase's own committed OpenAPI/AsyncAPI specs under
`docs/reference/coinbase/openapi/` — never from this package's own code, and never hand-tuned
to make a test pass. Where the spec documents a field's own `example`, that value is used
verbatim (including where it disagrees with its own `type:` — see "Spec self-contradictions"
below). Where a **required** field (or a field this package actually reads) has no vendor
example anywhere in its schema, a plausible value of the documented type was constructed by
hand and is listed under that fixture below, plus in `fills.md` with the literal values.

Regenerated with the local (unshipped, not a project dependency) tooling in this session's
scratchpad: `extract.js` walks a named operation's response/request schema; `fills.json`
supplies the manual fallbacks. Neither ships with the package — only the JSON fixtures and
this README do.

## Advanced Trade REST (`at-spec.yaml`)

### `at/get_market_trades.json`

- Operation: `GET /api/v3/brokerage/products/{product_id}/ticker` — `RetailBrokerageApi_GetMarketTrades`
  (`docs/reference/coinbase/openapi/at-spec.yaml:491`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.GetMarketTradesResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:7582`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_public_market_trades.json`

- Operation: `GET /api/v3/brokerage/market/products/{product_id}/ticker` — `RetailBrokerageApi_GetPublicMarketTrades`
  (`docs/reference/coinbase/openapi/at-spec.yaml:2608`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.GetMarketTradesResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:7582`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_candles.json`

- Operation: `GET /api/v3/brokerage/products/{product_id}/candles` — `RetailBrokerageApi_GetCandles`
  (`docs/reference/coinbase/openapi/at-spec.yaml:414`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.Candles` (`docs/reference/coinbase/openapi/at-spec.yaml:6455`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_public_candles.json`

- Operation: `GET /api/v3/brokerage/market/products/{product_id}/candles` — `RetailBrokerageApi_GetPublicCandles`
  (`docs/reference/coinbase/openapi/at-spec.yaml:2535`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.Candles` (`docs/reference/coinbase/openapi/at-spec.yaml:6455`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_products.json`

- Operation: `GET /api/v3/brokerage/products` — `RetailBrokerageApi_GetProducts`
  (`docs/reference/coinbase/openapi/at-spec.yaml:199`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.Products` (`docs/reference/coinbase/openapi/at-spec.yaml:9460`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$.products[].status (required, no vendor example)`

### `at/get_public_products.json`

- Operation: `GET /api/v3/brokerage/market/products` — `RetailBrokerageApi_GetPublicProducts`
  (`docs/reference/coinbase/openapi/at-spec.yaml:2348`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.Products` (`docs/reference/coinbase/openapi/at-spec.yaml:9460`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$.products[].status (required, no vendor example)`

### `at/get_product.json`

- Operation: `GET /api/v3/brokerage/products/{product_id}` — `RetailBrokerageApi_GetProduct`
  (`docs/reference/coinbase/openapi/at-spec.yaml:369`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.Product` (`docs/reference/coinbase/openapi/at-spec.yaml:9152`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$.status (required, no vendor example)`

### `at/get_public_product.json`

- Operation: `GET /api/v3/brokerage/market/products/{product_id}` — `RetailBrokerageApi_GetPublicProduct`
  (`docs/reference/coinbase/openapi/at-spec.yaml:2501`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.Product` (`docs/reference/coinbase/openapi/at-spec.yaml:9152`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$.status (required, no vendor example)`

### `at/get_accounts.json`

- Operation: `GET /api/v3/brokerage/accounts` — `RetailBrokerageApi_GetAccounts`
  (`docs/reference/coinbase/openapi/at-spec.yaml:10`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.GetAccountsResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:7488`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_account.json`

- Operation: `GET /api/v3/brokerage/accounts/{account_uuid}` — `RetailBrokerageApi_GetAccount`
  (`docs/reference/coinbase/openapi/at-spec.yaml:66`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.GetAccountResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:7482`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_payment_methods.json`

- Operation: `GET /api/v3/brokerage/payment_methods` — `RetailBrokerageApi_GetPaymentMethods`
  (`docs/reference/coinbase/openapi/at-spec.yaml:2661`)
- Response schema: `coinbase.retail.rest.proxy.payment_method.GetPaymentMethodsResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:10547`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_payment_method.json`

- Operation: `GET /api/v3/brokerage/payment_methods/{payment_method_id}` — `RetailBrokerageApi_GetPaymentMethod`
  (`docs/reference/coinbase/openapi/at-spec.yaml:2692`)
- Response schema: `coinbase.retail.rest.proxy.payment_method.GetPaymentMethodResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:10541`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/move_portfolio_funds.json`

- Operation: `POST /api/v3/brokerage/portfolios/move_funds` — `RetailBrokerageApi_MovePortfolioFunds`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1365`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.MovePortfolioFundsResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:7934`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_api_key_permissions.json`

- Operation: `GET /api/v3/brokerage/key_permissions` — `RetailBrokerageApi_GetApiKeyPermissions`
  (`docs/reference/coinbase/openapi/at-spec.yaml:2731`)
- Response schema: `coinbase.retail.rest.proxy.utility.GetApiKeyPermissionsResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:10603`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- `can_view`/`can_trade`/`can_transfer`/`portfolio_uuid` carry **no vendor example** and are not individually `required` either — but `Rest.get_key_permissions/2` pattern-matches the response on `%{"can_view" => _view}`, so a fixture omitting it entirely (as the unpatched extraction does) cannot exercise the successful path at all. Manually filled — see `../fills.md`.

### `at/get_server_time.json`

- Operation: `GET /api/v3/brokerage/time` — `RetailBrokerageApi_GetServerTime`
  (`docs/reference/coinbase/openapi/at-spec.yaml:2272`)
- Response schema: `coinbase.retail.rest.proxy.common.ExtendedTimestamp` (`docs/reference/coinbase/openapi/at-spec.yaml:9888`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_transaction_summary.json`

- Operation: `GET /api/v3/brokerage/transaction_summary` — `RetailBrokerageApi_GetTransactionSummary`
  (`docs/reference/coinbase/openapi/at-spec.yaml:2067`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.GetTransactionSummaryResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:7628`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_portfolios.json`

- Operation: `GET /api/v3/brokerage/portfolios` — `RetailBrokerageApi_GetPortfolios`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1285`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.GetPortfoliosResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:7603`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_portfolio_breakdown.json`

- Operation: `GET /api/v3/brokerage/portfolios/{portfolio_uuid}` — `RetailBrokerageApi_GetPortfolioBreakdown`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1402`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.GetPortfolioBreakdownResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:7597`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/create_portfolio.json`

- Operation: `POST /api/v3/brokerage/portfolios` — `RetailBrokerageApi_CreatePortfolio`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1328`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.CreatePortfolioResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:6559`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/edit_portfolio.json`

- Operation: `PUT /api/v3/brokerage/portfolios/{portfolio_uuid}` — `RetailBrokerageApi_EditPortfolio`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1482`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.EditPortfolioResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:6874`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/delete_portfolio.json`

- Operation: `DELETE /api/v3/brokerage/portfolios/{portfolio_uuid}` — `RetailBrokerageApi_DeletePortfolio`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1445`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.DeletePortfolioResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:6565`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/create_convert_quote.json`

- Operation: `POST /api/v3/brokerage/convert/quote` — `RetailBrokerageApi_CreateConvertQuote`
  (`docs/reference/coinbase/openapi/at-spec.yaml:2140`)
- Response schema: `coinbase.retail.rest.proxy.convert.CreateConvertQuoteResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:9935`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/commit_convert_trade.json`

- Operation: `POST /api/v3/brokerage/convert/trade/{trade_id}` — `RetailBrokerageApi_CommitConvertTrade`
  (`docs/reference/coinbase/openapi/at-spec.yaml:2228`)
- Response schema: `coinbase.retail.rest.proxy.convert.CommitConvertTradeResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:9911`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_convert_trade.json`

- Operation: `GET /api/v3/brokerage/convert/trade/{trade_id}` — `RetailBrokerageApi_GetConvertTrade`
  (`docs/reference/coinbase/openapi/at-spec.yaml:2178`)
- Response schema: `coinbase.retail.rest.proxy.convert.GetConvertTradeResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:9941`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_fcm_positions.json`

- Operation: `GET /api/v3/brokerage/cfm/positions` — `RetailBrokerageApi_GetFCMPositions`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1667`)
- Response schema: `coinbase.retail.rest.proxy.fcm.GetFCMPositionsResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:10237`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_fcm_position.json`

- Operation: `GET /api/v3/brokerage/cfm/positions/{product_id}` — `RetailBrokerageApi_GetFCMPosition`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1698`)
- Response schema: `coinbase.retail.rest.proxy.fcm.GetFCMPositionResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:10231`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_fcm_balance_summary.json`

- Operation: `GET /api/v3/brokerage/cfm/balance_summary` — `RetailBrokerageApi_GetFCMBalanceSummary`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1526`)
- Response schema: `coinbase.retail.rest.proxy.fcm.GetFCMBalanceSummaryResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:10225`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_fcm_sweeps.json`

- Operation: `GET /api/v3/brokerage/cfm/sweeps` — `RetailBrokerageApi_GetFCMSweeps`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1774`)
- Response schema: `coinbase.retail.rest.proxy.fcm.GetFCMSweepsResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:10244`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/schedule_fcm_sweep.json`

- Operation: `POST /api/v3/brokerage/cfm/sweeps/schedule` — `RetailBrokerageApi_ScheduleFCMSweep`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1736`)
- Response schema: `coinbase.retail.rest.proxy.fcm.ScheduleFCMSweepResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:10305`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/cancel_fcm_sweep.json`

- Operation: `DELETE /api/v3/brokerage/cfm/sweeps` — `RetailBrokerageApi_CancelFCMSweep`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1804`)
- Response schema: `coinbase.retail.rest.proxy.fcm.CancelFCMSweepResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:10024`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_intraday_margin_setting.json`

- Operation: `GET /api/v3/brokerage/cfm/intraday/margin_setting` — `RetailBrokerageApi_GetIntradayMarginSetting`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1557`)
- Response schema: `coinbase.retail.rest.proxy.fcm.GetIntradayMarginSettingResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:10251`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/set_intraday_margin_setting.json`

- Operation: `POST /api/v3/brokerage/cfm/intraday/margin_setting` — `RetailBrokerageApi_SetIntradayMarginSetting`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1587`)
- Response schema: `coinbase.retail.rest.proxy.fcm.SetIntradayMarginSettingResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:10320`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_current_margin_window.json`

- Operation: `GET /api/v3/brokerage/cfm/intraday/current_margin_window` — `RetailBrokerageApi_GetCurrentMarginWindow`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1624`)
- Response schema: `coinbase.retail.rest.proxy.fcm.GetCurrentMarginWindowResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:10212`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_fills.json`

- Operation: `GET /api/v3/brokerage/orders/historical/fills` — `RetailBrokerageApi_GetFills`
  (`docs/reference/coinbase/openapi/at-spec.yaml:963`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.GetFillsResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:7523`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_best_bid_ask.json`

- Operation: `GET /api/v3/brokerage/best_bid_ask` — `RetailBrokerageApi_GetBestBidAsk`
  (`docs/reference/coinbase/openapi/at-spec.yaml:105`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.GetBestBidAskResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:7512`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_product_book.json`

- Operation: `GET /api/v3/brokerage/product_book` — `RetailBrokerageApi_GetProductBook`
  (`docs/reference/coinbase/openapi/at-spec.yaml:147`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.GetProductBookResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:7610`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_public_product_book.json`

- Operation: `GET /api/v3/brokerage/market/product_book` — `RetailBrokerageApi_GetPublicProductBook`
  (`docs/reference/coinbase/openapi/at-spec.yaml:2300`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.GetProductBookResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:7610`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/post_order.json`

- Operation: `POST /api/v3/brokerage/orders` — `RetailBrokerageApi_PostOrder`
  (`docs/reference/coinbase/openapi/at-spec.yaml:558`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.NewOrderResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:8177`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/cancel_orders.json`

- Operation: `POST /api/v3/brokerage/orders/batch_cancel` — `RetailBrokerageApi_CancelOrders`
  (`docs/reference/coinbase/openapi/at-spec.yaml:600`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.CancelOrdersResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:6420`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/get_historical_order.json`

- Operation: `GET /api/v3/brokerage/orders/historical/{order_id}` — `RetailBrokerageApi_GetHistoricalOrder`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1158`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.GetHistoricalOrderResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:7541`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$.order.total_value_after_fees (required, no vendor example)`

### `at/get_historical_orders.json`

- Operation: `GET /api/v3/brokerage/orders/historical/batch` — `RetailBrokerageApi_GetHistoricalOrders`
  (`docs/reference/coinbase/openapi/at-spec.yaml:710`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.GetHistoricalOrdersResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:7548`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$.orders[].total_value_after_fees (required, no vendor example)`

### `at/preview_order.json`

- Operation: `POST /api/v3/brokerage/orders/preview` — `RetailBrokerageApi_PreviewOrder`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1209`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.OrderPreviewResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:8660`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$.order_total (required, no vendor example)`
  - `$.commission_total (required, no vendor example)`
  - `$.best_bid (required, no vendor example)`
  - `$.best_ask (required, no vendor example)`
  - `$.is_max (required, no vendor example)`
  - `$req.product_id (required, no vendor example)`

### `at/preview_edit_order.json`

- Operation: `POST /api/v3/brokerage/orders/edit_preview` — `RetailBrokerageApi_PreviewEditOrder`
  (`docs/reference/coinbase/openapi/at-spec.yaml:671`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.PreviewEditOrderResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:8916`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/close_position.json`

- Operation: `POST /api/v3/brokerage/orders/close_position` — `RetailBrokerageApi_ClosePosition`
  (`docs/reference/coinbase/openapi/at-spec.yaml:1246`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.ClosePositionResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:6485`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

### `at/edit_order.json`

- Operation: `POST /api/v3/brokerage/orders/edit` — `RetailBrokerageApi_EditOrder`
  (`docs/reference/coinbase/openapi/at-spec.yaml:637`)
- Response schema: `coinbase.public_api.authed.retail_brokerage_api.EditOrderResponse` (`docs/reference/coinbase/openapi/at-spec.yaml:6853`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).

## Prime staking REST (`prime-spec.yaml`)

Every Prime response below is returned to the caller **unmodified** — see
`lib/dp_exchange/coinbase/prime.ex`'s own moduledoc on why: none of it is decoded into a
contract type, so conformance here is about the fixture being a genuine shape the venue
documents, and the package's own request bodies matching the spec's required request fields
exactly (asserted directly in the test, not from a fixture — see the test file).

### `prime/portfolio_staking_initiate.json`

- Operation: `POST /v1/portfolios/{portfolio_id}/staking/initiate` — `PrimeRESTAPI_PortfolioStakingInitiate`
  (`docs/reference/coinbase/openapi/prime-spec.yaml:7257`)
- Response schema: `coinbase.public_rest_api.PortfolioStakingInitiateResponse` (`docs/reference/coinbase/openapi/prime-spec.yaml:14262`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$req.idempotency_key (required, no vendor example)`
  - `$req.currency_symbol (required, no vendor example)`
  - `$req.amount (required, no vendor example)`

### `prime/portfolio_staking_unstake.json`

- Operation: `POST /v1/portfolios/{portfolio_id}/staking/unstake` — `PrimeRESTAPI_PortfolioStakingUnstake`
  (`docs/reference/coinbase/openapi/prime-spec.yaml:7425`)
- Response schema: `coinbase.public_rest_api.PortfolioStakingUnstakeResponse` (`docs/reference/coinbase/openapi/prime-spec.yaml:14278`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$req.idempotency_key (required, no vendor example)`
  - `$req.currency_symbol (required, no vendor example)`

### `prime/list_transaction_validators.json`

- Operation: `POST /v1/portfolios/{portfolio_id}/staking/transaction-validators/query` — `PrimeRESTAPI_ListTransactionValidators`
  (`docs/reference/coinbase/openapi/prime-spec.yaml:7337`)
- Response schema: `coinbase.public_rest_api.ListTransactionValidatorsResponse` (`docs/reference/coinbase/openapi/prime-spec.yaml:13088`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$.transaction_validators[].transaction_id (required, no vendor example)`
  - `$.transaction_validators[].validator_address (required, no vendor example)`
  - `$.pagination.next_cursor (required, no vendor example)`
  - `$.pagination.has_next (required, no vendor example)`

### `prime/staking_initiate.json`

- Operation: `POST /v1/portfolios/{portfolio_id}/wallets/{wallet_id}/staking/initiate` — `PrimeRESTAPI_StakingInitiate`
  (`docs/reference/coinbase/openapi/prime-spec.yaml:8836`)
- Response schema: `coinbase.public_rest_api.StakingInitiateResponse` (`docs/reference/coinbase/openapi/prime-spec.yaml:15033`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$.wallet_id (required, no vendor example)`
  - `$.transaction_id (required, no vendor example)`
  - `$.activity_id (required, no vendor example)`
  - `$req.idempotency_key (required, no vendor example)`

### `prime/staking_unstake.json`

- Operation: `POST /v1/portfolios/{portfolio_id}/wallets/{wallet_id}/staking/unstake` — `PrimeRESTAPI_StakingUnstake`
  (`docs/reference/coinbase/openapi/prime-spec.yaml:8981`)
- Response schema: `coinbase.public_rest_api.StakingUnstakeResponse` (`docs/reference/coinbase/openapi/prime-spec.yaml:15081`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$.wallet_id (required, no vendor example)`
  - `$.transaction_id (required, no vendor example)`
  - `$.activity_id (required, no vendor example)`
  - `$req.idempotency_key (required, no vendor example)`
  - `$req.inputs.validator_allocations[].validator_address (required, no vendor example)`
  - `$req.inputs.validator_allocations[].amount (required, no vendor example)`

### `prime/preview_unstake.json`

- Operation: `POST /v1/portfolios/{portfolio_id}/wallets/{wallet_id}/staking/unstake/preview` — `PrimeRESTAPI_PreviewUnstake`
  (`docs/reference/coinbase/openapi/prime-spec.yaml:9068`)
- Response schema: `coinbase.public_rest_api.PreviewUnstakeResponse` (`docs/reference/coinbase/openapi/prime-spec.yaml:14502`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$.estimated_amount (required, no vendor example)`
  - `$req.amount (required, no vendor example)`

### `prime/get_unstaking_status.json`

- Operation: `GET /v1/portfolios/{portfolio_id}/wallets/{wallet_id}/staking/unstake/status` — `PrimeRESTAPI_GetUnstakingStatus`
  (`docs/reference/coinbase/openapi/prime-spec.yaml:9136`)
- Response schema: `coinbase.public_rest_api.GetUnstakingStatusResponse` (`docs/reference/coinbase/openapi/prime-spec.yaml:12848`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$.portfolio_id (required, no vendor example)`
  - `$.wallet_id (required, no vendor example)`
  - `$.wallet_address (required, no vendor example)`
  - `$.validators[].validator_address (required, no vendor example)`

### `prime/staking_claim_rewards.json`

- Operation: `POST /v1/portfolios/{portfolio_id}/wallets/{wallet_id}/staking/claim_rewards` — `PrimeRESTAPI_StakingClaimRewards`
  (`docs/reference/coinbase/openapi/prime-spec.yaml:8751`)
- Response schema: `coinbase.public_rest_api.StakingClaimRewardsResponse` (`docs/reference/coinbase/openapi/prime-spec.yaml:15016`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$.wallet_id (required, no vendor example)`
  - `$.transaction_id (required, no vendor example)`
  - `$.activity_id (required, no vendor example)`
  - `$req.idempotency_key (required, no vendor example)`

### `prime/get_staking_status.json`

- Operation: `GET /v1/portfolios/{portfolio_id}/wallets/{wallet_id}/staking/status` — `PrimeRESTAPI_GetStakingStatus`
  (`docs/reference/coinbase/openapi/prime-spec.yaml:8922`)
- Response schema: `coinbase.public_rest_api.GetStakingStatusResponse` (`docs/reference/coinbase/openapi/prime-spec.yaml:12777`)
- Built by walking the schema and taking each property's own vendor-documented `example` value (OpenAPI's own `example` keyword — this spec carries no response-level example, only field-level ones).
- Fields with **no vendor example anywhere in the schema** (constructed to satisfy the field's documented type — see `../fills.md` for the literal values used and why):
  - `$.portfolio_id (required, no vendor example)`
  - `$.wallet_id (required, no vendor example)`
  - `$.wallet_address (required, no vendor example)`
  - `$.validators[].validator_address (required, no vendor example)`

- **`at/get_product_distinct_increments.json`** — every increment/min/max size field on
  `Product` shares the **identical** vendor placeholder example, `"0.00000001"`
  (`price_increment`, `base_increment`, `quote_increment`, `base_min_size`,
  `quote_min_size` all documented with that one example string). A fixture built straight
  from the schema cannot tell apart `Rest.quantization/2` reading the right field from
  reading the wrong one — exactly the incident `quantization/2`'s own moduledoc records:
  "this package's own prior mistake" sent `quote_increment` where `price_increment` was
  documented. This variant gives each field a distinct value so the mapping itself is what
  the test checks, not just that some Decimal came back.

## Hand-curated variants

Three fixtures are not straight output of `extract.js` — each is a deliberate,
documented variant of an auto-extracted one, built because the schema alone cannot
express which of two real, valid shapes a single generated example should take:

- **`at/preview_order_accepted.json`** — `OrderPreviewResponse.errs` is a required array
  with no documented minimum length, and `extract.js` (faithfully) has no vendor example
  to draw an empty array from, so it fills one representative item from the referenced
  `PreviewFailureReason` enum. That is exactly right for `at/preview_order.json`, which
  conformance-tests `Rest.preview_result/1`'s **refusal** branch
  (`rest.ex:2951`, `%{"errs" => errs} when errs != []`) against a genuine vendor-shaped
  payload. It cannot also test the **acceptance** branch, because a populated `errs` *is*
  the schema's own documented rejection signal. `preview_order_accepted.json` is the same
  generated object with `errs: []` and `warning: []` — otherwise byte-identical, including
  every other field's vendor-documented value — so the `:ok` branch (`order_total`,
  `commission_total`, `best_bid`, `best_ask` decoded as `Decimal`) has a fixture to run
  against too.
- **`at/preview_edit_order_accepted.json`** — the identical situation for
  `PreviewEditOrderResponse.errors` and `Rest.edit_preview_result/1`
  (`rest.ex:3008`).
- **`at/get_products_alias_pair.json`** — every field in a single auto-extracted `Product`
  row is the vendor's own **placeholder** example (`product_id: "BTC-USD"`, and critically
  `alias: "BTC-USD"` too — the same placeholder string on both fields), so a fixture built
  from one row alone cannot exercise `Rest.get_alias_map/1`'s actual job, which is relating
  **two different** canonical symbols. This fixture reuses the same auto-extracted `Product`
  row twice, only overriding `product_id`/`alias`/`alias_to` on each to the exact aliased
  pair `get_alias_map/1`'s own moduledoc already documents as measured, real venue behaviour
  (`XLM-USDC` aliasing `XLM-USD` — `rest.ex`'s `get_alias_map/1` moduledoc, "measured live,
  2026-09-05"). Every other field on both rows is untouched, vendor-sourced data.

## WebSocket (`at-async.json`)

`at-async.json` documents `example`/`examples` **only on the subscribe-request messages**,
never on a channel's own data payload (`ticker`, `l2_data`, `heartbeats`, `status`, ...).
Every fixture below is therefore built strictly from the payload schema's own properties —
there is no vendor example to defer to, and every field present here is one the schema
documents as `type: string`/`integer`/etc with plausible values, not a copied vendor sample.

- `websocket/ticker.json` — `TickerEnvelope` (`docs/reference/coinbase/openapi/at-async.json:965`), each ticker row is `Ticker` (`:1208`). This package subscribes `ticker` and `level2` by default, and `market_trades` on opt-in (see the last section) — see `lib/dp_exchange/coinbase/socket.ex`'s `@unsubscribed_data_channels`.
- `websocket/l2_snapshot.json` / `websocket/l2_update.json` — `L2Envelope` (`:1045`), each row is `L2Update` (`:1356`). `side` is documented as an enum of exactly `bid`/`offer`; `decode_row/1` in `socket.ex` maps `"bid"` to `:bid` and anything else (including `"offer"`) to `:ask`, which `l2_snapshot.json`'s two rows exercise directly.
- `websocket/heartbeats.json` — `HeartbeatEnvelope` (`:851`). Dispatched to a no-op clause; the fixture exists to prove that a real heartbeat shape does not crash the handler, not to check a decoded value.
- `websocket/status_unsubscribed.json` — `StatusEnvelope` (`:925`) carrying `ProductStatus` rows (`:1320`). `status` is a channel this package never subscribes to (it declares `streamable: [:quotes, :order_book]` only); this fixture proves `dispatch/2`'s catch-all recognises a genuine vendor-shaped `status` frame and reports it as a `:data_quality` notice rather than crashing or silently dropping it.
- `subscriptions` (the venue's own subscribe-ack) is not documented anywhere in `at-async.json`'s channel list at all — it is Coinbase's own confirmation frame, undocumented in the spec this package pins. `socket.ex`'s own comment records this; no fixture is built for it because there is no spec section to build one from, and it carries no data to decode.

## Prime request bodies — no fixture, asserted directly

`prime.ex` sends a request body assembled entirely from **its own literal arguments**
(portfolio/wallet id, amount, a generated idempotency key), never from parsing a fixture,
and the nine `POST` staking operations' request schemas are anonymous inline objects in
`prime-spec.yaml` (no `$ref`, so nothing for `fills.json` to key off). Rather than build a
fixture nobody reads back, `spec_examples_test.exs` captures the real request body the
package sends through the `plug:` seam and asserts its keys and types against the spec's
own `required` list and property types directly (e.g. `PortfolioStakingInitiateRequest`
requires exactly `idempotency_key`, `currency_symbol`, `amount` —
`docs/reference/coinbase/openapi/prime-spec.yaml:8802-8814` — and the test asserts the
package sends exactly those three keys, as strings, and no `inputs`/`currency` field the
wallet-scoped schema would reject).

## Spec self-contradictions

- **`OrderPreviewRequest.required` names `commission_rate`, which does not exist in
  `OrderPreviewRequest.properties` at all**
  (`docs/reference/coinbase/openapi/at-spec.yaml`, `coinbase.public_api.authed.retail_brokerage_api.OrderPreviewRequest`
  — `required:` lists `product_id`, `side`, `commission_rate`, `order_configuration`, but
  `commission_rate` has no matching property definition anywhere in the same schema). This
  is a vendor spec-authoring bug, not a gap in this package: `Rest.preview_order/3` sends
  `product_id`, `side` and `order_configuration` only, which is what every other Coinbase
  SDK's behaviour and this repo's own `docs/reference/coinbase/reconciliation.md` already
  document as the real, working request. `extract.js`'s `missingRequiredFields` reports the
  phantom `commission_rate` for `at/preview_order.json`'s **request** side; it is omitted
  from the request assertion in the test with this note, not silently dropped.
- **`OrderPreviewResponse.quote_size`/`base_size` are documented `type: string` but the
  vendor's own `example` values are JSON numbers** (`10` and `0.001`, not `"10"`/`"0.001"`)
  — `docs/reference/coinbase/openapi/at-spec.yaml`,
  `coinbase.public_api.authed.retail_brokerage_api.OrderPreviewResponse`. Kept verbatim in
  `at/preview_order.json` rather than "corrected" to a string, per this task's instruction
  not to fix example values — and it is a useful case in its own right: `Rest.preview_result/1`
  calls the package's own `decimal/1` helper, which already handles an integer or a float
  alongside a numeric string (`rest.ex:2188-2191`), so this fixture is also the conformance
  check that a spec's own type/example mismatch does not crash decoding.
- **Coinbase's own `l2_data` `side` enum is `["bid", "offer"]`, not `["bid", "ask"]`** —
  `docs/reference/coinbase/openapi/at-async.json:1356` (`L2Update.side`). Not a
  contradiction inside the spec itself, but worth recording here because it is easy to
  misread as one against `Types.OrderBookDelta`'s own `:bid | :ask` vocabulary:
  `socket.ex`'s `book_side/1` maps the venue's `"offer"` to this package's `:ask`
  deliberately (see that function's own comment), and `websocket/l2_snapshot.json` sends
  the venue's real `"offer"` spelling rather than pre-translating it, so the test asserts
  the mapping actually happens rather than assuming it.


### `market_trades` (added with the `:trades` stream)

- `websocket/market_trades_snapshot.json` / `websocket/market_trades_update.json` —
  `MarketTradesEnvelope` (`docs/reference/coinbase/openapi/at-async.json:1088`), each row is
  `MarketTrade` (`:1382`). Like every data channel in this spec it has **no vendor example**,
  so these are built from the schema's own properties. The *shape* (envelope keys, event
  `type` of `snapshot` first at `sequence_num` 0 then `update`, string-typed `price`/`size`,
  `BUY`/`SELL` `side`, RFC 3339 `time`) is what was observed live against
  `wss://advanced-trade-ws.coinbase.com` on 2026-10-02; the *values* are hand-picked
  (`BUY` and `SELL` both present, so the side flip is exercised in both directions).
  `side` is "The maker's side of the trade." (`:1407`) and `socket.ex` flips it to the
  taker's; the snapshot fixture exists to prove that history is NOT delivered.

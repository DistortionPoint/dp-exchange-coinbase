# Manual fills

Some schemas the vendor's own spec references carry **no `example` on any of their own
properties** — the parent that embeds them may document an example elsewhere, but the
leaf schema itself does not. Where this package actually decodes one of those fields (a
`Decimal`, a timestamp, an enum this package maps to an atom) a placeholder of the
documented type was constructed by hand, below, rather than left empty — an empty `{}`
would silently skip the exact decode path a conformance test exists to exercise.

Every entry names the schema, the file/line where it is defined (confirming it truly
carries no example — this is not a claim taken on faith), and the literal values used and
why. Nothing here overrides a field the vendor did document; `extract.js` only applies a
fill to a property that resolved to `undefined`.

## `coinbase.consumer.shared.common.Amount`

`docs/reference/coinbase/openapi/at-spec.yaml:2859`

```json
{
  "value": "125.50",
  "currency": "USD"
}
```

## `coinbase.portfolio_service.Amount`

`docs/reference/coinbase/openapi/at-spec.yaml:5873`

```json
{
  "value": "125.50",
  "currency": "USD"
}
```

## `coinbase.public_api.authed.retail_brokerage_api.L2Level`

`docs/reference/coinbase/openapi/at-spec.yaml:7758`

```json
{
  "price": "79478.71",
  "size": "0.5"
}
```

## `coinbase.public_api.authed.retail_brokerage_api.PriceBook`

`docs/reference/coinbase/openapi/at-spec.yaml:9124`

```json
{
  "time": "2026-08-28T14:53:45Z"
}
```

## `coinbase.retail.rest.proxy.fcm.FCMPosition`

`docs/reference/coinbase/openapi/at-spec.yaml:10108`

```json
{
  "product_id": "BIT-28JUL23-CDE",
  "expiration_time": "2023-07-28T00:00:00Z",
  "number_of_contracts": "10",
  "current_price": "27000.50",
  "avg_entry_price": "26500.00",
  "unrealized_pnl": "500.00",
  "daily_realized_pnl": "120.00"
}
```

## `coinbase.retail.rest.proxy.convert.RatConvertTrade`

`docs/reference/coinbase/openapi/at-spec.yaml:9947`

```json
{
  "id": "b6ec2e9a-1b6a-4b6a-9e1a-000000000001"
}
```

## `coinbase.portfolio_service.Portfolio`

`docs/reference/coinbase/openapi/at-spec.yaml:6037`

```json
{
  "name": "Default Portfolio",
  "uuid": "8bfc20d7-f7c6-4422-bf07-8243ca4169fe",
  "deleted": false
}
```

## `coinbase.public_api.authed.retail_brokerage_api.Order`

`docs/reference/coinbase/openapi/at-spec.yaml:8223`

```json
{
  "total_value_after_fees": "10025.00"
}
```

## `coinbase.public_api.authed.retail_brokerage_api.OrderPreviewResponse`

`docs/reference/coinbase/openapi/at-spec.yaml:8660`

```json
{
  "order_total": "10025.00",
  "commission_total": "25.00",
  "best_bid": "39999.50",
  "best_ask": "40000.50",
  "is_max": false
}
```

## `coinbase.public_api.authed.retail_brokerage_api.OrderPreviewRequest`

`docs/reference/coinbase/openapi/at-spec.yaml:8601`

```json
{
  "product_id": "BTC-USD"
}
```

## `coinbase.public_api.authed.retail_brokerage_api.Product`

`docs/reference/coinbase/openapi/at-spec.yaml:9152`

```json
{
  "status": "online"
}
```

## `coinbase.public_rest_api.GetStakingStatusResponse`

`docs/reference/coinbase/openapi/prime-spec.yaml:12777`

```json
{
  "portfolio_id": "3d95870b-2f9e-4a1e-b0a3-000000portfolio",
  "wallet_id": "1a2b3c4d-9f8e-4a1e-b0a3-0000000wallet",
  "wallet_address": "0xabc1230000000000000000000000000000dead"
}
```

## `coinbase.public_rest_api.GetUnstakingStatusResponse`

`docs/reference/coinbase/openapi/prime-spec.yaml:12848`

```json
{
  "portfolio_id": "3d95870b-2f9e-4a1e-b0a3-000000portfolio",
  "wallet_id": "1a2b3c4d-9f8e-4a1e-b0a3-0000000wallet",
  "wallet_address": "0xabc1230000000000000000000000000000dead"
}
```

## `coinbase.public_rest_api.ValidatorStakingInfo`

`docs/reference/coinbase/openapi/prime-spec.yaml:15688`

```json
{
  "validator_address": "0xva11da700000000000000000000000000000001"
}
```

## `coinbase.public_rest_api.ValidatorUnstakingInfo`

`docs/reference/coinbase/openapi/prime-spec.yaml:15731`

```json
{
  "validator_address": "0xva11da700000000000000000000000000000001"
}
```

## `coinbase.public_rest_api.TransactionValidator`

`docs/reference/coinbase/openapi/prime-spec.yaml:15443`

```json
{
  "transaction_id": "8f14e45f-ceea-467e-0000-000000000txn",
  "validator_address": "0xva11da700000000000000000000000000000001"
}
```

## `coinbase.public_rest_api.PaginatedResponse`

`docs/reference/coinbase/openapi/prime-spec.yaml:14118`

```json
{
  "next_cursor": "",
  "has_next": false
}
```

## `coinbase.public_rest_api.PortfolioStakingInitiateResponse`

`docs/reference/coinbase/openapi/prime-spec.yaml:14262`

```json
{
  "activity_id": "act_0000000000000001",
  "transaction_id": "txn_0000000000000001"
}
```

## `coinbase.public_rest_api.PortfolioStakingUnstakeResponse`

`docs/reference/coinbase/openapi/prime-spec.yaml:14278`

```json
{
  "activity_id": "act_0000000000000002",
  "transaction_id": "txn_0000000000000002"
}
```

## `coinbase.public_rest_api.StakingInitiateResponse`

`docs/reference/coinbase/openapi/prime-spec.yaml:15033`

```json
{
  "wallet_id": "1a2b3c4d-9f8e-4a1e-b0a3-0000000wallet",
  "transaction_id": "txn_0000000000000003",
  "activity_id": "act_0000000000000003"
}
```

## `coinbase.public_rest_api.StakingUnstakeResponse`

`docs/reference/coinbase/openapi/prime-spec.yaml:15081`

```json
{
  "wallet_id": "1a2b3c4d-9f8e-4a1e-b0a3-0000000wallet",
  "transaction_id": "txn_0000000000000004",
  "activity_id": "act_0000000000000004"
}
```

## `coinbase.public_rest_api.StakingClaimRewardsResponse`

`docs/reference/coinbase/openapi/prime-spec.yaml:15016`

```json
{
  "wallet_id": "1a2b3c4d-9f8e-4a1e-b0a3-0000000wallet",
  "transaction_id": "txn_0000000000000005",
  "activity_id": "act_0000000000000005"
}
```

## `coinbase.public_rest_api.PreviewUnstakeResponse`

`docs/reference/coinbase/openapi/prime-spec.yaml:14502`

```json
{
  "estimated_amount": "15.5"
}
```

## `coinbase.retail.rest.proxy.utility.GetApiKeyPermissionsResponse`

`docs/reference/coinbase/openapi/at-spec.yaml:10603`

```json
{
  "can_view": true,
  "can_trade": true,
  "can_transfer": false,
  "portfolio_uuid": "8bfc20d7-f7c6-4422-bf07-8243ca4169fe"
}
```


# Get Product Candles — reference

**Source**: Coinbase's own API documentation, Advanced Trade REST API.
`https://docs.cdp.coinbase.com/api-reference/advanced-trade-api/rest-api/products/get-product-candles`

**Read 2026-08-28.** Committed rather than linked: a link moves, and D13 makes this the
ground truth the host's adapter is checked *against*.

## Granularity — the accepted enum, verbatim

```
UNKNOWN_GRANULARITY
ONE_MINUTE
FIVE_MINUTE
FIFTEEN_MINUTE
THIRTY_MINUTE
ONE_HOUR
TWO_HOUR
FOUR_HOUR
SIX_HOUR
ONE_DAY
```

Nine real widths. **Note what is absent: there is no twelve-hour candle.** The shared
`DpExchange.Core.Timeframe` vocabulary models `12h`; Coinbase does not serve it, so this
package's `historical_timeframes` is a subset of the vocabulary and asking for `12h` must
be an error rather than a substitution.

## Page size

> "By default, returns 350 (max 350)."

## Why this page is worth committing

This endpoint is where the family's named failure mode was caught in the wild.
`FOUR_HOUR` is real and served, and the host's adapter did not list it — it carried an
`_other -> "ONE_HOUR"` fallback, so a caller asking for four-hour candles received
**one-hour bars labelled as four-hour**. Every value was a real price. Only the meaning
was wrong, which is why nothing failed.

The documentation is what settles it: the enum above either contains a width or it does
not, and a width it does not contain is an error rather than the nearest neighbour.

Coinbase's own endpoint behaves the same way — an unrecognised enum such as `THREE_HOUR`
returns **empty**, not an error and not a substitute. So a package that guesses is
guessing on top of a venue that already refuses to.

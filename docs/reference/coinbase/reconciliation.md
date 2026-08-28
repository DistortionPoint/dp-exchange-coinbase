# Reconciling the host adapter against Coinbase's documentation

Phase 5.3 (D13). The documentation is the ground truth; the host's adapter is a prior
reading of it, valuable for the production behaviour it encodes. On conflict the
documentation wins and the divergence is recorded here.

Extraction pinned at `docs/reference/coinbase/extraction-pin.md` — host `553fa787`, with
the Coinbase subtree **dirty**, so the files read include uncommitted work.

## Candle granularities — AGREE

| | Value |
|---|---|
| Documentation | `ONE_MINUTE FIVE_MINUTE FIFTEEN_MINUTE THIRTY_MINUTE ONE_HOUR TWO_HOUR FOUR_HOUR SIX_HOUR ONE_DAY` |
| Adapter declares | `1m 5m 15m 30m 1h 2h 4h 6h 1d` |
| Adapter's enum map | all nine, `granularity_enum/1` returning `Map.fetch/2` |

Nine to nine, and **the declaration and the mechanism agree** — which is the check that
matters, because the historical defect was precisely a declaration and a map disagreeing.

**The `FOUR_HOUR` defect this task exists to catch is already fixed.** The adapter's own
comment dates it: *"2026-08-06 (Phase 6): FOUR_HOUR added and the `_other -> \"ONE_HOUR\"`
[fallback removed]"*, with the note that it *"was measured working against the live
endpoint — 350 bars"*. Carrying the incident forward rather than the fix alone is the
point: the reason the fallback is gone is more valuable than its absence.

**No twelve-hour candle.** `Core.Timeframe` models `12h`; Coinbase does not serve it. This
package declares a subset, and `12h` must return an error rather than the nearest width.

## Page size — AGREE

Documentation says max 350. Adapter declares `max_candles_per_request: 350`.

## Quote assets — AGREE, and worth noting how

| | Value |
|---|---|
| Adapter declares | `USDC USD EUR GBP BTC USDT ETH INR AUD CAD SGD` |
| Host MCP reports | the same eleven |

Eleven. The MCP `describe_exchange` answer and the adapter's declaration match, which
means the declared side and the running side agree — this is the declaration confirmed
against a live system rather than against itself.

## Fields that do NOT carry across, and why

These are in the host's declaration and have no equivalent in this package's:

| Host field | Why it does not cross |
|---|---|
| `has_websocket: true` | Transport. Both endpoints exist on every venue, so there is nothing to declare |
| `websocket_module: …WebsocketProvider` | Names a transport module so a host can start it. This venue starts its own |
| `stream_channels: ["level2", "ticker"]` | Coinbase's channel vocabulary. `:order_book` and `:quotes` are everyone's |
| `auto_collect: true`, `default_quotes: ["USDC"]` | Consumer collection policy — a business decision with storage cost behind it, not a venue capability |

`supported_quotes` **does** carry across: what the venue lists is the venue's fact.
`default_quotes` does not: what to collect is the consumer's.

## Still to reconcile

- Authentication — the CDP JWT claim set and `uris` scoping, against the adapter's builder
- WebSocket channels and their payload shapes
- Rate limits, public and authenticated, as two ceilings rather than one
- Order types and time-in-force, which the host declared nowhere at all

---

## Live measurement — 2026-08-28

Tier 2, run by hand against `api.coinbase.com`. Public endpoints only, no credentials, no
money. This is the declaration checked against the **running venue** rather than against
its documentation, which is what `measured_at` / `measured_against` exist to record.

### All nine granularities are served — CONFIRMED

`GET /api/v3/brokerage/market/products/BTC-USD/candles` returned real candles for every
one of `ONE_MINUTE FIVE_MINUTE FIFTEEN_MINUTE THIRTY_MINUTE ONE_HOUR TWO_HOUR FOUR_HOUR
SIX_HOUR ONE_DAY`.

Documentation, adapter declaration, adapter enum map and the live venue: **four sources,
one answer.**

### 350 is a hard refusal, not a truncation — MEASURED, and it changes what a caller must do

| Range requested | Candles returned |
|---|---|
| 350 minutes at `ONE_MINUTE` | 349 |
| **351 minutes** | **0, `"error":"INVALID_ARGUMENT"`** |
| 400 minutes | 0, `"error":"INVALID_ARGUMENT"` |

A caller that asks for 351 candles gets **nothing** — not the first 350. So
`max_candles_per_request: 350` is not advisory sizing, it is a boundary that must be
respected by whoever builds the request, and a backfill that widens its window to "get
more in one call" returns empty rather than partial. Empty is the shape that reads as
"no data for this period", which is exactly the confusion this family keeps having to
design against.

### The venue publishes no rate-limit headers — MEASURED

`GET .../candles` returns **no `x-ratelimit-*`, no `cb-*`, no `retry-after`.** The
ceiling is not discoverable from a response.

Two consequences. `parse_rate_limit_headers/1` will answer `nil` here, and Core is right
that `nil` means *this response did not say* rather than *there is no limit*. And this
package's `public_ceiling` has to be declared from documentation rather than read from the
wire — which makes `measured_against` doing honest work: the number is a documented
claim, not an observation.

### DIVERGENCE — the host's stated evidence is wrong, though its conclusion is right

`coinbase/provider.ex` justifies removing its granularity fallback with:

> *"Coinbase itself models this correctly — an unrecognised enum (`THREE_HOUR`) returns
> EMPTY, not a nearby width — so the error tuple simply propagates what the venue says."*

**Coinbase does not return empty. It returns an explicit parse error:**

```json
{"error":"unknown",
 "error_details":"parsing field \"granularity\": \"THREE_HOUR\" is not a valid value"}
```

Same for `TWELVE_HOUR`.

The conclusion the host drew — *there is no safe substitute for a width the venue does not
serve* — is correct and this package keeps it. The evidence cited for it is not. The venue
is **stricter** than the host believed: it refuses outright rather than answering
emptily.

Worth reporting host-side, because the difference matters to a caller. Code written
expecting empty will treat a rejected request as "no data in this period" and move on;
code expecting an error will surface it. The host's own comment would lead the next reader
to the first.

---

## 5.5 — the Coinbase rate-limit header parser is NOT ported, because it fabricates

§5.5 lists `parse_rate_limit_headers/2`'s `"coinbase"` branch as code to move here. Read
in full, it should not move anywhere:

```elixir
defp parse_coinbase_rate_limits(headers) do
  case {Map.get(headers, "cb-after"), Map.get(headers, "cb-before")} do
    {nil, nil} -> nil
    {after_cursor, before_cursor} ->
      %{
        # Coinbase doesn't expose exact limits
        remaining: 100,
        reset_time: DateTime.utc_now() |> DateTime.add(60, :second),
        limit: 100,
        after_cursor: after_cursor,
        before_cursor: before_cursor
      }
  end
end
```

**`cb-after` and `cb-before` are pagination cursors, not rate-limit headers.** The
function keys off their presence and then returns `limit: 100`, `remaining: 100` and a
reset time one minute from now — three constants dressed as measurements. Its own comment
says the quiet part: *"Coinbase doesn't expose exact limits."*

A caller reading `remaining: 100` believes it has budget information. It has a literal
that does not move as budget is spent, so it will read 100 while the venue is throttling.
This is §0's named failure mode in its purest form: every value plausible, only the
meaning wrong.

**Measured 2026-08-28**: `GET /api/v3/brokerage/market/products/BTC-USD/candles` returns
**no `x-ratelimit-*`, no `cb-*` and no `retry-after`.** There is nothing to parse, so
there is no parser here — Core's generic `parse_rate_limit_headers/1` will answer `nil`,
which correctly means *this response did not say*.

Report host-side.

## Rate-limit ceilings — declared, and honestly labelled as unverified

D13's source hierarchy, applied:

1. **Live measurement** — unavailable without deliberately exceeding the limit, which is
   abusive against a third party's API and is not done.
2. **Coinbase's own documentation** — a rate-limits page could not be located across the
   API reference index and `llms.txt`. **Not found is recorded as not found.**
3. **The host's adapter** — its moduledoc states *"10 requests/second for private
   endpoints, 3 requests/second for market data."*

So the declaration takes rank 3 and **says so**: `measured_against` records that these
came from the host's prior reading and are confirmed by neither the vendor's
documentation nor a probe. An unlabelled number would be worse than a missing one; a
labelled rank-3 number is usable and honest about what it is.

**Open item for 5.8 or a later tier-2 pass**: find the vendor's rate-limit page, or
confirm the figures against `Retry-After` on a naturally-occurring 429. Until then the
shape is right — two ceilings, authenticated higher — and the magnitudes are inherited.

---

## HOST FINDING — `generate_fallback_candles/4` survives on one path, and should not

Found while porting `get_historical_prices/4`. **Not ported.**

**Half of this was already fixed, and the fix is worth reading before the finding.** On
2026-05-26 the *error* path stopped fabricating, and its comment says why in terms this
family keeps rediscovering: callers *"cannot distinguish real from synthetic data"*, the
fake candles *"silently poisoned every downstream backtest"*, and the remediation traced
multi-hundred-dollar phantom profits to synthetic \$39k BTC prices. That path now returns
`{:error, {:api_unavailable, reason}}`.

**The generator itself was left in place, reachable from one remaining caller** — the
test-mode branch. Same function, same hardcoded table, same shape as the 2026-08-06 Gemini
incident that `Core.Timeframe.aligned?/2` was written to catch.

`coinbase/provider.ex:294` branches on a global flag before it reaches the network:

```elixir
if Application.get_env(:dp_crypto_management, :test_overrides, %{})[:mock_external_apis] do
  generate_fallback_candles(symbol, start_time, end_time, granularity)
else
  fetch_historical_prices_from_api(symbol, start_time, end_time, opts)
end
```

`generate_fallback_candles/4` then invents candles from a hardcoded price table
(`BTC-USD => 42_500.0`, `ETH-USD => 2_500.0`, …, anything unlisted `100.0`) with
pseudorandom variation seeded from `:erlang.phash2({symbol, timestamp})`, and returns them
as `{:ok, candles}` — indistinguishable at the call site from real history.

**Three things make the surviving branch worse than a test helper:**

**The timestamps are not bucket-aligned.** They are `end_time - i * granularity` for a
caller-supplied `end_time`. Measured against `Timeframe.aligned?/2` with a realistic
`end_time` of *now*, every generated candle fails alignment:

```
2026-08-28T14:34:56.040263Z  aligned?(1h)=false
2026-08-28T13:34:56.040263Z  aligned?(1h)=false
```

That is the exact signature the Gemini incident left behind — `now - i * granularity`,
sub-second timestamps, prices from a hardcoded table — and it is why `aligned?/2` exists.
It would be rejected on a guarded write path, but it is still handed to the caller as
history.

**The gate is a node-wide global.** `Application.get_env/3` on `:test_overrides` is
exactly the hazard §7.8 documents: one `async: true` test setting it makes every other
test on the node receive fabricated candles, silently, for the duration.

**The base price is 42,500.** The Gemini incident's fabricated `BTC-USD` closes were
*"42,912.10 (42_500 base)"*, and the 2026-05-26 remediation names \$42,500 as this
adapter's own base. It is the same table that produced both.

**One caller, one flag.** Removing the branch and the generator together closes it; the
error path already shows what the replacement looks like.

### What this package does instead

No fallback and no test-mode branch in production code. `get_historical_prices/4` calls
the venue or returns an error. A caller that wants deterministic candles uses the package's
fake, which is a real implementation of the facade selected **per process** through
`DpExchange.Core.Config` — not a global flag that leaks across a consumer's whole test
suite, and not a code path inside the live provider.

**The rule, stated once**: a package must not be able to return data the venue did not
send. Not behind a flag, not in test mode, not as a fallback.

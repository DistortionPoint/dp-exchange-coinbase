# Rate limits — reference, and a negative result

**Searched 2026-09-09.** This file exists to record what the vendor does **not** publish,
because that was previously recorded as "could not be located" — a statement about the
searcher rather than about the vendor, and one that had already hidden a five-times error
on another venue in this family.

## What is published

| surface | limit | source |
|---|---|---|
| Advanced Trade **WebSocket** | **8 per second per IP**, for connections *and* for unauthenticated messages, each counted separately | `docs.cdp.coinbase.com/coinbase-app/advanced-trade-apis/websocket/websocket-rate-limits` |

That figure is load-bearing, not decoration: `Feed`'s `@shard_spacing_floor_ms` of 125 ms
is derived from it directly (8/sec → one connection per 125 ms), and the working
`@default_shard_spacing_ms` of 1_000 ms sits 8× under it. The extra headroom is
deliberately attributed to the *undocumented concurrency ceiling* risk that crash-looped
another venue in this family, not to this number.

## What is not published

**There is no Advanced Trade REST rate limit anywhere in this vendor's documentation.**

That is a search result, not an impression:

1. `docs.cdp.coinbase.com/sitemap.xml` lists **2,357** pages, of which **eleven** are
   rate-limit pages. The earlier note that the rate-limit page "could not be located" was
   true of three URL guesses and false of the vendor — the pages were listed in the
   sitemap the whole time.
2. None of those eleven covers Advanced Trade REST. They cover the v2 App API
   (`coinbase-app/api-architecture/rate-limiting`, an hourly per-key figure), Exchange,
   International Exchange, Prime, FIX, and the Advanced Trade **WebSocket**.
3. All **84** Advanced Trade documentation pages were then fetched and searched for
   rate-limit text. **Exactly one** carries any — the WebSocket page above.

## What this package declares, and why it is still rank 3

`public_ceiling: %{limit: 3, per_ms: 1_000}` and
`authenticated_ceiling: %{limit: 10, per_ms: 1_000}` remain **inherited from the prior
adapter's moduledoc and not confirmed against anything**. Rank 3 of D13's hierarchy,
labelled as such in `capabilities/0`'s own `measured_against`.

They are not doc-derived because there is no document, and they are not measured because
measuring a rate ceiling means deliberately exceeding a third party's — which this family
does not do. An unlabelled number would be worse than a missing one; a labelled inherited
one is the honest state.

**What would change them**: a vendor page appearing (the `sitemap.xml` row in
`doc-sources.tsv` is watched weekly for exactly this), or a consumer running live against
the venue reporting an observed `429` boundary. The second is how a rate ceiling normally
becomes real in this family — a fact from production, not a probe from here.

## Why this file exists at all

On `developer.webull.com` the identical sitemap search found a **per-endpoint rate-limit
table that had existed for weeks**, unnoticed, while this family declared a ceiling five
times too permissive on a venue whose documented penalty is a temporary IP block. The
lesson generalised: *"the vendor does not document this"* is a claim with a method behind
it or it is not a claim. This file is the method, so the next reader can re-run it rather
than re-guess it.

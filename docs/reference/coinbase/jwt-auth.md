# CDP JWT authentication — reference

**Source**: Coinbase's own developer documentation, "JWT Authentication".
`https://docs.cdp.coinbase.com/get-started/authentication/jwt-authentication`.
**Read 2026-09-08** (search-engine cache and summarisation tool, not a raw fetch — the
page renders through a JS documentation framework that returns only a navigation shell to
a plain fetch, the same limitation this family has already hit on other venues' portals).

Committed rather than linked, per D13.

## The two-minute expiry, verbatim

> Note that your JWT is only valid for a period of **2 minutes** from the time it is
> generated. You'll need to re-generate your JWT before it expires to ensure uninterrupted
> access.

The page also states this is the SDK samples' default rather than a value CDP enforces
server-side: `expiresIn: 120` is documented as "optional (defaults to 120 seconds)", and a
"common pitfalls" note advises callers to "manage the token expiration to a timeframe which
makes sense for your use-case." So `Auth.jwt/2`'s `now + 120` matches Coinbase's own stated
default, not a hard ceiling the venue enforces on every token regardless of what a caller
requests — this package's own choice to use the venue's stated default is a reasonable one
(a short-lived, unmemoised token is the safer failure mode — see `Auth`'s moduledoc "The
two-minute expiry is deliberate" section), not a claim that a longer value would be
rejected.

## The claim set — read 2026-10-10

**Source**: Coinbase's "API Key Authentication" page,
`https://docs.cdp.coinbase.com/coinbase-app/authentication-authorization/api-key-authentication`,
read 2026-10-10 through a fetch-and-summarise tool (not a raw copy). What the page's code
samples build, as quoted from it:

- Header: `kid` = the key name, `nonce` = a fresh random hex string (`secrets.token_hex()`).
- Payload (Python sample): `'sub': key_name`, `'iss': "cdp"`, `'nbf': int(time.time())`,
  `'exp': int(time.time()) + 120`, `'uri': uri`.
- `uri` is one string, built as `f"{request_method} {request_host}{request_path}"`. The
  page never uses `uris`.
- No sample includes an `aud` claim.
- `iss` is `"cdp"` in the Python, JavaScript, PHP, Java, TypeScript, Go and C++ samples. The
  C# sample alone still uses `"coinbase-cloud"`. The page does not say which is required.

`Auth.jwt/2` builds this set. **Not yet probed with a live key** (tier 3).

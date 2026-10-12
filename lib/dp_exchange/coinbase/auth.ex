defmodule DpExchange.Coinbase.Auth do
  @moduledoc """
  Coinbase CDP authentication — a signed Ed25519 JWT, built here rather than in the
  shared HTTP client.

  This lived in `Core.HttpClient` as a `:coinbase_cdp_jwt` branch of a shared
  `build_auth_headers/5`. It is a venue fact, and a venue fact in shared code is a
  second place that can be wrong about the venue. Core keeps the generic schemes and
  takes a **function** for anything else; this is that function.

  ## Why it is public, and the incident behind it

  The WebSocket side needs the same token. It once had its own stub that returned the
  **raw API key** instead of a signed JWT, and Coinbase answers that with
  `{"type":"error","message":"authentication failure"}` — which is how the `level2`
  channel produced nothing while `ticker`, which is public and needs no auth, worked
  fine. A venue half-delivering looks like a quiet market, not a broken credential.

  A working implementation living one module away from a stub doing the same job is the
  kind of duplication that only ever shows up as a runtime failure. One implementation,
  used by both paths.
  """

  @doc """
  Builds authentication headers for a REST call.

  Returns `{:ok, headers}` or `{:error, reason}`, so a caller gates on it with `with`
  the way every other venue package in this family gates on its own `Auth.headers`.

  ## Why this returns a tuple rather than a bare header list

  **An unsigned token is worse than none**: it looks like a credential problem at the
  venue rather than at us, and sends the reader looking in the wrong place. That reason
  has always been right, but the shape this function used to have could not act on it.

  It was written as `Core.HttpClient`'s 4-arity auth hook, which may only return a
  header list — it has no way to say "abort, do not send". So on a signing failure it
  returned the content-type header alone and documented that "the caller decides whether
  an unauthenticated request is acceptable". **No caller ever decided.** `Rest.request/5`
  and `Rest.json_request/5` both handed whatever came back straight to
  `HttpClient.request/5` without ever checking for `Authorization`.

  For a GET on a public market-data path that is harmless — Coinbase serves those
  anonymously. For `json_request/5` there is **no public path**: every caller of it is a
  write. So a malformed `api_secret` turned a live `place_order/3` into an
  *unauthenticated* POST, sent to the venue to fail there as an opaque 401 — which is
  precisely the failure the paragraph above exists to prevent, produced by the mechanism
  that documented it.

  Returning a tuple is what makes the stated rule true. The signing failure now stops
  the request here, locally, with the reason that caused it.
  """
  @spec rest_headers(atom(), String.t(), String.t() | nil, map()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def rest_headers(method, path, _body, credentials) do
    uri = "#{method |> to_string() |> String.upcase()} api.coinbase.com#{path}"

    with {:ok, token} <- jwt(credentials, uri: uri) do
      {:ok, [{"Authorization", "Bearer #{token}"}, {"Content-Type", "application/json"}]}
    end
  end

  @doc """
  Builds a signed CDP JWT.

  ## The claim set is the one Coinbase documents

  `sub` and `kid` are the key name, `iss` is `"cdp"`, `nbf`/`exp` bound the window, and a
  REST token carries one `uri` string (`"GET api.coinbase.com/api/v3/..."`). Taken from
  Coinbase's "API Key Authentication" page (read 2026-10-10, quoted in
  `docs/reference/coinbase/jwt-auth.md`): every sample but one builds exactly this, with no
  `aud`. Documentation-derived, **not yet probed with a live key** — tier 3 needs
  credentials this repo never holds.

  This built the older Coinbase Cloud shape until 2026-10-10: `iss: "coinbase-cloud"`, an
  `aud: ["retail_rest_api_proxy"]`, and the scope as a `uris` LIST. The documented claim is
  the singular `uri`, so a REST token named its scope under a key the venue's own builder
  never writes — a token that looks scoped and, by the documentation, is not.

  ## `:uri`

  Scopes the token to one REST call. **The WebSocket token omits it** — a socket is not one
  request — so the claim is included only when given rather than defaulted to something
  plausible. Defaulting it would produce a token that looks right and is rejected.

  ## The two-minute expiry is deliberate

  Short by design, and **not cached**: the streaming side rebuilds one per subscribe. A
  token that outlives its window fails in exactly the silent way the incident above was
  about — the connection is up, the subscribe is accepted, and no data arrives.

  `120` matches Coinbase's own documented default (`docs/reference/coinbase/jwt-auth.md`
  quotes "your JWT is only valid for a period of 2 minutes" verbatim), not a ceiling the
  venue enforces regardless of what a caller requests — the page states 120s as the SDK
  samples' default and leaves the actual duration to the caller. This package's own choice
  to use that default, for the reason above, is doc-derived rather than an arbitrary
  number that happens to match.

  ## Only Ed25519 keys are supported

  `alg` is `EdDSA`, so `api_secret` is the Base64 of a 32-byte seed or a 64-byte
  seed-plus-public-key. A PEM block (the form an ECDSA private key takes) is not that: this
  builder does not sign with ECDSA, and a PEM `api_secret` answers
  `{:error, :unsupported_key_format}` rather than `{:error, :invalid_base64}`. It is
  refused, not converted. Not probed against a live ECDSA key; this is the shape of the
  string, nothing more.

  ## Credentials that cannot sign are refused here, by name

  A map without `:api_key` and `:api_secret` — `nil`, `%{}`, or one assembled with a
  typo'd key — answers `{:error, {:missing_credentials, :coinbase}}`, the same shape
  every other venue package in this family returns for the same condition.

  This clause used to be absent, and `credentials.api_key` was read unconditionally, so
  the same input raised `KeyError` from inside signing instead. That reached every write
  endpoint through `Rest.json_request/5`, which — unlike `Rest.request/5` — carries no
  `nil` guard of its own, and it surfaced as a crash in the caller's process rather than
  as the refusal the contract asks for.
  """
  @spec jwt(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def jwt(credentials, opts \\ [])

  def jwt(credentials, opts) do
    with :ok <- check_credentials(credentials) do
      sign_jwt(credentials.api_key, credentials.api_secret, opts)
    end
  end

  @doc """
  Whether `credentials` carries a usable `api_key` and `api_secret`, before any signing.

  * not a map with binary `:api_key` and `:api_secret`, or either one empty or
    whitespace-only: `{:error, {:missing_credentials, :coinbase}}`. A blank `api_key` used
    to sign a token with `kid: ""`, and a blank `api_secret` answered
    `{:unsupported_key_size, 0}`, which sent the reader to check a key length that was
    never the problem.
  * either one with leading or trailing whitespace (a `.env` value with its newline):
    `{:error, {:invalid_credentials, :coinbase}}`. Refused rather than trimmed and signed,
    so what is signed is what the caller configured. The value is never echoed.

  The one definition of "can sign" for `jwt/2` and for
  `DpExchange.Coinbase.Rest.validate_credentials/1`, and so for `DpExchange.Coinbase.Fake`.
  """
  @spec check_credentials(term()) ::
          :ok | {:error, {:missing_credentials | :invalid_credentials, :coinbase}}
  def check_credentials(%{api_key: api_key, api_secret: api_secret})
      when is_binary(api_key) and is_binary(api_secret) do
    cond do
      String.trim(api_key) == "" or String.trim(api_secret) == "" ->
        {:error, {:missing_credentials, :coinbase}}

      padded?(api_key) or (padded?(api_secret) and not pem?(api_secret)) ->
        {:error, {:invalid_credentials, :coinbase}}

      # `api_key` goes into the JWT's JSON (`kid`, `sub`) and `Jason.encode!/1` RAISES on a
      # binary that is not UTF-8, with a message that quotes the offending bytes: the
      # configured key, in an exception in the caller's (or the Feed's) process and so in
      # its crash report. Refused by name here, value not echoed.
      not String.valid?(api_key) ->
        {:error, {:invalid_credentials, :coinbase}}

      true ->
        :ok
    end
  end

  def check_credentials(_credentials), do: {:error, {:missing_credentials, :coinbase}}

  defp padded?(value), do: String.trim(value) != value

  # A PEM block always ends in a newline; `decode_private_key/1` names it for what it is
  # (`:unsupported_key_format`) rather than calling it padded.
  defp pem?("-----BEGIN" <> _rest), do: true
  defp pem?(_secret), do: false

  defp sign_jwt(api_key, api_secret, opts) do
    now = DateTime.utc_now() |> DateTime.to_unix(:second)
    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    header =
      %{"alg" => "EdDSA", "kid" => api_key, "nonce" => nonce, "typ" => "JWT"}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    claims =
      %{
        "sub" => api_key,
        "iss" => "cdp",
        "nbf" => now,
        # 120s — Coinbase's own documented default, see this function's own @doc.
        "exp" => now + 120
      }
      |> maybe_put_uri(Keyword.get(opts, :uri))
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    signing_input = "#{header}.#{claims}"

    with {:ok, private_bytes} <- decode_private_key(api_secret) do
      signature =
        :eddsa
        |> :crypto.sign(:none, signing_input, [private_bytes, :ed25519])
        |> Base.url_encode64(padding: false)

      {:ok, "#{signing_input}.#{signature}"}
    end
  end

  defp maybe_put_uri(claims, nil), do: claims
  defp maybe_put_uri(claims, uri) when is_binary(uri), do: Map.put(claims, "uri", uri)

  # A PEM block (`-----BEGIN EC PRIVATE KEY-----`, the form an ECDSA key takes) is named for
  # what it is. It is not Base64, so it used to answer `:invalid_base64` and send the reader
  # to check an encoding that was fine, when the key type is what this builder does not
  # support (`alg` is always `EdDSA`).
  defp decode_private_key("-----BEGIN" <> _pem), do: {:error, :unsupported_key_format}

  # The raw 32-byte Ed25519 seed. Coinbase issues both a 32-byte seed and a 64-byte
  # seed-plus-public-key; the second is the seed followed by the public key, so the
  # leading 32 bytes are what signs.
  #
  # Any other length is refused rather than truncated to 32. A wrong-length key that got
  # truncated would produce a syntactically valid token that the venue rejects, which
  # reads as a credential problem rather than a parsing one.
  defp decode_private_key(secret) do
    case Base.decode64(secret) do
      {:ok, <<seed::binary-32>>} -> {:ok, seed}
      {:ok, <<seed::binary-32, _public_key::binary-32>>} -> {:ok, seed}
      {:ok, other} -> {:error, {:unsupported_key_size, byte_size(other)}}
      :error -> {:error, :invalid_base64}
    end
  end
end

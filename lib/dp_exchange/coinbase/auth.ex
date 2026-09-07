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

    with {:ok, token} <- jwt(credentials, uris: [uri]) do
      {:ok, [{"Authorization", "Bearer #{token}"}, {"Content-Type", "application/json"}]}
    end
  end

  @doc """
  Builds a signed CDP JWT.

  ## `:uris`

  Scopes the token to specific REST calls, per Coinbase's documentation. **The WebSocket
  token omits it** — a socket is not one request — so the claim is included only when
  given rather than defaulted to something plausible. Defaulting it would produce a token
  that looks right and is rejected.

  ## The two-minute expiry is deliberate

  Short by design, and **not cached**: the streaming side rebuilds one per subscribe. A
  token that outlives its window fails in exactly the silent way the incident above was
  about — the connection is up, the subscribe is accepted, and no data arrives.

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

  def jwt(%{api_key: api_key, api_secret: api_secret}, opts)
      when is_binary(api_key) and is_binary(api_secret) do
    now = DateTime.utc_now() |> DateTime.to_unix(:second)
    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    header =
      %{"alg" => "EdDSA", "kid" => api_key, "nonce" => nonce, "typ" => "JWT"}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    claims =
      %{
        "sub" => api_key,
        "iss" => "coinbase-cloud",
        "aud" => ["retail_rest_api_proxy"],
        "nbf" => now,
        "exp" => now + 120
      }
      |> maybe_put_uris(Keyword.get(opts, :uris))
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

  def jwt(_credentials, _opts), do: {:error, {:missing_credentials, :coinbase}}

  defp maybe_put_uris(claims, nil), do: claims
  defp maybe_put_uris(claims, uris), do: Map.put(claims, "uris", uris)

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

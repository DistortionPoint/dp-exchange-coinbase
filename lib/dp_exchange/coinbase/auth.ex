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
  Builds authentication headers for a REST call, as `Core.HttpClient`'s auth hook.

  Pass it where an auth type would go:

      HttpClient.build_auth_headers(:get, path, body, credentials, &Auth.rest_headers/4)

  On a signing failure it returns the content-type header alone rather than an
  unsigned `Authorization`. **An unsigned token is worse than none**: it looks like a
  credential problem at the venue rather than at us, and sends the reader looking in the
  wrong place. The caller decides whether an unauthenticated request is acceptable.
  """
  @spec rest_headers(atom(), String.t(), String.t() | nil, map()) :: [{String.t(), String.t()}]
  def rest_headers(method, path, _body, credentials) do
    uri = "#{method |> to_string() |> String.upcase()} api.coinbase.com#{path}"

    case jwt(credentials, uris: [uri]) do
      {:ok, token} -> [{"Authorization", "Bearer #{token}"}, {"Content-Type", "application/json"}]
      {:error, _reason} -> [{"Content-Type", "application/json"}]
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
  """
  @spec jwt(map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def jwt(credentials, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.to_unix(:second)
    nonce = 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

    header =
      %{"alg" => "EdDSA", "kid" => credentials.api_key, "nonce" => nonce, "typ" => "JWT"}
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    claims =
      %{
        "sub" => credentials.api_key,
        "iss" => "coinbase-cloud",
        "aud" => ["retail_rest_api_proxy"],
        "nbf" => now,
        "exp" => now + 120
      }
      |> maybe_put_uris(Keyword.get(opts, :uris))
      |> Jason.encode!()
      |> Base.url_encode64(padding: false)

    signing_input = "#{header}.#{claims}"

    with {:ok, private_bytes} <- decode_private_key(credentials.api_secret) do
      signature =
        :eddsa
        |> :crypto.sign(:none, signing_input, [private_bytes, :ed25519])
        |> Base.url_encode64(padding: false)

      {:ok, "#{signing_input}.#{signature}"}
    end
  end

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

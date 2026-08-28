defmodule DpExchange.Coinbase.AuthTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Auth

  # A real Ed25519 seed, generated for this test. Not a credential: it authenticates
  # nothing and belongs to no account.
  @seed :crypto.strong_rand_bytes(32) |> Base.encode64()
  @credentials %{api_key: "organizations/x/apiKeys/y", api_secret: @seed}

  describe "jwt/2" do
    test "produces three base64url segments" do
      assert {:ok, token} = Auth.jwt(@credentials)
      assert [header, claims, signature] = String.split(token, ".")

      for segment <- [header, claims, signature] do
        assert {:ok, _decoded} = Base.url_decode64(segment, padding: false)
      end
    end

    test "the header names Ed25519 and carries the key id and a nonce" do
      {:ok, token} = Auth.jwt(@credentials)
      [header, _claims, _signature] = String.split(token, ".")
      {:ok, decoded} = Base.url_decode64(header, padding: false)

      assert %{"alg" => "EdDSA", "typ" => "JWT", "kid" => kid, "nonce" => nonce} =
               Jason.decode!(decoded)

      assert kid == @credentials.api_key
      assert byte_size(nonce) == 32
    end

    test "a fresh nonce per call — a replayed token is a token someone else can use" do
      {:ok, first} = Auth.jwt(@credentials)
      {:ok, second} = Auth.jwt(@credentials)

      refute first == second
    end

    test "the window is two minutes, and short on purpose" do
      # Not cached, and rebuilt per subscribe. A token that outlives its window fails
      # silently: the connection is up, the subscribe is accepted, no data arrives.
      {:ok, token} = Auth.jwt(@credentials)
      [_header, claims, _signature] = String.split(token, ".")
      {:ok, decoded} = Base.url_decode64(claims, padding: false)

      %{"nbf" => nbf, "exp" => exp} = Jason.decode!(decoded)
      assert exp - nbf == 120
    end

    test "uris are included only when given" do
      # The WebSocket token omits them — a socket is not one request — so defaulting the
      # claim to something plausible would produce a token that looks right and is
      # rejected.
      {:ok, without} = Auth.jwt(@credentials)
      {:ok, with_uris} = Auth.jwt(@credentials, uris: ["GET api.coinbase.com/x"])

      refute Map.has_key?(claims_of(without), "uris")
      assert claims_of(with_uris)["uris"] == ["GET api.coinbase.com/x"]
    end

    test "accepts the 64-byte seed-plus-public-key form" do
      seed = :crypto.strong_rand_bytes(64) |> Base.encode64()
      assert {:ok, _token} = Auth.jwt(%{@credentials | api_secret: seed})
    end
  end

  describe "it refuses rather than producing a token that cannot work" do
    test "a key of the wrong length is refused, not truncated" do
      # Truncating would produce a syntactically valid token the venue rejects, which
      # reads as a credential problem rather than a parsing one.
      secret = :crypto.strong_rand_bytes(20) |> Base.encode64()

      assert {:error, {:unsupported_key_size, 20}} =
               Auth.jwt(%{@credentials | api_secret: secret})
    end

    test "a non-base64 secret is refused" do
      assert {:error, :invalid_base64} = Auth.jwt(%{@credentials | api_secret: "not base64 !!"})
    end
  end

  describe "rest_headers/4" do
    test "returns a bearer token scoped to the call" do
      assert [{"Authorization", "Bearer " <> token}, {"Content-Type", "application/json"}] =
               Auth.rest_headers(:get, "/api/v3/brokerage/accounts", nil, @credentials)

      assert claims_of(token)["uris"] == ["GET api.coinbase.com/api/v3/brokerage/accounts"]
    end

    test "a signing failure yields NO Authorization header rather than an unsigned one" do
      # An unsigned token is worse than none: it looks like a credential problem at the
      # venue rather than at us, and sends the reader looking in the wrong place.
      headers = Auth.rest_headers(:get, "/x", nil, %{@credentials | api_secret: "!!"})

      assert headers == [{"Content-Type", "application/json"}]
    end
  end

  defp claims_of(token) do
    [_header, claims, _signature] = String.split(token, ".")
    {:ok, decoded} = Base.url_decode64(claims, padding: false)
    Jason.decode!(decoded)
  end
end

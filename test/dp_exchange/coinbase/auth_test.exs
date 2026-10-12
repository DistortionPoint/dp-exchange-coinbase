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

    test "uri is included only when given" do
      # The WebSocket token omits it — a socket is not one request — so defaulting the
      # claim to something plausible would produce a token that looks right and is
      # rejected.
      {:ok, without} = Auth.jwt(@credentials)
      {:ok, with_uri} = Auth.jwt(@credentials, uri: "GET api.coinbase.com/x")

      refute Map.has_key?(claims_of(without), "uri")
      assert claims_of(with_uri)["uri"] == "GET api.coinbase.com/x"
    end

    test "the claim set is the one Coinbase documents: iss cdp, no aud, no uris" do
      # Coinbase's "API Key Authentication" samples, read 2026-10-10. This built the older
      # Coinbase Cloud shape (`iss: "coinbase-cloud"`, an `aud`, a `uris` list) before.
      {:ok, token} = Auth.jwt(@credentials, uri: "GET api.coinbase.com/x")
      claims = claims_of(token)

      assert claims["iss"] == "cdp"
      assert claims["sub"] == @credentials.api_key
      refute Map.has_key?(claims, "aud")
      refute Map.has_key?(claims, "uris")
      assert claims |> Map.keys() |> Enum.sort() == ["exp", "iss", "nbf", "sub", "uri"]
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

    test "a PEM key is named as an unsupported format, not reported as bad Base64" do
      # `alg` is always EdDSA. A PEM block is not Base64, so it answered `:invalid_base64`
      # and sent the reader to check an encoding that was fine.
      pem = "-----BEGIN EC PRIVATE KEY-----\nMHcCAQEE\n-----END EC PRIVATE KEY-----\n"

      credentials = %{@credentials | api_secret: pem}

      assert {:error, :unsupported_key_format} = Auth.jwt(credentials)
      assert {:error, :unsupported_key_format} = Auth.rest_headers(:get, "/x", nil, credentials)
    end
  end

  describe "blank and padded credentials" do
    @missing {:error, {:missing_credentials, :coinbase}}
    @invalid {:error, {:invalid_credentials, :coinbase}}

    test "a blank or whitespace-only key or secret is missing, not signed with kid: \"\"" do
      for blank <- ["", " ", "\t\n"] do
        assert @missing == Auth.jwt(%{@credentials | api_key: blank})
        assert @missing == Auth.jwt(%{@credentials | api_secret: blank})
        assert @missing == Auth.rest_headers(:get, "/x", nil, %{@credentials | api_key: blank})
        assert @missing == Auth.check_credentials(%{@credentials | api_secret: blank})
      end
    end

    test "a padded key or secret is refused, never trimmed and signed, never echoed" do
      paddeds = [%{@credentials | api_key: " key"}, %{@credentials | api_secret: @seed <> "\n"}]

      for padded <- paddeds do
        assert @invalid == Auth.jwt(padded)
        assert @invalid == Auth.check_credentials(padded)
      end
    end

    test "a key that is not UTF-8 is refused by name, not raised with its bytes quoted" do
      # `Jason.encode!/1` on the `kid` raised `Jason.EncodeError` quoting the key.
      bad = %{@credentials | api_key: "test-key-not-real-" <> <<255, 254>>}

      assert @invalid == Auth.check_credentials(bad)
      assert @invalid == Auth.jwt(bad)
      assert @invalid == Auth.rest_headers(:get, "/x", nil, bad)
    end

    test "non-maps and maps missing a field are missing" do
      for bad <- [nil, %{}, %{api_key: "k"}, %{api_key: 1, api_secret: 2}, "key"] do
        assert @missing == Auth.check_credentials(bad)
      end

      assert :ok == Auth.check_credentials(@credentials)
    end
  end

  describe "rest_headers/4" do
    test "returns a bearer token scoped to the call" do
      assert {:ok, [{"Authorization", "Bearer " <> token}, {"Content-Type", "application/json"}]} =
               Auth.rest_headers(:get, "/api/v3/brokerage/accounts", nil, @credentials)

      assert claims_of(token)["uri"] == "GET api.coinbase.com/api/v3/brokerage/accounts"
    end

    test "a signing failure refuses the call rather than letting it be sent unsigned" do
      # An unsigned token is worse than none: it looks like a credential problem at the
      # venue rather than at us, and sends the reader looking in the wrong place.
      #
      # This used to return the content-type header alone and document that "the caller
      # decides whether an unauthenticated request is acceptable". No caller ever
      # decided — `Rest` handed the headers straight to `HttpClient.request/5` — so a
      # malformed secret became an unauthenticated POST on a write endpoint that has no
      # public path to fall back to. The error shape is what makes the rule enforceable.
      assert {:error, :invalid_base64} =
               Auth.rest_headers(:get, "/x", nil, %{@credentials | api_secret: "!!"})
    end

    test "credentials that cannot sign are refused by name, not with a KeyError" do
      # The shape every other venue package in this family returns for this condition.
      # `jwt/2` used to read `credentials.api_key` unconditionally and raise instead,
      # which reached every write endpoint through `Rest.json_request/5`.
      assert {:error, {:missing_credentials, :coinbase}} =
               Auth.rest_headers(:get, "/x", nil, %{})

      assert {:error, {:missing_credentials, :coinbase}} = Auth.jwt(nil)
      assert {:error, {:missing_credentials, :coinbase}} = Auth.jwt(%{api_key: "k"})
    end
  end

  defp claims_of(token) do
    [_header, claims, _signature] = String.split(token, ".")
    {:ok, decoded} = Base.url_decode64(claims, padding: false)
    Jason.decode!(decoded)
  end
end

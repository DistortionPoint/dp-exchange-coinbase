defmodule DpExchange.Coinbase.JwtFreshnessTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Socket

  # A real Ed25519 seed generated for this test; it authenticates nothing.
  @credentials %{
    api_key: "organizations/x/apiKeys/y",
    api_secret: Base.encode64(:crypto.strong_rand_bytes(32))
  }

  defp claims_of(%{jwt: token}) do
    [_header, claims, _signature] = String.split(token, ".")
    {:ok, decoded} = Base.url_decode64(claims, padding: false)
    Jason.decode!(decoded)
  end

  describe "a subscribe frame carries a token minted for that frame" do
    test "two subscribes of the same shard never share a token" do
      # The venue requires a fresh JWT on every subscribe, including the periodic re-issue
      # on a connection that has been up for hours. A token cached across subscribes would
      # carry the same nonce and, after two minutes, an expired `exp`.
      {:ok, first} = Socket.subscription_frame("level2", ["BTC-USD"], @credentials)
      {:ok, second} = Socket.subscription_frame("level2", ["BTC-USD"], @credentials)

      refute first.jwt == second.jwt
    end

    test "the token is valid when minted: nbf in the past, exp 120 s after nbf, in the future" do
      before_mint = System.os_time(:second)
      {:ok, frame} = Socket.subscription_frame("user", ["BTC-USD"], @credentials)
      after_mint = System.os_time(:second)

      %{"nbf" => nbf, "exp" => exp} = claims_of(frame)

      assert nbf <= before_mint
      assert exp - nbf == 120
      assert exp > after_mint
      assert exp <= after_mint + 120
    end

    test "a ticker subscribe, which is public, carries no token" do
      assert {:ok, frame} = Socket.subscription_frame("ticker", ["BTC-USD"], @credentials)
      refute Map.has_key?(frame, :jwt)
    end
  end
end

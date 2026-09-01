defmodule DpExchange.Coinbase.PrimeStakingTest do
  @moduledoc """
  Coinbase Prime custodial staking.

  D7 tier 4 says these are never tested against the live venue from here, so what is
  asserted is everything that can be wrong *before* the request leaves: the host, the path,
  the scope, the signed string, and the refusal when a credential or a portfolio is missing.

  **The scope assertions are the ones that matter.** A portfolio-scoped unstake redeems
  across every wallet in the portfolio and a wallet-scoped one redeems from the one named.
  A package that reached the wrong path would move the right amount out of the wrong place.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Fake, Prime}
  alias DpExchange.Core.Config

  @moduletag :capture_log

  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{
    access_key: "prime-key",
    passphrase: "prime-passphrase",
    signing_key: "prime-signing-key"
  }

  defp capturing(body, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:request, conn.method, conn.request_path, raw, Enum.into(conn.req_headers, %{})}
      )

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp opts(test_pid, extra \\ []) do
    Keyword.merge([plug: capturing(%{"ok" => true}, test_pid), retry_attempts: 0], extra)
  end

  describe "the two scopes reach two different paths" do
    test "a portfolio stake does not name a wallet" do
      me = self()

      assert {:ok, _result} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", Decimal.new("1"), opts(me))

      assert_receive {:request, "POST", path, _raw, _headers}
      assert path == "/v1/portfolios/pf-1/staking/initiate"
      refute path =~ "wallets"
    end

    test "a wallet stake names both" do
      me = self()

      assert {:ok, _result} =
               Prime.stake_wallet(@credentials, "pf-1", "w-9", "ETH", Decimal.new("1"), opts(me))

      assert_receive {:request, "POST", path, _raw, _headers}
      assert path == "/v1/portfolios/pf-1/wallets/w-9/staking/initiate"
    end

    test "a portfolio unstake redeems across the portfolio" do
      me = self()

      assert {:ok, _result} =
               Prime.unstake_portfolio(@credentials, "pf-1", "ETH", Decimal.new("1"), opts(me))

      assert_receive {:request, "POST", "/v1/portfolios/pf-1/staking/unstake", _raw, _headers}
    end

    test "a wallet unstake redeems from the wallet named" do
      me = self()

      assert {:ok, _result} =
               Prime.unstake_wallet(
                 @credentials,
                 "pf-1",
                 "w-9",
                 "ETH",
                 Decimal.new("1"),
                 opts(me)
               )

      assert_receive {:request, "POST", "/v1/portfolios/pf-1/wallets/w-9/staking/unstake", _r, _h}
    end

    test "a preview moves nothing and has its own path" do
      me = self()

      assert {:ok, _result} =
               Prime.preview_unstake_wallet(
                 @credentials,
                 "pf-1",
                 "w-9",
                 "ETH",
                 Decimal.new("1"),
                 opts(me)
               )

      assert_receive {:request, "POST", path, _raw, _headers}
      assert path == "/v1/portfolios/pf-1/wallets/w-9/staking/unstake/preview"
    end

    test "the two status reads are GETs at their own paths" do
      me = self()

      assert {:ok, _result} = Prime.unstake_status(@credentials, "pf-1", "w-9", opts(me))
      assert_receive {:request, "GET", unstake_path, _raw, _headers}
      assert unstake_path == "/v1/portfolios/pf-1/wallets/w-9/staking/unstake/status"

      assert {:ok, _result} = Prime.staking_status(@credentials, "pf-1", "w-9", opts(me))
      assert_receive {:request, "GET", status_path, _raw, _headers}
      assert status_path == "/v1/portfolios/pf-1/wallets/w-9/staking/status"
    end

    test "claiming rewards is a write at the wallet scope" do
      me = self()

      assert {:ok, _result} = Prime.claim_rewards(@credentials, "pf-1", "w-9", opts(me))

      assert_receive {:request, "POST", path, _raw, _headers}
      assert path == "/v1/portfolios/pf-1/wallets/w-9/staking/claim_rewards"
    end

    test "the validator query is a POST that reads" do
      me = self()

      assert {:ok, _result} =
               Prime.query_transaction_validators(
                 @credentials,
                 "pf-1",
                 opts(me, query: %{"currency" => "ETH"})
               )

      assert_receive {:request, "POST", path, raw, _headers}
      assert path == "/v1/portfolios/pf-1/staking/transaction-validators/query"
      # The filter is the venue's own vocabulary and is sent as given.
      assert Jason.decode!(raw) == %{"currency" => "ETH"}
    end
  end

  describe "what goes on the wire" do
    test "the amount is full notation, never scientific" do
      me = self()

      assert {:ok, _result} =
               Prime.stake_portfolio(
                 @credentials,
                 "pf-1",
                 "eth",
                 Decimal.new("0.00000001"),
                 opts(me)
               )

      assert_receive {:request, "POST", _path, raw, _headers}
      body = Jason.decode!(raw)
      assert body["amount"] == "0.00000001"
      assert body["currency"] == "ETH"
    end

    test "an idempotency key is passed through and never invented" do
      # A key the caller cannot reproduce protects nothing on a retry it did not make.
      me = self()

      assert {:ok, _result} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", Decimal.new("1"), opts(me))

      assert_receive {:request, "POST", _path, raw, _headers}
      refute Map.has_key?(Jason.decode!(raw), "idempotency_key")

      assert {:ok, _result} =
               Prime.stake_portfolio(
                 @credentials,
                 "pf-1",
                 "ETH",
                 Decimal.new("1"),
                 opts(me, idempotency_key: "given-by-caller")
               )

      assert_receive {:request, "POST", _path, raw2, _headers}
      assert Jason.decode!(raw2)["idempotency_key"] == "given-by-caller"
    end

    test "all four Prime headers are sent" do
      me = self()

      assert {:ok, _result} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", Decimal.new("1"), opts(me))

      assert_receive {:request, "POST", _path, _raw, headers}
      assert headers["x-cb-access-key"] == "prime-key"
      assert headers["x-cb-access-passphrase"] == "prime-passphrase"
      assert headers["x-cb-access-timestamp"] =~ ~r/^\d+$/
      assert byte_size(headers["x-cb-access-signature"]) > 0
    end

    test "the signature covers timestamp, verb, the /v1 path and the body" do
      # Signing the suffix without the /v1 prefix produces a valid signature over the wrong
      # string, which the venue reports as a credential problem rather than a path one.
      me = self()

      assert {:ok, _result} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", Decimal.new("1"), opts(me))

      assert_receive {:request, "POST", path, raw, headers}

      expected =
        :hmac
        |> :crypto.mac(
          :sha256,
          @credentials.signing_key,
          headers["x-cb-access-timestamp"] <> "POST" <> path <> raw
        )
        |> Base.encode64()

      assert headers["x-cb-access-signature"] == expected
    end

    test "a GET signs an empty body rather than the string \"nil\"" do
      me = self()

      assert {:ok, _result} = Prime.staking_status(@credentials, "pf-1", "w-9", opts(me))
      assert_receive {:request, "GET", path, _raw, headers}

      expected =
        :hmac
        |> :crypto.mac(
          :sha256,
          @credentials.signing_key,
          headers["x-cb-access-timestamp"] <> "GET" <> path
        )
        |> Base.encode64()

      assert headers["x-cb-access-signature"] == expected
    end
  end

  describe "credentials and refusals" do
    test "two of the three credentials is a refusal, not a signed request" do
      # A request signed with a partial triple is signed and wrong, and the venue reports
      # that as an authentication failure rather than as a missing field here.
      assert {:error, :missing_prime_credentials} =
               Prime.stake_portfolio(
                 %{access_key: "k", passphrase: "p"},
                 "pf-1",
                 "ETH",
                 Decimal.new("1"),
                 []
               )
    end

    test "the CDP key pair the rest of this package uses is not accepted" do
      assert {:error, :missing_prime_credentials} =
               Prime.staking_status(
                 %{api_key: "organizations/x", api_secret: "pem"},
                 "p",
                 "w",
                 []
               )
    end

    test "a 401 is a refusal, because retrying the same bytes cannot succeed" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"message" => "invalid signature"}))
      end

      assert {:refused, _body} =
               Prime.staking_status(@credentials, "pf-1", "w-9", plug: plug, retry_attempts: 0)
    end

    test "a 500 is an error, because retrying can help" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"message" => "boom"}))
      end

      assert {:error, {:exchange_error, :coinbase, _message}} =
               Prime.staking_status(@credentials, "pf-1", "w-9", plug: plug, retry_attempts: 0)
    end

    test "an unexpected status is an error, not a refusal" do
      # Measured 2026-09-01: Core's client collapses every non-2xx into an error whose
      # message carries the status, so the status is read back out of the string. Anything
      # that is not 400/401/403/404 stays an error, which is the retryable answer.
      plug = fn conn -> Plug.Conn.resp(conn, 302, "moved") end

      assert {:error, {:exchange_error, :coinbase, message}} =
               Prime.staking_status(@credentials, "pf-1", "w-9", plug: plug, retry_attempts: 0)

      assert message =~ "302"
    end

    test "a 200 that is not a map is unreadable, not an empty result" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(["not", "a", "map"]))
      end

      assert {:error, :unexpected_response_shape} =
               Prime.staking_status(@credentials, "pf-1", "w-9", plug: plug, retry_attempts: 0)
    end
  end

  describe "the facade chooses a scope only from what the caller said" do
    test "no portfolio is refused before a request is made" do
      assert {:error, :missing_portfolio} =
               DpExchange.Coinbase.stake("ETH", Decimal.new("1"), credentials: @credentials)
    end

    test "a portfolio alone means the portfolio scope" do
      me = self()

      assert {:ok, _result} =
               DpExchange.Coinbase.stake(
                 "ETH",
                 Decimal.new("1"),
                 opts(me, credentials: @credentials, portfolio_id: "pf-1")
               )

      assert_receive {:request, "POST", "/v1/portfolios/pf-1/staking/initiate", _raw, _headers}
    end

    test "adding a wallet moves it to the wallet scope" do
      me = self()

      assert {:ok, _result} =
               DpExchange.Coinbase.unstake(
                 "ETH",
                 Decimal.new("1"),
                 opts(me, credentials: @credentials, portfolio_id: "pf-1", wallet_id: "w-9")
               )

      assert_receive {:request, "POST", path, _raw, _headers}
      assert path == "/v1/portfolios/pf-1/wallets/w-9/staking/unstake"
    end
  end

  describe "the fake holds the same guards" do
    test "a stake without a portfolio is refused" do
      assert {:error, :missing_portfolio} = Fake.stake("ETH", Decimal.new("1"))
      assert {:error, :missing_portfolio} = Fake.unstake("ETH", Decimal.new("1"))
    end

    test "the scope follows the wallet, as it does in the package" do
      assert {:ok, portfolio} = Fake.stake("ETH", Decimal.new("1"), portfolio_id: "pf-1")
      assert portfolio["scope"] == "portfolio"

      assert {:ok, wallet} =
               Fake.stake("ETH", Decimal.new("1"), portfolio_id: "pf-1", wallet_id: "w-9")

      assert wallet["scope"] == "wallet"
    end

    test "an unstake is not settled" do
      assert {:ok, result} = Fake.unstake("ETH", Decimal.new("1"), portfolio_id: "pf-1")
      assert result["settled"] == false
    end
  end

  describe "what a caller can add, and what it cannot" do
    test "extra body fields the venue documents are merged in" do
      # Prime's staking bodies carry venue-specific fields this package does not model. They
      # are the caller's to supply; inventing names for them here would be guessing at a
      # vocabulary only Prime defines.
      me = self()

      assert {:ok, _result} =
               Prime.stake_wallet(
                 @credentials,
                 "pf-1",
                 "w-9",
                 "ETH",
                 Decimal.new("1"),
                 opts(me, extra: %{"validator_address" => "0xabc"})
               )

      assert_receive {:request, "POST", _path, raw, _headers}
      body = Jason.decode!(raw)
      assert body["validator_address"] == "0xabc"
      assert body["currency"] == "ETH"
    end

    test "claim_rewards sends an empty body by default and the caller's when given" do
      me = self()

      assert {:ok, _result} = Prime.claim_rewards(@credentials, "pf-1", "w-9", opts(me))
      assert_receive {:request, "POST", _path, raw, _headers}
      assert Jason.decode!(raw) == %{}

      assert {:ok, _result} =
               Prime.claim_rewards(@credentials, "pf-1", "w-9", opts(me, body: %{"c" => "ETH"}))

      assert_receive {:request, "POST", _path, raw2, _headers}
      assert Jason.decode!(raw2) == %{"c" => "ETH"}
    end

    test "the validator query defaults to an empty filter rather than omitting the body" do
      me = self()

      assert {:ok, _result} = Prime.query_transaction_validators(@credentials, "pf-1", opts(me))
      assert_receive {:request, "POST", _path, raw, _headers}
      assert Jason.decode!(raw) == %{}
    end

    test "a transport failure stays an error, not a refusal" do
      # A connection that never reached the venue said nothing about the request. Reporting
      # it as a refusal would tell a caller the venue declined something it never saw.
      plug = fn _conn -> raise "connection reset" end

      assert {:error, _reason} =
               Prime.staking_status(@credentials, "pf-1", "w-9", plug: plug, retry_attempts: 0)
    end
  end
end

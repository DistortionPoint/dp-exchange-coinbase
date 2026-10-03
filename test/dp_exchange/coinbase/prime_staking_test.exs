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
                 opts(me, transaction_ids: ["tx-1", "tx-2"])
               )

      assert_receive {:request, "POST", path, raw, _headers}
      assert path == "/v1/portfolios/pf-1/staking/transaction-validators/query"
      assert Jason.decode!(raw) == %{"transaction_ids" => ["tx-1", "tx-2"]}
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
      assert body["currency_symbol"] == "ETH"
    end

    test "an idempotency key is ALWAYS sent, generated when the caller gives none" do
      # **This asserted the opposite**, on the reasoning that "a key the caller cannot
      # reproduce protects nothing on a retry it did not make". That half is true and worth
      # keeping in view: a caller who calls `stake_portfolio/5` a second time gets a fresh
      # key, and the venue cannot tell that from a second stake — because it is one.
      #
      # It is the wrong retry. `Core.HttpClient` retries a timeout or a 5xx **three times by
      # default**, re-sending the identical body, and `Prime.request_opts/1` forwards
      # `:retry_attempts` unchanged. Against a generated key those attempts carry the same
      # value and the venue returns the original result; against no key at all they are
      # three separate stakes. The old test reasoned about the caller's retry and the defect
      # lived in the package's own.
      #
      # `Rest.place_order/3` had already settled the identical question the other way —
      # "re-sending one returns the original order instead of placing a second" — with a key
      # the caller equally cannot reproduce. Two paths in one package disagreeing about the
      # same venue mechanism is what this is.
      me = self()

      assert {:ok, _result} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", Decimal.new("1"), opts(me))

      assert_receive {:request, "POST", _path, raw, _headers}
      generated = Jason.decode!(raw)["idempotency_key"]

      assert is_binary(generated) and generated != "",
             "a staking write with no idempotency key is a write HttpClient will send three times"

      assert {:ok, _result} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", Decimal.new("1"), opts(me))

      assert_receive {:request, "POST", _path, raw_again, _headers}

      refute Jason.decode!(raw_again)["idempotency_key"] == generated,
             "two separate calls are two separate stakes and must not share a key"
    end

    test "a caller's own idempotency key is used, never overwritten" do
      me = self()

      assert {:ok, _result} =
               Prime.stake_portfolio(
                 @credentials,
                 "pf-1",
                 "ETH",
                 Decimal.new("1"),
                 opts(me, idempotency_key: "given-by-caller")
               )

      assert_receive {:request, "POST", _path, raw, _headers}
      assert Jason.decode!(raw)["idempotency_key"] == "given-by-caller"
    end

    test "claim_rewards/4 now retries like the other staking writes, key or no key" do
      # This used to send one attempt only, reasoning that its body was opaque and an
      # `idempotency_key` could not safely be injected into a caller's own map. The schema is
      # no longer unknown — `StakingClaimRewardsRequest` requires exactly the key this module
      # already generates for `stake_wallet/6` and the rest — so `claim_rewards_body/1` always
      # puts one in, and `Core.HttpClient`'s default retry count is no longer overridden away.
      # Note that `opts/2` above pins `retry_attempts: 0` for every other test in this file,
      # which is why the package's real default is exercised explicitly here instead.
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        Plug.Conn.resp(conn, 500, "upstream is having a bad day")
      end

      assert {:error, _reason} =
               Prime.claim_rewards(@credentials, "pf-1", "w-1", plug: plug, retry_delay: 1)

      assert :counters.get(counter, 1) > 1,
             "claim_rewards/4 carries a generated idempotency_key now, so a retried attempt " <>
               "is safe the same way a stake's retry is"
    end

    test "unstaking carries a key too, not only staking" do
      # Both directions move an asset, and both go through the same body builder. Asserted
      # rather than assumed, because "the fix landed on one of the pair" is the shape this
      # family keeps finding.
      me = self()

      assert {:ok, _result} =
               Prime.unstake_portfolio(@credentials, "pf-1", "ETH", Decimal.new("1"), opts(me))

      assert_receive {:request, "POST", _path, raw, _headers}
      assert is_binary(Jason.decode!(raw)["idempotency_key"])
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
                 %{
                   api_key: "organizations/x",
                   api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
                 },
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

  describe "the facade chooses the operation, not only the scope" do
    # The other two cells of the same 2x2. `stake`+portfolio and `unstake`+wallet were
    # tested above; `unstake`+portfolio and `stake`+wallet were not, and those are the two
    # branches of `prime_portfolio/6` and `prime_wallet/7` the suite never executed.
    #
    # Worth having rather than assumed-by-symmetry: the operation atom is what picks between
    # `stake_portfolio` and `unstake_portfolio`, so a transposed clause sends a redemption to
    # the initiate path. Both numbers stay real, the call succeeds, and the account does the
    # opposite of what the caller asked — on the one surface in this package that moves
    # staked funds. The path assertion is what catches it.
    test "a portfolio alone with unstake means the portfolio unstake path" do
      me = self()

      assert {:ok, _result} =
               DpExchange.Coinbase.unstake(
                 "ETH",
                 Decimal.new("1"),
                 opts(me, credentials: @credentials, portfolio_id: "pf-1")
               )

      assert_receive {:request, "POST", path, _raw, _headers}
      assert path == "/v1/portfolios/pf-1/staking/unstake"
      refute path =~ "initiate"
    end

    test "a wallet with stake means the wallet initiate path" do
      me = self()

      assert {:ok, _result} =
               DpExchange.Coinbase.stake(
                 "ETH",
                 Decimal.new("1"),
                 opts(me, credentials: @credentials, portfolio_id: "pf-1", wallet_id: "w-9")
               )

      assert_receive {:request, "POST", path, _raw, _headers}
      assert path == "/v1/portfolios/pf-1/wallets/w-9/staking/initiate"
      refute path =~ "unstake"
    end
  end

  describe "the facade reaches the rest of Prime's nine endpoints directly" do
    test "query_transaction_validators/3 reaches the portfolio-scoped path" do
      me = self()

      assert {:ok, _result} =
               DpExchange.Coinbase.query_transaction_validators(
                 @credentials,
                 "pf-1",
                 opts(me, transaction_ids: ["tx-1"])
               )

      assert_receive {:request, "POST", path, _raw, _headers}
      assert path == "/v1/portfolios/pf-1/staking/transaction-validators/query"
    end

    test "staking_status/4 reaches the wallet-scoped GET" do
      me = self()

      assert {:ok, _result} =
               DpExchange.Coinbase.staking_status(@credentials, "pf-1", "w-9", opts(me))

      assert_receive {:request, "GET", path, _raw, _headers}
      assert path == "/v1/portfolios/pf-1/wallets/w-9/staking/status"
    end

    test "unstake_status/4 reaches the wallet-scoped GET" do
      me = self()

      assert {:ok, _result} =
               DpExchange.Coinbase.unstake_status(@credentials, "pf-1", "w-9", opts(me))

      assert_receive {:request, "GET", path, _raw, _headers}
      assert path == "/v1/portfolios/pf-1/wallets/w-9/staking/unstake/status"
    end

    test "claim_rewards/4 reaches the wallet-scoped write" do
      me = self()

      assert {:ok, _result} =
               DpExchange.Coinbase.claim_rewards(@credentials, "pf-1", "w-9", opts(me))

      assert_receive {:request, "POST", path, _raw, _headers}
      assert path == "/v1/portfolios/pf-1/wallets/w-9/staking/claim_rewards"
    end

    test "preview_unstake_wallet/6 reaches the preview path and moves nothing" do
      me = self()

      assert {:ok, _result} =
               DpExchange.Coinbase.preview_unstake_wallet(
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
    test "extra body fields the venue documents are merged into a wallet stake's inputs" do
      # `WalletStakeInputs` carries `amount` plus asset-specific fields like
      # `validator_address` and `end_date`, all nested under `inputs`
      # (docs/reference/coinbase/openapi/prime-spec.yaml:15857-15873). They are the caller's
      # to supply; inventing names for them here would be guessing at a vocabulary only Prime
      # defines, but they belong under `inputs`, not at the top level the old flat body used.
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
      assert body["inputs"]["validator_address"] == "0xabc"
      assert body["inputs"]["amount"] == "1"
      refute Map.has_key?(body, "currency")
      refute Map.has_key?(body, "validator_address")
    end

    test "a wallet stake sends no currency field at all — the wallet already names one asset" do
      me = self()

      assert {:ok, _result} =
               Prime.stake_wallet(@credentials, "pf-1", "w-9", "ETH", Decimal.new("1"), opts(me))

      assert_receive {:request, "POST", _path, raw, _headers}
      body = Jason.decode!(raw)
      refute Map.has_key?(body, "currency")
      refute Map.has_key?(body, "currency_symbol")
      assert body["inputs"]["amount"] == "1"
    end

    test "opts[:metadata] is sent as the sibling of inputs, not merged into it" do
      me = self()

      assert {:ok, _result} =
               Prime.unstake_wallet(
                 @credentials,
                 "pf-1",
                 "w-9",
                 "ETH",
                 Decimal.new("1"),
                 opts(me, metadata: %{"external_id" => "ext-1"})
               )

      assert_receive {:request, "POST", _path, raw, _headers}
      body = Jason.decode!(raw)
      assert body["metadata"] == %{"external_id" => "ext-1"}
      refute Map.has_key?(body["inputs"], "external_id")
    end

    test "a preview sends only {amount} — no currency, no idempotency_key" do
      # PreviewUnstakeRequest's body is `{amount}` alone
      # (docs/reference/coinbase/openapi/prime-spec.yaml:9083-9090). This used to send the
      # same generated-idempotency-key body as a real unstake, on a call the venue documents
      # as moving nothing.
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

      assert_receive {:request, "POST", _path, raw, _headers}
      assert Jason.decode!(raw) == %{"amount" => "1"}
    end

    test "claim_rewards generates an idempotency_key by default and merges into a caller body" do
      me = self()

      assert {:ok, _result} = Prime.claim_rewards(@credentials, "pf-1", "w-9", opts(me))
      assert_receive {:request, "POST", _path, raw, _headers}
      generated = Jason.decode!(raw)
      assert is_binary(generated["idempotency_key"]) and generated["idempotency_key"] != ""
      refute Map.has_key?(generated, "inputs")

      assert {:ok, _result} =
               Prime.claim_rewards(
                 @credentials,
                 "pf-1",
                 "w-9",
                 opts(me, body: %{"idempotency_key" => "caller-key"})
               )

      assert_receive {:request, "POST", _path, raw2, _headers}
      # A key already present in the caller's own body is kept, not overwritten.
      assert Jason.decode!(raw2) == %{"idempotency_key" => "caller-key"}
    end

    test "claim_rewards reads opts[:amount] into inputs.amount" do
      me = self()

      assert {:ok, _result} =
               Prime.claim_rewards(
                 @credentials,
                 "pf-1",
                 "w-9",
                 opts(me, amount: Decimal.new("2"))
               )

      assert_receive {:request, "POST", _path, raw, _headers}
      body = Jason.decode!(raw)
      assert body["inputs"]["amount"] == "2"
      assert is_binary(body["idempotency_key"])
    end

    test "the validator query is refused locally when transaction_ids is missing" do
      assert {:error, :missing_transaction_ids} =
               Prime.query_transaction_validators(@credentials, "pf-1", [])

      assert {:error, :missing_transaction_ids} =
               Prime.query_transaction_validators(@credentials, "pf-1", transaction_ids: [])
    end

    test "a transport failure stays an error, not a refusal" do
      # A connection that never reached the venue said nothing about the request. Reporting
      # it as a refusal would tell a caller the venue declined something it never saw.
      plug = fn _conn -> raise "connection reset" end

      assert {:error, _reason} =
               Prime.staking_status(@credentials, "pf-1", "w-9", plug: plug, retry_attempts: 0)
    end
  end

  describe "rate_limit_blocking — family-wide gap, DpCryptoManagement issue #23" do
    # A real limiter module, recording which entry point it was actually called through —
    # the only way to prove `:rate_limit_blocking` reached `Core.HttpClient` rather than
    # merely appearing in `request_opts/1`'s own allowlist.
    defmodule RecordingLimiter do
      @moduledoc false
      @behaviour DpExchange.Core.RateLimitBehaviour

      @impl true
      # dp_exchange_core 0.3.52: a non-blocking request reserves with `acquire/3` and a zero
      # timeout (it never waits), where it used to `check/3` first and race other callers.
      def acquire(_provider, _weight, opts) do
        call = if Keyword.get(opts, :timeout) == 0, do: :acquire_without_waiting, else: :acquire
        Process.put(:rate_limiter_call, call)
        :ok
      end

      @impl true
      def check(_provider, _weight, _opts) do
        Process.put(:rate_limiter_call, :check)
        :ok
      end

      @impl true
      def record(_provider, _weight, _opts), do: :ok
    end

    test "rate_limit_blocking: true reaches Core.HttpClient as acquire/3" do
      Config.put_override(:rate_limit_module, RecordingLimiter)
      plug = fn conn -> Req.Test.json(conn, %{"status" => "ACTIVE"}) end

      assert {:ok, _result} =
               Prime.staking_status(@credentials, "pf-1", "w-9",
                 plug: plug,
                 retry_attempts: 0,
                 rate_limit_blocking: true
               )

      assert Process.get(:rate_limiter_call) == :acquire
    end

    test "rate_limit_blocking: false (or omitted) reaches Core.HttpClient as acquire/3 with no wait" do
      Config.put_override(:rate_limit_module, RecordingLimiter)
      plug = fn conn -> Req.Test.json(conn, %{"status" => "ACTIVE"}) end

      assert {:ok, _result} =
               Prime.staking_status(@credentials, "pf-1", "w-9", plug: plug, retry_attempts: 0)

      assert Process.get(:rate_limiter_call) == :acquire_without_waiting
    end
  end

  describe "a retried Prime request" do
    test "is signed again, with its own timestamp" do
      # A retry carrying the first attempt's `X-CB-ACCESS-TIMESTAMP` ages with every attempt
      # until the venue refuses it. The first attempt is held past a second so a timestamp
      # re-read for the retry cannot equal the first one.
      me = self()
      counter = :counters.new(1, [])

      plug = fn conn ->
        :counters.add(counter, 1, 1)
        send(me, {:timestamp, Plug.Conn.get_req_header(conn, "x-cb-access-timestamp")})
        if :counters.get(counter, 1) == 1, do: Process.sleep(1_100)
        Plug.Conn.resp(conn, 503, "unavailable")
      end

      Prime.stake_portfolio(@credentials, "pf-1", "ETH", Decimal.new("1"),
        plug: plug,
        retry_attempts: 2,
        retry_delay: 1
      )

      assert_received {:timestamp, [first]}
      assert_received {:timestamp, [second]}
      assert String.to_integer(second) > String.to_integer(first)
    end
  end
end

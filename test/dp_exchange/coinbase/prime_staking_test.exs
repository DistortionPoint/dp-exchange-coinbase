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
  alias DpExchange.Core.{Config, Types}

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

  # A wallet-scoped stake or unstake first READS the wallet (`GET .../wallets/{wid}`) to check
  # the asset it was told against the asset the wallet holds. This stub answers that read as a
  # wallet holding ETH; every other request gets `body`.
  defp capturing(body, test_pid, wallet_symbol \\ "ETH") do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)

      send(
        test_pid,
        {:request, conn.method, conn.request_path, raw, Enum.into(conn.req_headers, %{})}
      )

      reply =
        if wallet_read?(conn), do: %{"wallet" => %{"symbol" => wallet_symbol}}, else: body

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(reply))
    end
  end

  defp wallet_read?(conn) do
    conn.method == "GET" and
      Regex.match?(~r{\A/v1/portfolios/[^/]+/wallets/[^/]+\z}, conn.request_path)
  end

  defp opts(test_pid, extra \\ []) do
    ok = %{"ok" => true, "transaction_id" => "txn-1"}
    Keyword.merge([plug: capturing(ok, test_pid), retry_attempts: 0], extra)
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

    test "claiming rewards refuses an amount it cannot send, instead of raising or sending it" do
      me = self()

      for bad <- [1.5, 3, "1", Decimal.new("0"), Decimal.new("-1"), Decimal.new("NaN")] do
        assert {:error, {:invalid_amount, _amount}} =
                 Prime.claim_rewards(@credentials, "pf-1", "w-9", opts(me, amount: bad))
      end

      refute_received {:request, _method, _path, _raw, _headers}

      good = opts(me, amount: Decimal.new("2"))
      assert {:ok, _result} = Prime.claim_rewards(@credentials, "pf-1", "w-9", good)

      assert_receive {:request, "POST", _path, raw, _headers}
      assert Jason.decode!(raw)["inputs"] == %{"amount" => "2"}
    end

    test "claiming rewards refuses a body that is not a map or carries an unusable key" do
      me = self()

      assert {:error, {:invalid_body, "x"}} =
               Prime.claim_rewards(@credentials, "pf-1", "w-9", opts(me, body: "x"))

      bodies = [%{"idempotency_key" => ""}, %{"idempotency_key" => nil}, %{idempotency_key: 5}]

      for bad <- bodies do
        assert {:error, {:invalid_idempotency_key, _key}} =
                 Prime.claim_rewards(@credentials, "pf-1", "w-9", opts(me, body: bad))
      end

      refute_received {:request, _method, _path, _raw, _headers}
    end

    test "an atom-keyed idempotency_key in the body is the same field, sent once" do
      me = self()
      good = opts(me, body: %{idempotency_key: "6f1d2a40-0000-4000-8000-000000000001"})
      assert {:ok, _result} = Prime.claim_rewards(@credentials, "pf-1", "w-9", good)

      assert_receive {:request, "POST", _path, raw, _headers}, 5_000
      assert Jason.decode!(raw) == %{"idempotency_key" => "6f1d2a40-0000-4000-8000-000000000001"}
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

  describe "a write that cannot be sent is refused, not raised" do
    test "a non-Decimal, non-positive or non-finite amount, or a nil asset, sends nothing" do
      me = self()

      for amount <- [1.5, nil, "1", Decimal.new(0), Decimal.new(-1), Decimal.new("NaN")] do
        assert {:error, {:invalid_amount, ^amount}} =
                 Prime.stake_portfolio(@credentials, "pf-1", "ETH", amount, opts(me))

        assert {:error, {:invalid_amount, ^amount}} =
                 Prime.stake_wallet(@credentials, "pf-1", "w-1", "ETH", amount, opts(me))
      end

      assert {:error, {:invalid_asset, nil}} =
               Prime.unstake_portfolio(@credentials, "pf-1", nil, Decimal.new(1), opts(me))

      refute_received {:request, _method, _path, _raw, _headers}
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
      # It is the wrong retry. A staking write retries a timeout or a 5xx **three times by
      # default** (`Prime.retried/1`; Core alone sends a POST once), re-sending the
      # identical body, and `Prime.request_opts/1` forwards `:retry_attempts` unchanged.
      # Against a generated key those attempts carry the same value and the venue returns
      # the original result; against no key at all they are three separate stakes.
      # The old test reasoned about the caller's retry and the defect lived in the package's
      # own.
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
                 opts(me, idempotency_key: "6f1d2a40-0000-4000-8000-000000000002")
               )

      assert_receive {:request, "POST", _path, raw, _headers}
      assert Jason.decode!(raw)["idempotency_key"] == "6f1d2a40-0000-4000-8000-000000000002"
    end

    test "claim_rewards/4 now retries like the other staking writes, key or no key" do
      # This used to send one attempt only, reasoning that its body was opaque and an
      # `idempotency_key` could not safely be injected into a caller's own map. The schema is
      # no longer unknown — `StakingClaimRewardsRequest` requires exactly the key this module
      # already generates for `stake_wallet/6` and the rest — so `claim_rewards_body/1` always
      # puts one in, and `Prime.retried/1`'s three attempts are no longer overridden away.
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

    test "both scopes answer a StakingTransaction, as the real facade does" do
      for extra <- [[], [wallet_id: "w-9"]] do
        assert {:ok, %Types.StakingTransaction{} = tx} =
                 Fake.stake(
                   "eth",
                   Decimal.new("1"),
                   [portfolio_id: "pf-1", credentials: @credentials] ++ extra
                 )

        assert tx.type == :stake
        assert tx.asset == "ETH"
        assert Decimal.equal?(tx.amount, Decimal.new("1"))
        assert tx.amount_remaining == nil
        assert tx.provider == :coinbase
        assert is_binary(tx.id) and tx.id != ""
      end
    end

    test "each placement gets its own id, and a reused idempotency key answers the original" do
      opts = [portfolio_id: "pf-1", credentials: @credentials]

      assert {:ok, first} = Fake.stake("ETH", Decimal.new("1"), opts)
      assert {:ok, second} = Fake.stake("ETH", Decimal.new("1"), opts)
      refute first.id == second.id

      keyed = [idempotency_key: "6f1d2a40-0000-4000-8000-000000000009"] ++ opts
      assert {:ok, a} = Fake.stake("ETH", Decimal.new("1"), keyed)
      assert {:ok, b} = Fake.stake("ETH", Decimal.new("1"), keyed)
      assert a.id == b.id
    end

    test "the fake refuses what Prime.validate_write refuses, in the same order" do
      one = Decimal.new("1")
      base = [portfolio_id: "pf-1", credentials: @credentials]

      # Not a UUID, empty, or not a string: the real path refuses all three.
      for bad <- ["", "not-a-uuid", 7] do
        expected = {:error, {:invalid_idempotency_key, bad}}
        assert expected == Fake.stake("ETH", one, [idempotency_key: bad] ++ base)
        assert expected == Fake.unstake("ETH", one, [idempotency_key: bad] ++ base)
        real = [idempotency_key: bad, retry_attempts: 0]
        assert expected == Prime.stake_portfolio(@credentials, "pf-1", "ETH", one, real)
      end

      assert {:error, {:invalid_extra, "x"}} = Fake.stake("ETH", one, [extra: "x"] ++ base)

      # The 64-place exponent bound the real path applies to every amount.
      wide = %Decimal{sign: 1, coef: 1, exp: 999_999_999}
      assert {:error, {:invalid_amount, ^wide}} = Fake.stake("ETH", wide, base)
      assert {:error, {:invalid_amount, ^wide}} = Fake.unstake("ETH", wide, base)

      # The positional arguments are refused before the options (family check order).
      assert {:error, {:invalid_asset, nil}} = Fake.stake(nil, one, [metdata: 1] ++ base)
      assert {:error, {:invalid_amount, 1.5}} = Fake.unstake("ETH", 1.5, [metdata: 1] ++ base)

      assert {:error, {:invalid_asset, nil}} =
               DpExchange.Coinbase.stake(nil, one, [metdata: 1] ++ base)

      assert {:error, {:unknown_option, :metdata}} = Fake.stake("ETH", one, [metdata: 1] ++ base)

      # The asset is checked in the wallet scope too.
      assert {:error, {:invalid_asset, :eth}} =
               Fake.stake(:eth, one, [wallet_id: "w-1"] ++ base)
    end

    test "a stake without Prime credentials, or with an unsendable amount, is refused" do
      assert {:error, :missing_prime_credentials} =
               Fake.stake("ETH", Decimal.new("1"), portfolio_id: "pf-1")

      assert {:error, {:invalid_amount, 1.5}} =
               Fake.stake("ETH", 1.5, portfolio_id: "pf-1", credentials: @credentials)

      assert {:error, {:invalid_asset, nil}} =
               Fake.unstake(nil, Decimal.new("1"),
                 portfolio_id: "pf-1",
                 credentials: @credentials
               )
    end

    test "an unstake is not settled: the whole amount is still remaining" do
      assert {:ok, %Types.StakingTransaction{} = tx} =
               Fake.unstake("ETH", Decimal.new("1"),
                 portfolio_id: "pf-1",
                 credentials: @credentials
               )

      assert tx.type == :unstake
      assert Decimal.equal?(tx.amount_remaining, Decimal.new("1"))
      assert Types.StakingTransaction.settled?(tx) == false
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

    test "opts[:metadata] is a top-level member of both portfolio-scoped bodies too" do
      # PortfolioStakingMetadata, prime-spec.yaml:7286 (initiate) and :7453 (unstake). The
      # portfolio body used to drop it while the wallet body sent it.
      me = self()
      metadata = %{"external_id" => "ext-2"}
      extra = opts(me, metadata: metadata)

      assert {:ok, _result} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", Decimal.new("1"), extra)

      assert_receive {:request, "POST", "/v1/portfolios/pf-1/staking/initiate", raw, _headers}
      assert Jason.decode!(raw)["metadata"] == metadata

      assert {:ok, _result} =
               Prime.unstake_portfolio(@credentials, "pf-1", "ETH", Decimal.new("1"), extra)

      assert_receive {:request, "POST", "/v1/portfolios/pf-1/staking/unstake", raw, _headers}
      assert Jason.decode!(raw)["metadata"] == metadata
    end

    test "a portfolio body without metadata carries no metadata member" do
      me = self()

      assert {:ok, _result} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", Decimal.new("1"), opts(me))

      assert_receive {:request, "POST", _path, raw, _headers}
      refute Map.has_key?(Jason.decode!(raw), "metadata")
    end

    test "metadata that is not a map is refused on both scopes and by the Fake, nothing sent" do
      me = self()
      bad = opts(me, metadata: "ext-3")
      one = Decimal.new("1")

      assert {:error, {:invalid_metadata, "ext-3"}} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", one, bad)

      assert {:error, {:invalid_metadata, "ext-3"}} =
               Prime.unstake_portfolio(@credentials, "pf-1", "ETH", one, bad)

      assert {:error, {:invalid_metadata, "ext-3"}} =
               Prime.stake_wallet(@credentials, "pf-1", "w-9", "ETH", one, bad)

      assert {:error, {:invalid_metadata, "ext-3"}} =
               Prime.unstake_wallet(@credentials, "pf-1", "w-9", "ETH", one, bad)

      assert {:error, {:invalid_metadata, "ext-3"}} =
               Fake.stake("ETH", one,
                 portfolio_id: "pf-1",
                 credentials: @credentials,
                 metadata: "ext-3"
               )

      refute_received {:request, _method, _path, _raw, _headers}
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
                 opts(me, body: %{"idempotency_key" => "6f1d2a40-0000-4000-8000-000000000003"})
               )

      assert_receive {:request, "POST", _path, raw2, _headers}
      # A key already present in the caller's own body is kept, not overwritten.
      assert Jason.decode!(raw2) == %{"idempotency_key" => "6f1d2a40-0000-4000-8000-000000000003"}
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

  describe "what is refused before anything is signed" do
    @bad_ids [nil, "", " ", "a/b", "../x", "pf?x=1", "pf.1", 7, :atom, ["pf-1"]]

    test "a portfolio or wallet id that is not a plain path segment sends nothing" do
      me = self()
      one = Decimal.new(1)

      for bad <- @bad_ids do
        assert {:error, {:invalid_portfolio_id, ^bad}} =
                 Prime.stake_portfolio(@credentials, bad, "ETH", one, opts(me))

        assert {:error, {:invalid_portfolio_id, ^bad}} =
                 Prime.unstake_portfolio(@credentials, bad, "ETH", one, opts(me))

        assert {:error, {:invalid_portfolio_id, ^bad}} =
                 Prime.query_transaction_validators(
                   @credentials,
                   bad,
                   opts(me, transaction_ids: ["tx-1"])
                 )

        assert {:error, {:invalid_portfolio_id, ^bad}} =
                 Prime.stake_wallet(@credentials, bad, "w-1", "ETH", one, opts(me))

        assert {:error, {:invalid_wallet_id, ^bad}} =
                 Prime.stake_wallet(@credentials, "pf-1", bad, "ETH", one, opts(me))

        assert {:error, {:invalid_wallet_id, ^bad}} =
                 Prime.unstake_wallet(@credentials, "pf-1", bad, "ETH", one, opts(me))

        assert {:error, {:invalid_wallet_id, ^bad}} =
                 Prime.preview_unstake_wallet(@credentials, "pf-1", bad, "ETH", one, opts(me))

        assert {:error, {:invalid_wallet_id, ^bad}} =
                 Prime.claim_rewards(@credentials, "pf-1", bad, opts(me))

        assert {:error, {:invalid_wallet_id, ^bad}} =
                 Prime.staking_status(@credentials, "pf-1", bad, opts(me))

        assert {:error, {:invalid_wallet_id, ^bad}} =
                 Prime.unstake_status(@credentials, "pf-1", bad, opts(me))
      end

      refute_received {:request, _method, _path, _raw, _headers}
    end

    test "the facade's wallet scope cannot reach /wallets//" do
      # `stake/3` picks the wallet scope on `wallet_id != nil`, so `""` was a wallet.
      me = self()

      assert {:error, {:invalid_wallet_id, ""}} =
               DpExchange.Coinbase.stake(
                 "ETH",
                 Decimal.new(1),
                 opts(me, credentials: @credentials, portfolio_id: "pf-1", wallet_id: "")
               )

      refute_received {:request, _method, _path, _raw, _headers}
    end

    test "an idempotency key that is given must be a non-empty string" do
      # The venue answers a repeated key with the first response, so `""` turned every later
      # stake into a copy of the first, reported as a success.
      me = self()
      one = Decimal.new(1)

      for bad <- ["", 7, :key, false] do
        assert {:error, {:invalid_idempotency_key, ^bad}} =
                 Prime.stake_portfolio(
                   @credentials,
                   "pf-1",
                   "ETH",
                   one,
                   opts(me, idempotency_key: bad)
                 )

        assert {:error, {:invalid_idempotency_key, ^bad}} =
                 Prime.unstake_wallet(
                   @credentials,
                   "pf-1",
                   "w-1",
                   "ETH",
                   one,
                   opts(me, idempotency_key: bad)
                 )

        assert {:error, {:invalid_idempotency_key, ^bad}} =
                 Prime.claim_rewards(@credentials, "pf-1", "w-1", opts(me, idempotency_key: bad))
      end

      refute_received {:request, _method, _path, _raw, _headers}

      assert {:ok, _result} =
               Prime.stake_portfolio(
                 @credentials,
                 "pf-1",
                 "ETH",
                 one,
                 opts(me, idempotency_key: "9b2c0c46-9d56-4c2c-8f43-0f7a4c2d9e11")
               )

      assert_receive {:request, "POST", _path, raw, _headers}
      assert Jason.decode!(raw)["idempotency_key"] == "9b2c0c46-9d56-4c2c-8f43-0f7a4c2d9e11"
    end

    test "opts[:extra] cannot replace the fields that were validated" do
      me = self()

      hostile = %{
        "amount" => "1000",
        "currency_symbol" => "DOGE",
        "idempotency_key" => "stolen",
        amount: "2000"
      }

      assert {:ok, _result} =
               Prime.stake_portfolio(
                 @credentials,
                 "pf-1",
                 "eth",
                 Decimal.new("1"),
                 opts(me, extra: hostile)
               )

      assert_receive {:request, "POST", _path, raw, _headers}
      body = Jason.decode!(raw)
      assert body["amount"] == "1"
      assert body["currency_symbol"] == "ETH"
      assert body["idempotency_key"] =~ ~r/\A[0-9a-f-]{36}\z/

      assert {:ok, _result} =
               Prime.stake_wallet(
                 @credentials,
                 "pf-1",
                 "w-1",
                 "ETH",
                 Decimal.new("1"),
                 opts(me, extra: %{"amount" => "1000", "validator_address" => "0xabc"})
               )

      assert_receive {:request, "POST", _path, raw, _headers}
      inputs = Jason.decode!(raw)["inputs"]
      assert inputs["amount"] == "1"
      assert inputs["validator_address"] == "0xabc"

      assert {:ok, _result} =
               Prime.query_transaction_validators(
                 @credentials,
                 "pf-1",
                 opts(me, transaction_ids: ["tx-1"], extra: %{"transaction_ids" => ["other"]})
               )

      assert_receive {:request, "POST", _path, raw, _headers}
      assert Jason.decode!(raw)["transaction_ids"] == ["tx-1"]
    end

    test "an extra field that cannot be encoded is refused as a value, nothing sent" do
      me = self()

      assert {:error, :unencodable_body} =
               Prime.stake_portfolio(
                 @credentials,
                 "pf-1",
                 "eth",
                 Decimal.new("1"),
                 opts(me, extra: %{"validator" => {:not, :json}})
               )

      assert {:error, :unencodable_body} =
               Prime.claim_rewards(
                 @credentials,
                 "pf-1",
                 "w-1",
                 opts(me, body: %{"inputs" => %{"x" => self()}})
               )

      refute_receive {:request, _method, _path, _raw, _headers}, 50
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

  describe "a wallet-scoped write is checked against the wallet's own asset" do
    test "an asset that is not the wallet's is refused and nothing is written" do
      me = self()
      plug = capturing(%{"transaction_id" => "txn-1"}, me, "SOL")
      real = [plug: plug, retry_attempts: 0]
      one = Decimal.new("1")

      assert {:error, {:wallet_asset_mismatch, "ETH", "SOL"}} =
               Prime.stake_wallet(@credentials, "pf-1", "w-1", "ETH", one, real)

      assert {:error, {:wallet_asset_mismatch, "ETH", "SOL"}} =
               Prime.unstake_wallet(@credentials, "pf-1", "w-1", "ETH", one, real)

      assert {:error, {:wallet_asset_mismatch, "ETH", "SOL"}} =
               DpExchange.Coinbase.stake(
                 "ETH",
                 one,
                 [credentials: @credentials, portfolio_id: "pf-1", wallet_id: "w-1"] ++ real
               )

      # The wallet was read once per call, and never written to.
      assert_receive {:request, "GET", "/v1/portfolios/pf-1/wallets/w-1", _raw, _headers}, 5_000
      refute_received {:request, "POST", _path, _raw, _headers}
    end

    test "the comparison ignores case and the matching write goes out" do
      me = self()
      ok = %{"transaction_id" => "txn-9"}
      real = [plug: capturing(ok, me, "eth"), retry_attempts: 0]

      assert {:ok, _body} =
               Prime.stake_wallet(@credentials, "pf-1", "w-1", "ETH", Decimal.new("1"), real)

      assert_receive {:request, "GET", "/v1/portfolios/pf-1/wallets/w-1", _raw, _headers}, 5_000

      assert_receive {:request, "POST", "/v1/portfolios/pf-1/wallets/w-1/staking/initiate", _r,
                      _h},
                     5_000
    end

    test "a wallet whose symbol cannot be read is not staked: the asset is unverified" do
      me = self()

      for body <- [%{}, %{"wallet" => %{}}, %{"wallet" => %{"symbol" => ""}}] do
        plug = fn conn ->
          {:ok, _raw, conn} = Plug.Conn.read_body(conn)
          send(me, {:method, conn.method})

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(body))
        end

        assert {:error, {:wallet_asset_unverified, :unexpected_response_shape}} =
                 Prime.stake_wallet(@credentials, "pf-1", "w-1", "ETH", Decimal.new("1"),
                   plug: plug,
                   retry_attempts: 0
                 )
      end

      assert_receive {:method, "GET"}, 5_000
      refute_received {:method, "POST"}
    end

    test "a failed wallet read is returned as it came and nothing is written" do
      me = self()

      denied = fn conn ->
        send(me, {:method, conn.method})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"message" => "no such wallet"}))
      end

      assert {:refused, _message} =
               Prime.stake_wallet(@credentials, "pf-1", "w-1", "ETH", Decimal.new("1"),
                 plug: denied,
                 retry_attempts: 0
               )

      down = fn conn ->
        send(me, {:method, conn.method})
        Plug.Conn.resp(conn, 503, "down")
      end

      assert {:error, {:exchange_error, :coinbase, _text}} =
               Prime.unstake_wallet(@credentials, "pf-1", "w-1", "ETH", Decimal.new("1"),
                 plug: down,
                 retry_attempts: 0
               )

      assert_receive {:method, "GET"}, 5_000
      refute_received {:method, "POST"}
    end
  end

  describe "the facade returns a StakingTransaction" do
    defp facade_opts(me, extra) do
      ok = %{"transaction_id" => "txn-42", "activity_id" => "act-42"}

      Keyword.merge(
        [
          credentials: @credentials,
          portfolio_id: "pf-1",
          plug: capturing(ok, me),
          retry_attempts: 0
        ],
        extra
      )
    end

    test "stake/3 builds the struct from the transaction id, in both scopes" do
      me = self()
      one = Decimal.new("1.5")

      for scope <- [[], [wallet_id: "w-1"]] do
        assert {:ok, %Types.StakingTransaction{} = tx} =
                 DpExchange.Coinbase.stake("eth", one, facade_opts(me, scope))

        assert tx.id == "txn-42"
        assert tx.type == :stake
        assert tx.asset == "ETH"
        assert Decimal.equal?(tx.amount, one)
        assert tx.amount_remaining == nil
        assert tx.provider == :coinbase
      end
    end

    test "unstake/3 reports the whole amount as still remaining" do
      me = self()

      assert {:ok, %Types.StakingTransaction{} = tx} =
               DpExchange.Coinbase.unstake("ETH", Decimal.new("8"), facade_opts(me, []))

      assert tx.type == :unstake
      assert Decimal.equal?(tx.amount_remaining, Decimal.new("8"))
      assert Types.StakingTransaction.settled?(tx) == false
    end

    test "a 2xx without a transaction id is unconfirmed and carries the key that was sent" do
      me = self()
      no_id = capturing(%{"ok" => true}, me)

      assert {:error, {:write_unconfirmed, key, :missing_transaction_id}} =
               DpExchange.Coinbase.stake(
                 "ETH",
                 Decimal.new("1"),
                 facade_opts(me, plug: no_id)
               )

      assert_receive {:request, "POST", _path, raw, _headers}, 5_000
      assert Jason.decode!(raw)["idempotency_key"] == key

      # The caller's own key is the one carried back.
      mine = "6f1d2a40-0000-4000-8000-0000000000aa"

      assert {:error, {:write_unconfirmed, ^mine, :missing_transaction_id}} =
               DpExchange.Coinbase.unstake(
                 "ETH",
                 Decimal.new("1"),
                 facade_opts(me, plug: no_id, idempotency_key: mine)
               )

      for blank <- ["", "   ", 7, nil] do
        assert {:error, {:write_unconfirmed, _key, :missing_transaction_id}} =
                 DpExchange.Coinbase.stake(
                   "ETH",
                   Decimal.new("1"),
                   facade_opts(me, plug: capturing(%{"transaction_id" => blank}, me))
                 )
      end
    end

    test "validation and a missing portfolio stay plain errors" do
      me = self()

      assert {:error, :missing_portfolio} =
               DpExchange.Coinbase.stake("ETH", Decimal.new("1"), credentials: @credentials)

      assert {:error, {:invalid_amount, 1.5}} =
               DpExchange.Coinbase.stake("ETH", 1.5, facade_opts(me, []))

      assert {:error, :missing_prime_credentials} =
               DpExchange.Coinbase.stake(
                 "ETH",
                 Decimal.new("1"),
                 facade_opts(me, credentials: %{})
               )

      refute_received {:request, _method, _path, _raw, _headers}
    end
  end

  describe "an unconfirmed staking write (W1) carries the idempotency key" do
    defmodule Throttling do
      @moduledoc false
      @behaviour DpExchange.Core.RateLimitBehaviour

      @impl true
      def acquire(_provider, _weight, _opts), do: {:error, :rate_limit_timeout}
      @impl true
      def check(_provider, _weight, _opts), do: {:rate_limited, 2_000}
      @impl true
      def record(_provider, _weight, _opts), do: :ok
    end

    defmodule RefuseAfterFirst do
      @moduledoc false
      @behaviour DpExchange.Core.RateLimitBehaviour

      @impl true
      def acquire(_provider, _weight, _opts) do
        if Process.get(:prime_first_acquire_done, false) do
          {:error, :rate_limit_timeout}
        else
          Process.put(:prime_first_acquire_done, true)
          :ok
        end
      end

      @impl true
      def check(_provider, _weight, _opts), do: {:rate_limited, 2_000}
      @impl true
      def record(_provider, _weight, _opts), do: :ok
    end

    @key "6f1d2a40-0000-4000-8000-0000000000bb"

    defp status_plug(status, me) do
      fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(raw)["idempotency_key"]})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(status, Jason.encode!(%{"message" => "x"}))
      end
    end

    test "a 5xx after the send is unconfirmed, with the key that was sent" do
      me = self()
      one = Decimal.new("1")

      assert {:error, {:write_unconfirmed, key, {:exchange_error, :coinbase, text}}} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", one,
                 plug: status_plug(500, me),
                 retry_attempts: 0
               )

      assert text =~ "500"
      assert_receive {:sent, ^key}, 5_000
      assert key =~ ~r/\A[0-9a-f-]{36}\z/

      assert {:error, {:write_unconfirmed, @key, _reason}} =
               Prime.claim_rewards(@credentials, "pf-1", "w-1",
                 plug: status_plug(502, me),
                 retry_attempts: 0,
                 idempotency_key: @key
               )
    end

    test "a 2xx that is not an object is unconfirmed on every keyed write" do
      list = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(["no"]))
      end

      real = [plug: list, retry_attempts: 0, idempotency_key: @key]
      one = Decimal.new("1")

      assert {:error, {:write_unconfirmed, @key, :unexpected_response_shape}} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", one, real)

      assert {:error, {:write_unconfirmed, @key, :unexpected_response_shape}} =
               Prime.unstake_portfolio(@credentials, "pf-1", "ETH", one, real)

      assert {:error, {:write_unconfirmed, @key, :unexpected_response_shape}} =
               Prime.claim_rewards(@credentials, "pf-1", "w-1", real)
    end

    test "a 4xx on the first attempt is a refusal, on a retry it is unconfirmed" do
      me = self()
      one = Decimal.new("1")

      assert {:refused, message} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", one,
                 plug: status_plug(403, me),
                 retry_attempts: 0
               )

      assert message =~ "403"

      # 503 then 403: the 403 answers an internal RETRY of a keyed write, so the earlier
      # attempt may have been accepted and the 403 may be the venue objecting to the repeat.
      counter = :counters.new(1, [])

      flaky = fn conn ->
        {:ok, _raw, conn} = Plug.Conn.read_body(conn)
        :counters.add(counter, 1, 1)
        status = if :counters.get(counter, 1) == 1, do: 503, else: 403

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(status, Jason.encode!(%{"message" => "x"}))
      end

      assert {:error, {:write_unconfirmed, @key, reason}} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", one,
                 plug: flaky,
                 retry_attempts: 2,
                 retry_delay: 1,
                 idempotency_key: @key
               )

      assert :counters.get(counter, 1) == 2
      assert is_binary(reason)
      assert reason =~ "403"
    end

    test "DV6: a 409 or 422 on the first attempt is a refusal, a 429 is a plain error" do
      me = self()
      one = Decimal.new("1")

      for status <- [409, 422] do
        assert {:refused, message} =
                 Prime.stake_portfolio(@credentials, "pf-1", "ETH", one,
                   plug: status_plug(status, me),
                   retry_attempts: 1,
                   idempotency_key: @key
                 )

        assert message =~ Integer.to_string(status)
      end

      assert {:error, {:exchange_error, :coinbase, "Rate limited by the venue" <> _rest}} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", one,
                 plug: status_plug(429, me),
                 retry_attempts: 1,
                 idempotency_key: @key
               )
    end

    test "a 429 answered to a retry is unconfirmed, not plain" do
      counter = :counters.new(1, [])

      flaky = fn conn ->
        {:ok, _raw, conn} = Plug.Conn.read_body(conn)
        :counters.add(counter, 1, 1)
        status = if :counters.get(counter, 1) == 1, do: 503, else: 429

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(status, Jason.encode!(%{"message" => "x"}))
      end

      assert {:error, {:write_unconfirmed, @key, _reason}} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", Decimal.new("1"),
                 plug: flaky,
                 retry_attempts: 2,
                 retry_delay: 1,
                 idempotency_key: @key
               )

      assert :counters.get(counter, 1) == 2
    end

    test "our own limiter refusing the first attempt is decided before sending: plain" do
      Config.put_override(:rate_limit_module, Throttling)
      me = self()

      assert {:error, {:exchange_error, :coinbase, "Throttled by our own rate limiter" <> _r}} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", Decimal.new("1"),
                 plug: status_plug(500, me),
                 retry_attempts: 2,
                 retry_delay: 1
               )

      refute_received {:sent, _key}
    end

    test "the limiter refusing a retry after a sent 5xx is unconfirmed, not plain" do
      Config.put_override(:rate_limit_module, RefuseAfterFirst)
      me = self()

      assert {:error, {:write_unconfirmed, @key, {:exchange_error, :coinbase, text}}} =
               Prime.unstake_portfolio(@credentials, "pf-1", "ETH", Decimal.new("1"),
                 plug: status_plug(503, me),
                 retry_attempts: 3,
                 retry_delay: 1,
                 idempotency_key: @key
               )

      assert text =~ "Throttled by our own rate limiter"
      assert_receive {:sent, @key}, 5_000
      refute_received {:sent, _key}
    end

    test "a signing failure and a body that cannot be encoded are plain, nothing was sent" do
      one = Decimal.new("1")

      assert {:error, :missing_prime_credentials} =
               Prime.stake_portfolio(%{access_key: "k"}, "pf-1", "ETH", one, retry_attempts: 0)

      assert {:error, :unencodable_body} =
               Prime.stake_portfolio(@credentials, "pf-1", "ETH", one,
                 extra: %{"x" => {:not, :json}},
                 retry_attempts: 0
               )
    end
  end
end

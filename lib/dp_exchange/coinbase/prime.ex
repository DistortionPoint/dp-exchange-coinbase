defmodule DpExchange.Coinbase.Prime do
  @moduledoc """
  Coinbase **Prime** custodial staking — a different product, a different host, and a
  different signing scheme from Advanced Trade.

  ## Why this is its own module

  Everything else in this package talks to `api.coinbase.com/api/v3/brokerage` and signs
  with a CDP JWT. Prime talks to `api.prime.coinbase.com/v1` and signs with an HMAC over
  the request, using an access key, a passphrase and a signing key that Advanced Trade
  neither issues nor accepts. Putting the two behind one credential map would produce a
  request that is signed, plausible and rejected — and reported as an authentication
  problem at the venue rather than a wrong product here.

  **These are the endpoints that make Coinbase a custodial staking venue** comparable to
  Gemini. They are *not* the CDP Staking API, whose seven endpoints take a wallet address
  and return **unsigned transactions for the caller to sign and broadcast**. That is a
  different capability, and reaching it through `stake/3` would be this family's recurring
  failure at its most expensive: a caller believing it had staked while holding an unsigned
  transaction nobody sent.

  ## Two scopes, and this package will not pick one for you

  Prime publishes every staking operation twice — once **across a portfolio** and once
  **on one wallet**:

      POST /v1/portfolios/{pid}/staking/initiate                      portfolio
      POST /v1/portfolios/{pid}/staking/unstake                       portfolio
      POST /v1/portfolios/{pid}/staking/transaction-validators/query  portfolio
      POST /v1/portfolios/{pid}/wallets/{wid}/staking/initiate        wallet
      POST /v1/portfolios/{pid}/wallets/{wid}/staking/unstake         wallet
      POST /v1/portfolios/{pid}/wallets/{wid}/staking/unstake/preview wallet
      GET  /v1/portfolios/{pid}/wallets/{wid}/staking/unstake/status  wallet
      POST /v1/portfolios/{pid}/wallets/{wid}/staking/claim_rewards   wallet
      GET  /v1/portfolios/{pid}/wallets/{wid}/staking/status          wallet

  The two are not interchangeable: a portfolio-scoped unstake redeems across every wallet
  in the portfolio, and a wallet-scoped one redeems from the one named. Each is a separate
  function here, and `DpExchange.Coinbase.stake/3` chooses between them **only** on what
  the caller actually said — a `:wallet_id` in `opts` means the wallet, its absence means
  the portfolio. Nothing is defaulted.

  ## What was measured, and what was not

  **Nothing here has been run against Prime.** The paths are read from the vendor's own
  pages on 2026-08-31, deduplicated from thirteen pages to nine endpoints — four pairs
  document one path under two names. The signing scheme is read from Prime's authentication
  documentation and has never been probed: this repository holds no Prime credential and
  D7 tier 4 says money-moving endpoints are answered in production by a consumer, not by a
  test here.

  Responses come back as the venue's own maps for the same reason. A `Types.StakingBalance`
  built from an unverified field name would be a plausible number in the wrong field, which
  is worse than a map a caller has to read.
  """

  alias DpExchange.Coinbase.IdempotencyKey
  alias DpExchange.Core.{Config, HttpClient}

  @base_url "https://api.prime.coinbase.com"
  @api_path "/v1"

  @typedoc """
  Prime's own credential triple. **Not the CDP key pair** the rest of this package uses —
  they are issued separately and neither product accepts the other's.
  """
  @type credentials :: %{
          required(:access_key) => String.t(),
          required(:passphrase) => String.t(),
          required(:signing_key) => String.t()
        }

  @doc """
  Stakes `amount` of `asset` **across a portfolio** — `POST /portfolios/{pid}/staking/initiate`.

  This acts on every eligible wallet in the portfolio. `stake_wallet/6` names one instead,
  and the two are not the same operation.

  **This moves funds.** `opts[:idempotency_key]` is passed through where the caller supplies
  one; this package does not generate it, because an idempotency key a caller cannot
  reproduce protects nothing on a retry it did not make.
  """
  @spec stake_portfolio(credentials(), String.t(), String.t(), Decimal.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def stake_portfolio(credentials, portfolio_id, asset, amount, opts) do
    post(
      "/portfolios/#{portfolio_id}/staking/initiate",
      portfolio_stake_body(asset, amount, opts),
      credentials: credentials,
      opts: opts
    )
  end

  @doc """
  Redeems `amount` of a staked `asset` **across a portfolio** —
  `POST /portfolios/{pid}/staking/unstake`.

  **Returns before the redemption completes.** The asset unbonds on the chain's schedule;
  `unstake_status/4` is what reports progress, and a caller treating this return value as
  settled will spend an asset it does not have yet.
  """
  @spec unstake_portfolio(credentials(), String.t(), String.t(), Decimal.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def unstake_portfolio(credentials, portfolio_id, asset, amount, opts) do
    post(
      "/portfolios/#{portfolio_id}/staking/unstake",
      portfolio_stake_body(asset, amount, opts),
      credentials: credentials,
      opts: opts
    )
  end

  @doc """
  The validators a staking transaction would touch —
  `POST /portfolios/{pid}/staking/transaction-validators/query`.

  A read, despite the POST: Prime takes the query in a body. `opts[:transaction_ids]` is
  **required** — `ListTransactionValidatorsRequest.transaction_ids` is a required field
  (docs/reference/coinbase/openapi/prime-spec.yaml:7350) with no documented "every
  transaction" meaning for its absence, so a caller who omits it is refused locally rather
  than sent to the venue with a body that invents an empty list on its behalf.
  `opts[:extra]` carries the venue's other documented fields (`cursor`, `limit`,
  `sort_direction`) as given, because reshaping them would be a second place to be wrong
  about a vocabulary only Prime defines.
  """
  @spec query_transaction_validators(credentials(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def query_transaction_validators(credentials, portfolio_id, opts) do
    case Config.opt(opts, :transaction_ids, nil) do
      ids when is_list(ids) and ids != [] ->
        body = Map.merge(%{"transaction_ids" => ids}, Config.opt(opts, :extra, %{}))

        post(
          "/portfolios/#{portfolio_id}/staking/transaction-validators/query",
          body,
          credentials: credentials,
          opts: opts
        )

      _missing_or_empty ->
        {:error, :missing_transaction_ids}
    end
  end

  @doc """
  Stakes `amount` of `asset` **on one wallet** —
  `POST /portfolios/{pid}/wallets/{wid}/staking/initiate`.

  `asset` is not sent — `StakingInitiateRequest` at this path carries no currency field
  (docs/reference/coinbase/openapi/prime-spec.yaml:8850-8869); the wallet already names a
  single asset on the venue's side. It stays a parameter here because a caller choosing
  between `stake_wallet/6` and `stake_portfolio/5` needs to say which asset it means, the
  same way `unstake_wallet/6` and `preview_unstake_wallet/6` do.
  """
  @spec stake_wallet(credentials(), String.t(), String.t(), String.t(), Decimal.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def stake_wallet(credentials, portfolio_id, wallet_id, _asset, amount, opts) do
    post(
      "/portfolios/#{portfolio_id}/wallets/#{wallet_id}/staking/initiate",
      wallet_stake_body(amount, opts),
      credentials: credentials,
      opts: opts
    )
  end

  @doc """
  Redeems `amount` of a staked `asset` **from one wallet** —
  `POST /portfolios/{pid}/wallets/{wid}/staking/unstake`.

  `preview_unstake_wallet/6` answers what this would do without doing it. `asset` is not
  sent, for the same reason it is not sent by `stake_wallet/6` — see that function's doc.
  """
  @spec unstake_wallet(
          credentials(),
          String.t(),
          String.t(),
          String.t(),
          Decimal.t(),
          keyword()
        ) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def unstake_wallet(credentials, portfolio_id, wallet_id, _asset, amount, opts) do
    post(
      "/portfolios/#{portfolio_id}/wallets/#{wallet_id}/staking/unstake",
      wallet_stake_body(amount, opts),
      credentials: credentials,
      opts: opts
    )
  end

  @doc """
  What a wallet-scoped redemption would do, without doing it —
  `POST /portfolios/{pid}/wallets/{wid}/staking/unstake/preview`.

  **A preview is not a reservation.** Nothing is held, and the unbonding schedule it
  reports is the schedule as of the moment it was asked. It is the only endpoint in this
  module that moves nothing.

  `PreviewUnstakeRequest`'s body is `{amount}` alone — no `currency`, no
  `idempotency_key` (docs/reference/coinbase/openapi/prime-spec.yaml:9083-9090). This used
  to send the same body as a real unstake, including a generated idempotency key, on the
  reasoning that a key on a call that changes nothing was harmless. It was also undocumented:
  the venue defines no field here for it to occupy, so sending one was a guess at a schema
  this package does not own, exactly what `query_transaction_validators/3`'s comment above
  warns against. `asset` is unused for the same reason `stake_wallet/6` does not send it.
  """
  @spec preview_unstake_wallet(
          credentials(),
          String.t(),
          String.t(),
          String.t(),
          Decimal.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def preview_unstake_wallet(credentials, portfolio_id, wallet_id, _asset, amount, opts) do
    post(
      "/portfolios/#{portfolio_id}/wallets/#{wallet_id}/staking/unstake/preview",
      %{"amount" => Decimal.to_string(amount, :normal)},
      credentials: credentials,
      opts: opts
    )
  end

  @doc """
  How far a wallet's redemption has got —
  `GET /portfolios/{pid}/wallets/{wid}/staking/unstake/status`.

  **This is the endpoint that says a redemption is not finished.** Unstaking is a process,
  not an event: the asset unbonds over days and arrives in parts. A consumer that never
  reads this will report a redemption as complete the moment it was accepted.
  """
  @spec unstake_status(credentials(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def unstake_status(credentials, portfolio_id, wallet_id, opts) do
    get("/portfolios/#{portfolio_id}/wallets/#{wallet_id}/staking/unstake/status",
      credentials: credentials,
      opts: opts
    )
  end

  @doc """
  Claims accrued rewards for one wallet —
  `POST /portfolios/{pid}/wallets/{wid}/staking/claim_rewards`.

  **A write, not a report.** It does not say what has accrued; it moves what has. A caller
  wanting the figure reads `staking_status/4`.

  `StakingClaimRewardsRequest` requires `idempotency_key` and takes an optional
  `inputs.amount` — omitted, the wallet claims the maximum available
  (docs/reference/coinbase/openapi/prime-spec.yaml:8744-8770, :15784-15787). This module
  generates the key when the caller gives none, the same as the staking calls above, and
  reads `opts[:amount]` into `inputs.amount` when given. A caller who wants to shape the
  body itself still can, through `opts[:body]` — that override is honoured, but the
  required key is always merged in rather than let it be missing, and a key the caller's
  own body already carries is kept over a freshly generated one.

  ## Retried like the other staking writes, not sent once

  This used to send one attempt only, on the reasoning that its body was opaque — whatever
  `opts[:body]` held — and that injecting an `idempotency_key` into a caller's own map would
  be a guess at a schema this package did not own. The schema is no longer unknown: it
  requires exactly the key this module already generates for `stake_wallet/6` and the rest.
  With that key present, `Core.HttpClient`'s default of three attempts is safe the same way
  it is for a stake or an unstake — the venue returns the original response for a retried
  key rather than claiming a second time — so the `retry_attempts: 1` override is gone.
  """
  @spec claim_rewards(credentials(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def claim_rewards(credentials, portfolio_id, wallet_id, opts) do
    post(
      "/portfolios/#{portfolio_id}/wallets/#{wallet_id}/staking/claim_rewards",
      claim_rewards_body(opts),
      credentials: credentials,
      opts: opts
    )
  end

  @doc """
  One wallet's staking state — `GET /portfolios/{pid}/wallets/{wid}/staking/status`.

  **Not `get_staking_balances/1`.** That callback answers "every staked position, one per
  asset"; this names one wallet and reports that wallet's state. Returning it there would
  answer a narrower question while looking like the wider one, which is why the callback
  stays declared absent on this venue.
  """
  @spec staking_status(credentials(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def staking_status(credentials, portfolio_id, wallet_id, opts) do
    get("/portfolios/#{portfolio_id}/wallets/#{wallet_id}/staking/status",
      credentials: credentials,
      opts: opts
    )
  end

  # --- internals ----------------------------------------------------------

  # Full notation, never scientific: `Decimal.to_string/1` renders a small quantity as
  # 1E-8, which is not a number this venue reads.
  # **An idempotency key is ALWAYS sent, generated when the caller gives none.**
  #
  # It used to be `put_present("idempotency_key", opts[:idempotency_key])` — present only if
  # the caller thought to pass one — while `request_opts/1` forwards `:retry_attempts`
  # unchanged, so the default of 3 applied. A staking write that timed out on its first
  # attempt was therefore re-sent up to twice more with **nothing the venue could tell the
  # second attempt from the first by**, and staking the same amount twice is not a retry, it
  # is a second position.
  #
  # `Rest.place_order/3` already resolved the identical question the identical way — "re-
  # sending one returns the original order instead of placing a second" — and
  # `dp_exchange_gemini`'s `withdraw/6` does the same with `clientTransferId`, with a test
  # pinning that it is sent even when the caller gives none. This is the sibling those two
  # left open, on a money-moving path.
  #
  # Generating rather than refusing to retry is the better of the two remedies and is the one
  # the venue's own API supports: this field was already being sent when a caller supplied
  # it, so it is the venue's mechanism, not an invention here. `claim_rewards/4` now generates
  # one the identical way — see `claim_rewards_body/1` — now that its schema is known too.
  #
  # This used to be one `stake_body/3` shared by every staking call, portfolio- and
  # wallet-scoped alike, sending a flat `{currency, amount, idempotency_key}`. Neither scope's
  # real schema matches that shape: `StakingInitiateRequest` (portfolio) wants
  # `currency_symbol`, not `currency`, and `StakingInitiateRequest` (wallet) wants the amount
  # nested at `inputs.amount`, with no currency field at all — the wallet already names a
  # single asset on the venue's side. Sending the wrong flat body did not fail; it landed on a
  # field the venue does not read for that path and, for the wallet scope, omitted `inputs`
  # entirely, which the docs say defaults to staking the *maximum amount available*
  # (docs/reference/coinbase/openapi/prime-spec.yaml:15862, :15909) — the caller's amount was
  # silently discarded. Split into `portfolio_stake_body/3` and `wallet_stake_body/2` below so
  # each scope's body only ever mirrors that scope's own schema.
  defp portfolio_stake_body(asset, amount, opts) do
    %{
      "idempotency_key" => Keyword.get(opts, :idempotency_key) || IdempotencyKey.generate(),
      "currency_symbol" => String.upcase(asset),
      "amount" => Decimal.to_string(amount, :normal)
    }
    |> Map.merge(Config.opt(opts, :extra, %{}))
  end

  # `WalletStakeInputs`/`WalletUnstakeInputs` carry `amount` (plus asset-specific fields like
  # `validator_address`/`end_date`) nested under `inputs`, not at the top level
  # (docs/reference/coinbase/openapi/prime-spec.yaml:15857-15873, :15904-15920). `opts[:extra]`
  # merges into `inputs`, because every field that schema documents lives there — a caller
  # supplying `validator_address` means "an input to this stake", not "a new top-level field
  # StakingInitiateRequest never declared". `opts[:metadata]`, if given, is sent as the
  # sibling `metadata` object the schema also allows, since that one is genuinely top-level.
  defp wallet_stake_body(amount, opts) do
    inputs =
      %{"amount" => Decimal.to_string(amount, :normal)}
      |> Map.merge(Config.opt(opts, :extra, %{}))

    %{"idempotency_key" => Keyword.get(opts, :idempotency_key) || IdempotencyKey.generate()}
    |> Map.put("inputs", inputs)
    |> put_present("metadata", Config.opt(opts, :metadata, nil))
  end

  # `StakingClaimRewardsRequest` requires `idempotency_key`; `inputs.amount` is optional and,
  # if omitted, the wallet claims the maximum available
  # (docs/reference/coinbase/openapi/prime-spec.yaml:8744-8770, :15784-15787). A caller's own
  # `opts[:body]` is honoured as the base — this module still does not know every field this
  # schema might grow — but the required key is always merged in rather than risk a request
  # the venue refuses outright for missing it, and a key already present in the caller's body
  # is kept rather than overwritten by a freshly generated one.
  defp claim_rewards_body(opts) do
    opts
    |> Config.opt(:body, %{})
    |> Map.put_new(
      "idempotency_key",
      Keyword.get(opts, :idempotency_key) || IdempotencyKey.generate()
    )
    |> put_claim_amount(Config.opt(opts, :amount, nil))
  end

  defp put_claim_amount(body, nil), do: body

  defp put_claim_amount(body, amount) do
    inputs = Map.get(body, "inputs", %{})
    Map.put(body, "inputs", Map.put(inputs, "amount", Decimal.to_string(amount, :normal)))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp post(path, body, credentials: credentials, opts: opts) do
    encoded = Jason.encode!(body)

    headers = signer(:post, path, encoded, credentials)

    :post
    |> HttpClient.request(@base_url <> @api_path <> path, headers, encoded, request_opts(opts))
    |> unwrap()
  end

  defp get(path, credentials: credentials, opts: opts) do
    :get
    |> HttpClient.request(
      @base_url <> @api_path <> path,
      signer(:get, path, "", credentials),
      nil,
      request_opts(opts)
    )
    |> unwrap()
  end

  # Signed per attempt, not once per call: `Core.HttpClient` retries a timeout or a 5xx, and
  # a retry carrying the first attempt's `X-CB-ACCESS-TIMESTAMP` ages with every attempt
  # until the venue refuses it as a credential problem. `Core.HttpClient` calls this again
  # for each attempt. Every write here already survives a retry — the staking writes carry
  # an idempotency key, and `claim_rewards/4` is sent once.
  defp signer(method, path, body, credentials),
    do: fn -> headers(method, path, body, credentials) end

  # Prime signs `timestamp + method + requestPath + body`, HMAC-SHA256 under the signing
  # key, base64-encoded. The path signed is the one after the host and **includes** the
  # `/v1` prefix — signing the suffix alone produces a valid signature over the wrong
  # string, which the venue reports as a credential problem.
  defp headers(method, path, body, credentials) do
    with {:ok, access_key, passphrase, signing_key} <- credential_parts(credentials) do
      timestamp = Integer.to_string(System.os_time(:second))
      verb = method |> to_string() |> String.upcase()
      message = timestamp <> verb <> @api_path <> path <> body

      signature =
        :hmac
        |> :crypto.mac(:sha256, signing_key, message)
        |> Base.encode64()

      {:ok,
       [
         {"X-CB-ACCESS-KEY", access_key},
         {"X-CB-ACCESS-PASSPHRASE", passphrase},
         {"X-CB-ACCESS-SIGNATURE", signature},
         {"X-CB-ACCESS-TIMESTAMP", timestamp},
         {"Content-Type", "application/json"}
       ]}
    end
  end

  # All three or none. A request signed with two of them is signed and wrong, and the venue
  # reports that as an authentication failure rather than as a missing field here.
  defp credential_parts(%{access_key: key, passphrase: phrase, signing_key: signing})
       when is_binary(key) and is_binary(phrase) and is_binary(signing),
       do: {:ok, key, phrase, signing}

  defp credential_parts(_other), do: {:error, :missing_prime_credentials}

  defp request_opts(opts) do
    opts
    |> Keyword.take([
      :timeout,
      :retry_attempts,
      :retry_delay,
      :plug,
      :weight,
      :rate_limit_blocking
    ])
    |> Keyword.put(:provider, :coinbase)
    |> Keyword.put_new(:limiter, Config.opt(opts, :limiter, DpExchange.Coinbase.RateLimiter))
  end

  defp unwrap({:ok, %{status: status, body: body}}) when status in 200..299 and is_map(body),
    do: {:ok, body}

  defp unwrap({:ok, %{status: status}}) when status in 200..299,
    do: {:error, :unexpected_response_shape}

  # There is no clause for a non-2xx `{:ok, response}` here, and that is deliberate:
  # Core's client never returns one. Measured 2026-09-01 — a plug answering 302 comes back
  # as `{:error, {:exchange_error, :coinbase, "Unexpected status (302): …"}}`, and 4xx and
  # 5xx the same way. A clause for a shape that never arrives is a second place to be wrong
  # about the client, and it reads as though it had been tested.

  # Core's client collapses a 4xx into `{:exchange_error, provider, message}`, so the status
  # has to be read back out of the message string. A 400, 401, 403 or 404 is permanent **for
  # the request as sent**: retrying the identical bytes cannot succeed. A caller whose
  # credentials were wrong fixes them and makes a different request, which is not a retry.
  defp unwrap({:error, {:exchange_error, _provider, message} = reason}) when is_binary(message) do
    if refusal?(message), do: {:refused, message}, else: {:error, reason}
  end

  defp unwrap({:error, message}) when is_binary(message) do
    if refusal?(message), do: {:refused, message}, else: {:error, message}
  end

  defp unwrap({:error, reason}), do: {:error, reason}

  # Anchored to the start of the message Core builds (`"Client error (404): …"`). Unanchored,
  # a 5xx or 429 whose quoted body contained `(404)` matched, and a retryable failure came
  # back as a permanent `{:refused, _}`, the false positive `Rest`'s own docs record.
  defp refusal?(message), do: Regex.match?(~r/\AClient error \((?:400|401|403|404)\)/, message)
end

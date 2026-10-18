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

  ## What is refused before anything is signed

  A portfolio or wallet id is a path segment that is signed and sent exactly as given, so it
  has to be a non-empty string of letters, digits, `_` and `-`. `nil`, `""`, a number, or a
  string carrying `/`, `?` or `.` answers `{:error, {:invalid_portfolio_id, value}}` or
  `{:error, {:invalid_wallet_id, value}}` and sends nothing. Before, `nil` became
  `/portfolios//staking/initiate` and `"x/../y"` named a different path from the one the
  function promises.

  An `opts[:idempotency_key]` that is given must be a UUID in the canonical 8-4-4-4-12 hex
  form, as the spec requires (`{:error, {:invalid_idempotency_key, value}}`): the venue
  returns the first response for a repeated key, so `""` made every later stake a copy of
  the first. And `opts[:extra]` fills in
  fields this module does not know; it cannot replace `amount`, `currency_symbol`,
  `idempotency_key` or `transaction_ids`, which are the ones it validated.
  `opts[:metadata]` (the spec's `external_id` object) is sent on all four staking writes,
  portfolio- and wallet-scoped; a value that is not a map is `{:error, {:invalid_metadata, v}}`.

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

  alias DpExchange.Coinbase.{IdempotencyKey, OptionKeys}
  alias DpExchange.Core.{Config, HttpClient, Types}

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

  **This moves funds.** `opts[:idempotency_key]` is sent where the caller supplies one, and
  one is generated otherwise, once per call, so this call's own retries cannot stake twice. A
  caller retrying the call itself must pass its own key, or the venue sees a new request.

  **An unconfirmed write carries that key.** A transport failure or `5xx` after the send, a
  `2xx` whose body is not an object, or a `4xx` answered to one of this call's own internal
  retries is `{:error, {:write_unconfirmed, idempotency_key, reason}}` (`reason` bounded):
  the stake may exist, and the key is what the caller retries or reconciles with. The same
  holds for `unstake_portfolio/5`, `stake_wallet/6`, `unstake_wallet/6` and `claim_rewards/4`.
  A failure decided before anything was sent (validation, credentials, our own rate limiter
  refusing the first attempt, a signing failure) and a `4xx` on the first attempt stay plain
  `{:error, _}` / `{:refused, _}`.
  """
  @spec stake_portfolio(credentials(), String.t(), String.t(), Decimal.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def stake_portfolio(credentials, portfolio_id, asset, amount, opts) do
    with :ok <- valid_portfolio(portfolio_id),
         :ok <- validate_positional(asset, amount),
         :ok <- validate_stake_options(opts),
         :ok <- valid_key(opts),
         :ok <- valid_extra(opts),
         :ok <- valid_metadata(opts) do
      post_write(
        "/portfolios/#{portfolio_id}/staking/initiate",
        portfolio_stake_body(asset, amount, opts),
        credentials,
        opts
      )
    end
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
    with :ok <- valid_portfolio(portfolio_id),
         :ok <- validate_positional(asset, amount),
         :ok <- validate_stake_options(opts),
         :ok <- valid_key(opts),
         :ok <- valid_extra(opts),
         :ok <- valid_metadata(opts) do
      post_write(
        "/portfolios/#{portfolio_id}/staking/unstake",
        portfolio_stake_body(asset, amount, opts),
        credentials,
        opts
      )
    end
  end

  @doc """
  The validators a staking transaction would touch —
  `POST /portfolios/{pid}/staking/transaction-validators/query`.

  A read, despite the POST: Prime takes the query in a body. `opts[:transaction_ids]` is
  **required** — `ListTransactionValidatorsRequest.transaction_ids` is a required field
  (docs/reference/coinbase/openapi/prime-spec.yaml:7350) with no documented "every
  transaction" meaning for its absence, so a caller who omits it is refused locally rather
  than sent to the venue with a body that invents an empty list on its behalf. Every id must
  be a non-empty string and there may be at most 100 (the spec's stated maximum), else
  `{:error, {:invalid_transaction_ids, ids}}` and nothing is signed.
  `opts[:extra]` carries the venue's other documented fields (`cursor`, `limit`,
  `sort_direction`) as given, because reshaping them would be a second place to be wrong
  about a vocabulary only Prime defines.
  """
  @spec query_transaction_validators(credentials(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def query_transaction_validators(credentials, portfolio_id, opts) do
    with :ok <- validate_validators_query(portfolio_id, opts) do
      ids = Config.opt(opts, :transaction_ids, nil)

      post(
        "/portfolios/#{portfolio_id}/staking/transaction-validators/query",
        Map.merge(extra_fields(opts), %{"transaction_ids" => ids}),
        credentials: credentials,
        opts: opts
      )
    end
  end

  @doc """
  The local checks `query_transaction_validators/3` runs before anything is signed, in its
  order: the portfolio id (`{:invalid_portfolio_id, v}`), `opts[:extra]` a map
  (`{:invalid_extra, v}`), `opts[:transaction_ids]` present and non-empty
  (`{:error, :missing_transaction_ids}`) and each id a non-empty string, at most 100
  (`{:invalid_transaction_ids, ids}`); `extra` members `cursor` (string), `limit` (1..1000) and
  `sort_direction` (`"DESC"` / `"ASC"`) are checked when present
  (`{:invalid_extra, key, value}`). Exposed so `DpExchange.Coinbase.Fake` refuses exactly
  as the real path does.
  """
  @spec validate_validators_query(term(), keyword()) :: :ok | {:error, term()}
  def validate_validators_query(portfolio_id, opts) do
    with :ok <- valid_portfolio(portfolio_id),
         :ok <- OptionKeys.check(:query_transaction_validators, opts),
         :ok <- valid_extra(opts),
         :ok <- valid_query_paging(extra_fields(opts)) do
      case Config.opt(opts, :transaction_ids, nil) do
        ids when is_list(ids) and ids != [] -> valid_transaction_ids(ids)
        _missing_or_empty -> {:error, :missing_transaction_ids}
      end
    end
  end

  # The three paging fields the request documents, when `opts[:extra]` carries them:
  # `cursor` a string, `limit` an int32 "Default is 100, maximum is 1000", `sort_direction`
  # `DESC` or `ASC` (prime-spec.yaml, `ListTransactionValidatorsRequest`, `SortDirection`).
  # Any other member of `extra` stays the caller's own, as documented.
  defp valid_query_paging(extra) do
    bad =
      Enum.find(["cursor", "limit", "sort_direction"], fn key ->
        Map.has_key?(extra, key) and not paging_value?(key, Map.fetch!(extra, key))
      end)

    if bad, do: {:error, {:invalid_extra, bad, Map.fetch!(extra, bad)}}, else: :ok
  end

  defp paging_value?("cursor", value), do: is_binary(value)
  defp paging_value?("limit", value), do: is_integer(value) and value >= 1 and value <= 1000
  defp paging_value?("sort_direction", value), do: value in ["DESC", "ASC"]

  # The spec's `transaction_ids` is an array of strings, "maximum of 100 transaction IDs
  # allowed per request" (prime-spec.yaml, `ListTransactionValidators`). A non-string element
  # or a 101st id is a request the venue documents as invalid, so it is refused locally; an
  # improper list is not a list of ids either.
  @max_transaction_ids 100

  defp valid_transaction_ids(ids) do
    if transaction_ids?(ids, 0), do: :ok, else: {:error, {:invalid_transaction_ids, ids}}
  end

  defp transaction_ids?([id | rest], count)
       when is_binary(id) and id != "" and count < @max_transaction_ids,
       do: transaction_ids?(rest, count + 1)

  defp transaction_ids?([], _count), do: true
  defp transaction_ids?(_other, _count), do: false

  @doc """
  Stakes `amount` of `asset` **on one wallet** —
  `POST /portfolios/{pid}/wallets/{wid}/staking/initiate`.

  `asset` is not sent — `StakingInitiateRequest` at this path carries no currency field
  (docs/reference/coinbase/openapi/prime-spec.yaml:8850-8869); the wallet already names a
  single asset on the venue's side.

  **The asset is VERIFIED against the wallet before anything is written.** Because the body
  carries no currency, a caller naming `"ETH"` for a wallet that holds `"SOL"` used to stake
  the SOL, silently. This reads `GET /portfolios/{pid}/wallets/{wid}` (`Wallet.symbol`,
  "the asset stored in the wallet", prime-spec.yaml:15765) first and refuses on mismatch
  (case-insensitively): `{:error, {:wallet_asset_mismatch, asked, held}}`. A wallet whose
  symbol cannot be read is `{:error, {:wallet_asset_unverified, reason}}`: an asset that
  cannot be checked is not staked. The read's own failure is returned as it came
  (`{:refused, _}` for a 4xx, `{:error, _}` otherwise); nothing has been written by then.

  An unconfirmed write is `{:error, {:write_unconfirmed, idempotency_key, reason}}`, as
  `stake_portfolio/5` documents: the key is the one actually sent, generated or the
  caller's, so the caller can reconcile with it.

  **A repeated key FAILS at this path; it does not return the original.** The wallet-scoped
  `StakingInitiateRequest` and `StakingUnstakeRequest` say "Subsequent requests using the same
  key will fail" (prime-spec.yaml, the `idempotency_key` description on
  `/wallets/{wid}/staking/initiate` and `.../unstake`), where the portfolio-scoped ones and
  `claim_rewards/4` say they "will not create new transactions" / "return the original
  response". So a wallet write whose answer was lost and which was re-sent comes back as a
  `4xx` to the retry, which is `write_unconfirmed` here, never a refusal: do not read it as
  "nothing was staked", look the transaction up with `staking_status/4` before trying again.
  `WalletStakeInputs.amount` is documented "ETH only"; for other assets the venue's reading of
  `inputs.amount` is unmeasured.
  """
  @spec stake_wallet(credentials(), String.t(), String.t(), String.t(), Decimal.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def stake_wallet(credentials, portfolio_id, wallet_id, asset, amount, opts) do
    with :ok <- valid_scope(portfolio_id, wallet_id),
         :ok <- validate_positional(asset, amount),
         :ok <- validate_stake_options(opts),
         :ok <- valid_key(opts),
         :ok <- valid_extra(opts),
         :ok <- valid_metadata(opts),
         :ok <- verify_wallet_asset(credentials, portfolio_id, wallet_id, asset, opts) do
      post_write(
        "/portfolios/#{portfolio_id}/wallets/#{wallet_id}/staking/initiate",
        wallet_stake_body(amount, opts),
        credentials,
        opts
      )
    end
  end

  @doc """
  Redeems `amount` of a staked `asset` **from one wallet** —
  `POST /portfolios/{pid}/wallets/{wid}/staking/unstake`.

  `preview_unstake_wallet/6` answers what this would do without doing it. `asset` is not
  sent, for the same reason it is not sent by `stake_wallet/6`, and is verified against the
  wallet the same way before anything is written — see that function's doc.
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
  def unstake_wallet(credentials, portfolio_id, wallet_id, asset, amount, opts) do
    with :ok <- valid_scope(portfolio_id, wallet_id),
         :ok <- validate_positional(asset, amount),
         :ok <- validate_stake_options(opts),
         :ok <- valid_key(opts),
         :ok <- valid_extra(opts),
         :ok <- valid_metadata(opts),
         :ok <- verify_wallet_asset(credentials, portfolio_id, wallet_id, asset, opts) do
      post_write(
        "/portfolios/#{portfolio_id}/wallets/#{wallet_id}/staking/unstake",
        wallet_stake_body(amount, opts),
        credentials,
        opts
      )
    end
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
  warns against. `asset` is unused for the same reason `stake_wallet/6` does not send it, and
  unlike `stake_wallet/6` it is **not** checked against the wallet: a preview moves nothing,
  so the preview answers for the wallet named, whatever it holds.
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
    with :ok <- validate_preview_unstake(portfolio_id, wallet_id, amount, opts) do
      post(
        "/portfolios/#{portfolio_id}/wallets/#{wallet_id}/staking/unstake/preview",
        %{"amount" => Decimal.to_string(amount, :normal)},
        credentials: credentials,
        opts: opts
      )
    end
  end

  @doc """
  The local checks `preview_unstake_wallet/6` runs before anything is signed: both ids
  (`{:invalid_portfolio_id, v}` / `{:invalid_wallet_id, v}`), then the amount
  (`{:invalid_amount, v}`), then the options (`DpExchange.Coinbase.OptionKeys`). The asset is
  not checked, as in the real call. Exposed so `DpExchange.Coinbase.Fake` refuses exactly as
  the real path does.
  """
  @spec validate_preview_unstake(term(), term(), term(), term()) :: :ok | {:error, term()}
  def validate_preview_unstake(portfolio_id, wallet_id, amount, opts) do
    with :ok <- valid_scope(portfolio_id, wallet_id),
         :ok <- valid_amount(amount),
         do: OptionKeys.check(:preview_unstake_wallet, opts)
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
    with :ok <- validate_wallet_read(:unstake_status, portfolio_id, wallet_id, opts) do
      get("/portfolios/#{portfolio_id}/wallets/#{wallet_id}/staking/unstake/status",
        credentials: credentials,
        opts: opts
      )
    end
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
  With that key present, the three attempts this module requests explicitly (Core's own
  non-GET default is one) are safe the same way they are for a stake or an unstake — the venue returns the original response for a retried
  key rather than claiming a second time — so the `retry_attempts: 1` override is gone.
  """
  @spec claim_rewards(credentials(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def claim_rewards(credentials, portfolio_id, wallet_id, opts) do
    with :ok <- validate_claim(portfolio_id, wallet_id, opts) do
      post_write(
        "/portfolios/#{portfolio_id}/wallets/#{wallet_id}/staking/claim_rewards",
        claim_rewards_body(opts),
        credentials,
        opts
      )
    end
  end

  @doc """
  The local checks `claim_rewards/4` runs before anything is signed, in its order: both ids,
  `opts[:amount]` absent or a valid amount (`{:invalid_amount, v}`), `opts[:idempotency_key]`
  absent or a UUID, and `opts[:body]` a map (`{:invalid_body, v}`). Exposed so
  `DpExchange.Coinbase.Fake` refuses exactly as the real path does.
  """
  @spec validate_claim(term(), term(), keyword()) :: :ok | {:error, term()}
  def validate_claim(portfolio_id, wallet_id, opts) do
    with :ok <- valid_scope(portfolio_id, wallet_id),
         :ok <- OptionKeys.check(:claim_rewards, opts),
         :ok <- valid_claim_amount(Config.opt(opts, :amount, nil)),
         :ok <- valid_key(opts) do
      valid_claim_body(Config.opt(opts, :body, %{}))
    end
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
    with :ok <- validate_wallet_read(:staking_status, portfolio_id, wallet_id, opts) do
      get("/portfolios/#{portfolio_id}/wallets/#{wallet_id}/staking/status",
        credentials: credentials,
        opts: opts
      )
    end
  end

  @doc """
  The id check the wallet-scoped reads (`staking_status/4`, `unstake_status/4`) and
  `claim_rewards/4` run first: `portfolio_id` and `wallet_id` both required (a `nil` wallet is
  `{:error, {:invalid_wallet_id, nil}}`, unlike `validate_scope/2`, where it means portfolio
  scope). Exposed so `DpExchange.Coinbase.Fake` refuses exactly as the real path does.
  """
  @spec validate_wallet_scope(term(), term()) ::
          :ok | {:error, {:invalid_portfolio_id | :invalid_wallet_id, term()}}
  def validate_wallet_scope(portfolio_id, wallet_id), do: valid_scope(portfolio_id, wallet_id)

  @doc """
  The id check every staking call runs first: `portfolio_id`, and `wallet_id` when the call is
  wallet-scoped (`nil` means portfolio scope).

  `{:error, {:invalid_portfolio_id, v}}` or `{:error, {:invalid_wallet_id, v}}`. Exposed so
  `DpExchange.Coinbase.Fake` refuses exactly as the real path does.
  """
  @spec validate_scope(term(), term()) ::
          :ok | {:error, {:invalid_portfolio_id | :invalid_wallet_id, term()}}
  def validate_scope(portfolio_id, nil), do: valid_portfolio(portfolio_id)
  def validate_scope(portfolio_id, wallet_id), do: valid_scope(portfolio_id, wallet_id)

  @doc """
  Refuses an option a staking write does not honour (`{:error, {:unknown_option, key}}`) and
  options that are not a keyword list (`{:error, {:invalid_options, v}}`). The transport keys
  always pass; see `DpExchange.Coinbase.OptionKeys`. A misspelt `metdata:` was
  dropped and the stake sent without it. Exposed so `DpExchange.Coinbase.Fake` and the
  facade refuse exactly as the real path does.
  """
  @spec validate_stake_options(term()) ::
          :ok | {:error, {:unknown_option, term()} | {:invalid_options, term()}}
  def validate_stake_options(opts), do: OptionKeys.check(:stake, opts)

  @doc """
  The checks `staking_status/4` and `unstake_status/4` run before anything is signed: the
  ids (`validate_wallet_scope/2`), then the options. `function` names which of the two, for
  `DpExchange.Coinbase.OptionKeys`. Exposed so `DpExchange.Coinbase.Fake` refuses exactly as
  the real path does.
  """
  @spec validate_wallet_read(atom(), term(), term(), term()) :: :ok | {:error, term()}
  def validate_wallet_read(function, portfolio_id, wallet_id, opts) do
    with :ok <- validate_wallet_scope(portfolio_id, wallet_id),
         do: OptionKeys.check(function, opts)
  end

  @doc """
  The field checks a staking write (`stake/3` / `unstake/3`) runs after the scope, in the
  order the real path runs them: the positional arguments (`validate_positional/2`), then
  the options (`validate_stake_options/1`), `opts[:idempotency_key]` absent or a UUID
  (`{:invalid_idempotency_key, v}`), `opts[:extra]` absent or a map
  (`{:invalid_extra, v}`) and `opts[:metadata]` absent or a map (`{:invalid_metadata, v}`).
  Exposed so `DpExchange.Coinbase.Fake` refuses exactly as the real path does.
  """
  @spec validate_write(term(), term(), keyword()) :: :ok | {:error, term()}
  def validate_write(asset, amount, opts) do
    with :ok <- validate_positional(asset, amount),
         :ok <- validate_stake_options(opts),
         :ok <- valid_key(opts),
         :ok <- valid_extra(opts) do
      valid_metadata(opts)
    end
  end

  @doc """
  The positional checks of a staking write, which run before its options: `asset` a
  non-blank string (`{:invalid_asset, v}`), then `amount` a finite, positive `Decimal` within
  64 places (`{:invalid_amount, v}`).
  """
  @spec validate_positional(term(), term()) :: :ok | {:error, term()}
  def validate_positional(asset, amount) do
    with :ok <- valid_asset(asset), do: valid_amount(amount)
  end

  @doc """
  The `Core.Types.StakingTransaction` for an accepted staking write.

  `body` is Prime's answer (`StakingInitiateResponse`, `PortfolioStakingInitiateResponse`
  and their unstake twins all carry `transaction_id`); `key` is the idempotency key that was
  sent. `:amount` is what was requested. For an unstake `:amount_remaining` is that same
  amount: the response reports no progress, so nothing has been reported paid, and
  `unstake_status/4` is what moves it. A stake leaves it `nil` — the type reserves the field
  for a redemption's progress. `:amount_paid_so_far` is `nil` (not reported).

  A `2xx` whose body names no usable `transaction_id` cannot say what was written, so it is
  `{:error, {:write_unconfirmed, key, :missing_transaction_id}}` (W1): the stake may exist,
  and `key` is what the caller retries or reconciles with.
  """
  @spec to_staking_transaction(
          term(),
          :stake | :unstake,
          String.t(),
          Decimal.t(),
          String.t()
        ) ::
          {:ok, Types.StakingTransaction.t()}
          | {:error, {:write_unconfirmed, String.t(), :missing_transaction_id}}
  def to_staking_transaction(%{"transaction_id" => id}, type, asset, amount, key)
      when is_binary(id) and id != "" do
    if String.trim(id) == "",
      do: {:error, {:write_unconfirmed, key, :missing_transaction_id}},
      else: {:ok, staking_transaction(id, type, asset, amount)}
  end

  def to_staking_transaction(_body, _type, _asset, _amount, key),
    do: {:error, {:write_unconfirmed, key, :missing_transaction_id}}

  defp staking_transaction(id, type, asset, amount) do
    Types.StakingTransaction.new(
      id: id,
      type: type,
      venue_type: nil,
      asset: String.upcase(asset),
      amount: amount,
      amount_paid_so_far: nil,
      amount_remaining: if(type == :unstake, do: amount),
      provider: :coinbase
    )
  end

  # --- internals ----------------------------------------------------------

  # **A write that moves funds refuses an amount it cannot send, instead of raising.**
  # `Decimal.to_string/2` on a float or `nil`, or `String.upcase/1` on a `nil` asset, raised
  # inside the caller's process. A zero, negative, NaN or infinite amount is no stake at all,
  # and the venue is not the place to find that out.
  #
  # An exponent beyond 64 places either side of the point is refused as well: `Decimal.to_string(
  # %Decimal{coef: 1, exp: 999_999_999}, :normal)` builds a billion-character string in the
  # caller's process before anything is signed. The bound is the one `Rest` applies to every
  # amount it sends, a judgement and not a venue measurement.
  defp valid_amount(%Decimal{} = amount) do
    if usable?(amount), do: :ok, else: {:error, {:invalid_amount, amount}}
  end

  defp valid_amount(amount), do: {:error, {:invalid_amount, amount}}

  defp usable?(%Decimal{exp: exp}) when exp > 64 or exp < -64, do: false

  defp usable?(%Decimal{} = amount),
    do: not Decimal.inf?(amount) and not Decimal.nan?(amount) and Decimal.positive?(amount)

  # `claim_rewards/4`'s amount is optional (absent claims the maximum), but a PRESENT one is
  # held to the same rule as every other write here. A float or integer used to raise
  # `FunctionClauseError` in `Decimal.to_string/2` inside the caller's process, and a zero or
  # negative `Decimal` was sent to the venue as given.
  defp valid_claim_amount(nil), do: :ok
  defp valid_claim_amount(amount), do: valid_amount(amount)

  # `opts[:extra]` is a map of the venue's own fields. A string or a list of non-pairs raised
  # `Protocol.UndefinedError` from `Map.new/2` inside the caller's process, after the amount
  # had been validated and before anything was sent.
  defp valid_extra(opts) do
    case Config.opt(opts, :extra, %{}) do
      extra when is_map(extra) -> if nameable_keys?(extra), do: :ok, else: invalid_extra(extra)
      other -> invalid_extra(other)
    end
  end

  defp invalid_extra(value), do: {:error, {:invalid_extra, value}}

  # `opts[:metadata]` is the spec's `PortfolioStakingMetadata` / `WalletStakingMetadata`, an
  # object (`external_id`), on the portfolio- and wallet-scoped writes alike. Anything else is
  # refused here rather than sent for the venue to reject (or, as a string, to misread).
  #
  # Both metadata schemas define `external_id` and nothing else (prime-spec.yaml
  # `PortfolioStakingMetadata`: up to 255 characters; `WalletStakingMetadata`: up to 255
  # bytes), so only that member is accepted, as a string within 255 bytes (the stricter of
  # the two). A member the spec does not describe is refused, not sent for the venue to drop.
  defp valid_metadata(opts) do
    case Keyword.get(opts, :metadata) do
      nil -> :ok
      metadata when is_map(metadata) -> documented_metadata(metadata)
      other -> {:error, {:invalid_metadata, other}}
    end
  end

  defp documented_metadata(metadata) do
    valid? =
      Enum.all?(metadata, fn
        {key, value} when key in [:external_id, "external_id"] ->
          is_binary(value) and byte_size(value) <= 255

        _undocumented ->
          false
      end)

    if valid?, do: :ok, else: {:error, {:invalid_metadata, metadata}}
  end

  # `extra_fields/1` and `claim_rewards_body/1` spell every key with `to_string/1`, which
  # raised `Protocol.UndefinedError` in the caller's process for a tuple or map key.
  defp nameable_keys?(map), do: Enum.all?(Map.keys(map), &(is_atom(&1) or is_binary(&1)))

  defp valid_asset(asset) when is_binary(asset) and asset != "", do: :ok
  defp valid_asset(asset), do: {:error, {:invalid_asset, asset}}

  # **A portfolio or wallet id is a path segment, and a path segment is checked.** Both are
  # interpolated into the request path and covered by the signature, so whatever the caller
  # passed was signed and sent. `nil` interpolated to `""` and reached
  # `/portfolios//staking/initiate`; `"pf/../x"` or `"pf?x=1"` named a different path from
  # the one the function's name promises. On the staking writes that is a request this module
  # signed for a resource nobody chose. Prime issues UUIDs, so letters, digits, `_` and `-`
  # are all an id needs; anything else is refused before anything is signed.
  defp valid_portfolio(id), do: valid_id(id, :invalid_portfolio_id)

  defp valid_scope(portfolio_id, wallet_id) do
    with :ok <- valid_portfolio(portfolio_id), do: valid_id(wallet_id, :invalid_wallet_id)
  end

  defp valid_id(id, error) when is_binary(id) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id), do: :ok, else: {:error, {error, id}}
  end

  defp valid_id(id, error), do: {:error, {error, id}}

  # **A caller-supplied idempotency key must be a UUID (and so non-empty).** `"" || generate()` is
  # `""`, so `idempotency_key: ""` was sent, and the venue treats "the same key" as "the same
  # request" and returns the first response (`prime-spec.yaml`: "Subsequent requests using the
  # same key will not create new transactions"). Two different stakes sent with `""` were one
  # stake, and the second came back `{:ok, _}`.
  defp valid_key(opts) do
    case Keyword.get(opts, :idempotency_key) do
      nil -> :ok
      key -> uuid_key(key)
    end
  end

  # The spec calls the key "uuid required" (`prime-spec.yaml` 7248-7290). The canonical
  # 8-4-4-4-12 hex form is checked and anything else refused: a key the venue may reject or
  # read as another one is not worth sending on a call that moves funds. The keys this
  # module generates are `IdempotencyKey.generate/0` v4 UUIDs, which satisfy it.
  defp uuid_key(key) when is_binary(key) do
    if Regex.match?(~r/\A[[:xdigit:]]{8}(-[[:xdigit:]]{4}){3}-[[:xdigit:]]{12}\z/, key),
      do: :ok,
      else: {:error, {:invalid_idempotency_key, key}}
  end

  defp uuid_key(other), do: {:error, {:invalid_idempotency_key, other}}

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
  #
  # **`opts[:extra]` is merged UNDER the fields this module validated, not over them.** It
  # was merged over, so `extra: %{"amount" => "100"}` replaced the amount that `valid_amount/1`
  # had just checked and the caller had just been told was the one sent. `extra` is for the
  # fields the venue documents and this module does not know; the key, the symbol and the
  # amount are not among them. See `extra_fields/1`.
  #
  # `opts[:metadata]` is a top-level member of both portfolio-scoped requests
  # (`PortfolioStakingMetadata`, prime-spec.yaml:7286, :7453; `external_id`). It was dropped
  # here while the wallet body sent it, so the same option did nothing on one scope.
  defp portfolio_stake_body(asset, amount, opts) do
    opts
    |> extra_fields()
    |> Map.merge(%{
      "idempotency_key" => Keyword.get(opts, :idempotency_key) || IdempotencyKey.generate(),
      "currency_symbol" => String.upcase(asset),
      "amount" => Decimal.to_string(amount, :normal)
    })
    |> put_present("metadata", Config.opt(opts, :metadata, nil))
  end

  # `WalletStakeInputs`/`WalletUnstakeInputs` carry `amount` (plus asset-specific fields like
  # `validator_address`/`end_date`) nested under `inputs`, not at the top level
  # (docs/reference/coinbase/openapi/prime-spec.yaml:15857-15873, :15904-15920). `opts[:extra]`
  # merges into `inputs`, because every field that schema documents lives there — a caller
  # supplying `validator_address` means "an input to this stake", not "a new top-level field
  # StakingInitiateRequest never declared". `opts[:metadata]`, if given, is sent as the
  # sibling `metadata` object the schema also allows, since that one is genuinely top-level.
  defp wallet_stake_body(amount, opts) do
    inputs = Map.merge(extra_fields(opts), %{"amount" => Decimal.to_string(amount, :normal)})

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
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put_new(
      "idempotency_key",
      Keyword.get(opts, :idempotency_key) || IdempotencyKey.generate()
    )
    |> put_claim_amount(Config.opt(opts, :amount, nil))
  end

  # The caller's own body must be a map, and a key it carries must be a non-empty string:
  # `Map.put_new/3` kept a `nil` or `""` key (the venue treats the same key as the same
  # request, so every claim after the first would return the first's response), and a
  # non-map raised inside the caller's process. An atom `:idempotency_key` is the same field
  # spelled differently, so it is checked as the string key it becomes.
  defp valid_claim_body(body) when is_map(body) do
    if nameable_keys?(body) do
      with :ok <- valid_claim_key(body), do: valid_claim_inputs(body)
    else
      {:error, {:invalid_body, body}}
    end
  end

  defp valid_claim_body(body), do: {:error, {:invalid_body, body}}

  defp valid_claim_key(body) do
    case Enum.find(body, fn {key, _value} -> to_string(key) == "idempotency_key" end) do
      nil -> :ok
      {_key, value} -> uuid_key(value)
    end
  end

  # `put_claim_amount/2` merges `amount` into the body's `inputs`, and `Map.put/3` on a
  # non-map `inputs` raised `BadMapError` in the caller's process.
  defp valid_claim_inputs(body) do
    case Enum.find(body, fn {key, _value} -> to_string(key) == "inputs" end) do
      nil -> :ok
      {_key, inputs} when is_map(inputs) -> :ok
      {_key, inputs} -> {:error, {:invalid_inputs, inputs}}
    end
  end

  defp put_claim_amount(body, nil), do: body

  defp put_claim_amount(body, amount) do
    inputs = Map.get(body, "inputs", %{})
    Map.put(body, "inputs", Map.put(inputs, "amount", Decimal.to_string(amount, :normal)))
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # `opts[:extra]` with string keys. An atom-keyed entry (`%{amount: "100"}`) beside the
  # string-keyed field this module sets is two JSON members with one name, and the venue
  # decides which of the two it reads. One spelling means a merge can actually replace.
  defp extra_fields(opts) do
    opts |> Config.opt(:extra, %{}) |> Map.new(fn {key, value} -> {to_string(key), value} end)
  end

  # `opts[:extra]`, `opts[:metadata]` and `opts[:body]` are the caller's own terms, and
  # `Jason.encode!/1` raised `Protocol.UndefinedError` (a tuple, a pid) inside the caller's
  # process after every field had been validated. Refused as a value instead, before anything
  # is signed.
  defp post(path, body, credentials: credentials, opts: opts) do
    with {:ok, encoded} <- encode_body(body) do
      headers = signer(:post, path, encoded, credentials)

      :post
      |> HttpClient.request(
        @base_url <> @api_path <> path,
        headers,
        encoded,
        opts |> retried() |> request_opts()
      )
      |> unwrap()
    end
  end

  # Core retries a non-GET once by default. Both POST paths here are safe to repeat, so three
  # attempts are requested explicitly (a caller can still lower it): `post_write/4` carries an
  # `idempotency_key`, which the portfolio-scoped writes and `claim_rewards` answer a repeat of
  # with the original response and the wallet-scoped stake/unstake answer with a failure
  # (prime-spec.yaml says "will fail"); that failure is a 4xx to a retry, which `unwrap_write/3`
  # reports as `write_unconfirmed`, so a repeat can never be read as a refusal. And `post/4`
  # only reads or previews (a validator query, an unstake preview). Every send re-signs.
  defp retried(opts), do: Keyword.update(opts, :retry_attempts, 3, &(&1 || 3))

  # **A staking write, past the point where it may have reached the venue, never answers a
  # bare error** (family convention W1). The body always carries the `idempotency_key` that
  # was sent (the caller's, or the one generated for this call), and it is that key a caller
  # retries with. The outcomes:
  #
  #   * a transport failure, a 5xx or a 2xx whose body is not an object may have staked:
  #     `{:error, {:write_unconfirmed, key, reason}}`;
  #   * a 4xx answered to an internal RETRY (the signer ran more than once) is the same
  #     thing, not a refusal: the earlier attempt may have been accepted, and the 4xx may be
  #     the venue objecting to the repeat;
  #   * a failure decided before anything was sent (our own limiter refusing the first
  #     attempt, signing) and a 4xx on the first attempt stay plain.
  #
  # The signer is counted as `Rest.place_order/3` counts it, because this call retries.
  defp post_write(path, body, credentials, opts) do
    key = Map.get(body, "idempotency_key")
    calls = :atomics.new(1, signed: false)

    with {:ok, encoded} <- encode_body(body) do
      headers = calls |> counting(signer(:post, path, encoded, credentials))

      :post
      |> HttpClient.request(
        @base_url <> @api_path <> path,
        headers,
        encoded,
        opts |> retried() |> request_opts()
      )
      |> unwrap_write(key, {calls, opts})
    end
  end

  defp counting(calls, signer) do
    fn ->
      :atomics.add(calls, 1, 1)
      signer.()
    end
  end

  # A 2xx the venue answered but whose body is no object cannot say what became of the write.
  defp unwrap_write({:ok, %{status: status}} = result, key, _counted)
       when status in 200..299 do
    case unwrap(result) do
      {:ok, _body} = confirmed -> confirmed
      {:error, reason} -> write_unconfirmed(key, reason)
    end
  end

  defp unwrap_write(failure, key, counted) do
    case write_unwrap(failure) do
      {:refused, message} = refused ->
        if attempts_made(counted) > 1, do: write_unconfirmed(key, message), else: refused

      {:error, reason} ->
        cond do
          pre_send_failure?(reason) and sent_attempts(counted) == 0 -> {:error, reason}
          # DV6: a 429 to the FIRST attempt is the venue throttling before it acted.
          too_many_requests?(reason) and attempts_made(counted) <= 1 -> {:error, reason}
          true -> write_unconfirmed(key, reason)
        end
    end
  end

  # DV6 for writes: EVERY 4xx the venue answers to a first attempt (409 and 422 included, not
  # only the 400/401/403/404 a read treats as permanent) is a refusal of that request. A 429
  # never arrives as a "Client error": `Core.HttpClient` answers it as its own tagged message.
  defp write_unwrap({:error, {:exchange_error, _provider, message}} = failure)
       when is_binary(message) do
    if Regex.match?(~r/\AClient error \(4\d\d\)/, message),
      do: {:refused, message},
      else: unwrap(failure)
  end

  defp write_unwrap(failure), do: unwrap(failure)

  defp too_many_requests?({:exchange_error, _venue, "Rate limited by the venue" <> _rest}),
    do: true

  defp too_many_requests?(_reason), do: false

  defp write_unconfirmed(key, reason),
    do: {:error, {:write_unconfirmed, key, bounded_reason(reason)}}

  # `Core.HttpClient` signs once per attempt, just before the limiter is asked (twice per
  # attempt with a blocking limiter), so the count tells how many attempts really left the
  # process. For a pre-send failure the last signature was never sent; a response, even a
  # 4xx, means every signature of its attempt was.
  defp sent_attempts({calls, opts}) do
    signed = :atomics.get(calls, 1)

    if Config.opt(opts, :rate_limit_blocking, false),
      do: div(signed, 2),
      else: max(signed - 1, 0)
  end

  defp attempts_made({calls, opts}) do
    signed = :atomics.get(calls, 1)
    if Config.opt(opts, :rate_limit_blocking, false), do: div(signed, 2), else: signed
  end

  defp pre_send_failure?({:exchange_error, _venue, :rate_limit_timeout}), do: true

  defp pre_send_failure?({:exchange_error, _venue, "Throttled by our own rate limiter" <> _rest}),
    do: true

  defp pre_send_failure?({:exchange_error, _venue, "Rate limiter unavailable"}), do: true
  defp pre_send_failure?({:exchange_error, _venue, _reason}), do: false

  # DELIBERATE DEFENSIVE CLAUSES, unreachable today: `request_opts/1` always sets `provider`,
  # so `Core.HttpClient` tags every message it builds as `{:exchange_error, provider, msg}`
  # and a bare string never arrives. Core builds a bare one only when no provider is given.
  # Kept so that, should that ever change, a bare "Throttled…" is still decided before
  # sending and any other message (a response the venue gave) still falls into the
  # unconfirmed class instead of the catch-all below, which means "raised before the request".
  defp pre_send_failure?("Throttled by our own rate limiter" <> _rest), do: true
  defp pre_send_failure?("Rate limiter unavailable"), do: true
  defp pre_send_failure?(reason) when is_binary(reason), do: false
  # What is left is raised before the request: the header function's signing error.
  defp pre_send_failure?(_local), do: true

  @max_unconfirmed_text 256

  defp bounded_reason(reason) when is_atom(reason), do: reason

  defp bounded_reason(reason) when is_binary(reason),
    do: String.slice(reason, 0, @max_unconfirmed_text)

  defp bounded_reason({:exchange_error, venue, message}) when is_atom(venue),
    do: {:exchange_error, venue, bounded_reason(message)}

  # DELIBERATE CATCH-ALL: whatever else rides in an unconfirmed write's reason — today only
  # `{:response_too_large, limit}` inside an `:exchange_error` (an over-16 MiB reply, which
  # no tier-1 test sends) — is bounded here rather than copied whole into the return value.
  # Without it that reason would raise `FunctionClauseError` on a money-adjacent write.
  defp bounded_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 200)
    |> String.slice(0, @max_unconfirmed_text)
  end

  # The wallet-scoped bodies carry no currency, so the wallet decides what is staked. Reading
  # the wallet first and comparing is the only way to make the caller's `asset` mean what it
  # says. Fails closed: a symbol that cannot be read is a refusal to write, not a guess.
  defp verify_wallet_asset(credentials, portfolio_id, wallet_id, asset, opts) do
    path = "/portfolios/#{portfolio_id}/wallets/#{wallet_id}"

    case get(path, credentials: credentials, opts: opts) do
      {:ok, %{"wallet" => %{"symbol" => held}}} when is_binary(held) and held != "" ->
        if String.upcase(held) == String.upcase(asset),
          do: :ok,
          else: {:error, {:wallet_asset_mismatch, asset, held}}

      {:ok, _unreadable} ->
        {:error, {:wallet_asset_unverified, :unexpected_response_shape}}

      {:refused, _message} = refused ->
        refused

      {:error, _reason} = failure ->
        failure
    end
  end

  defp encode_body(body) do
    {:ok, Jason.encode!(body)}
  rescue
    _error in [Protocol.UndefinedError, Jason.EncodeError] -> {:error, :unencodable_body}
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
  # for each attempt. Every write here already survives a retry — the staking writes and
  # `claim_rewards/4` all carry an idempotency key.
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
    |> Keyword.take(OptionKeys.forwarded())
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

  # DELIBERATE DEFENSIVE CLAUSE, unreachable today: `request_opts/1` always sets `provider`,
  # so Core's client never answers a bare message. Kept so a 4xx still reads as a refusal if
  # that ever changes, rather than as a possibly-transient `{:error, _}`.
  defp unwrap({:error, message}) when is_binary(message) do
    if refusal?(message), do: {:refused, message}, else: {:error, message}
  end

  defp unwrap({:error, reason}), do: {:error, reason}

  # Anchored to the start of the message Core builds (`"Client error (404): …"`). Unanchored,
  # a 5xx or 429 whose quoted body contained `(404)` matched, and a retryable failure came
  # back as a permanent `{:refused, _}`, the false positive `Rest`'s own docs record.
  defp refusal?(message), do: Regex.match?(~r/\AClient error \((?:400|401|403|404)\)/, message)
end

defmodule DpExchange.Coinbase do
  @moduledoc """
  Coinbase, behind the DpExchange facade.

  > #### ⚠️ EXPERIMENTAL {: .warning}
  >
  > This package has not run in production. While it is `0.x` the API may change without
  > a major version — pin all three segments. **Maturity is declared per endpoint**
  > through `capabilities/0`; do not read this banner as your check.

  **This module is the entire public API of this package.** Transport, signing, session
  handling and supervision are internal, and there is nothing here that returns them.

  ## What is specific to Coinbase, and what a caller can therefore rely on

  **Credentials choose the endpoint; they do not gate it — with one exception.** Coinbase
  serves almost all market data publicly and authenticated. Pass credentials and this
  package uses the authenticated path, which has the higher ceiling; pass none and it uses
  the public one. Either way you get the same `Core.Types.*` back, and `capabilities/0`
  tells you what the difference bought. **`get_top_of_book/2` is the one exception**: the
  venue publishes no public form of `/best_bid_ask` — confirmed live, `401` authenticated
  and `404` at the `/market/...` path a caller would expect — so this one call is
  `{:refused, :missing_credentials}` without them rather than a nearer substitute.

  **Nine candle widths, and `12h` is not one of them.** The shared vocabulary models it;
  Coinbase does not serve it. Asking for a width Coinbase does not serve is an **error**,
  never the nearest one — a caller handed one-hour bars labelled four-hour has every value
  real and every label wrong, which is how it went unnoticed for weeks.

  **350 candles per request is a hard boundary.** Measured: 350 minutes of one-minute
  candles returns 349; **351 returns zero and an error**, not the first 350. This package
  refuses an over-wide range up front with `{:error, {:range_too_wide, …}}` rather than
  sending it and handing back an empty result, because empty reads as "no data for this
  period".

  **Coinbase publishes no rate-limit headers.** Measured 2026-08-28: no `x-ratelimit-*`,
  no `retry-after`. The ceilings in `capabilities/0` are declared, and
  `measured_against` says exactly where they came from.

  ## Supervision

  Add it to your own tree. Nothing starts on load — a consumer that has not asked for
  Coinbase must not find a socket open.

      children = [{DpExchange.Coinbase, credentials: my_credentials()}]
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Coinbase.{Feed, Prime, Rest, Supervisor}
  alias DpExchange.Core.{Capabilities, Venue}

  # The venue serves none of these. **That is a claim about Coinbase, not about how far
  # this package got** — and the two are worth telling apart, because both answer a caller
  # identically and only the second can ever change.
  #
  # The mislabel goes both ways and both are defects. A venue's own absence filed as a
  # backlog item invents work that cannot be done and quietly implies an endpoint the vendor
  # does not publish; a backlog item filed as the venue's absence hides a capability a
  # consumer could have had. Robinhood shipped four of the first kind and no test failed.
  @venue_does_not_serve [
    # **Prime publishes staking; it does not publish these four.** `stake/3` and
    # `unstake/3` are live against Prime — see `DpExchange.Coinbase.Prime` — and these are
    # the reads that have no endpoint behind them:
    #
    # * no rate schedule is published at all
    # * `staking/status` names **one wallet** and reports that wallet's state, which is not
    #   "every staked position, one per asset". Returning it here would answer a narrower
    #   question while looking like the wider one; it is reachable as
    #   `Prime.staking_status/4`.
    # * `claim_rewards` is a write that moves accrued rewards, not a report of what accrued
    # * there is no staking history endpoint at either scope
    {:get_staking_rates, 1},
    {:get_staking_balances, 1},
    {:get_staking_rewards, 1},
    {:get_staking_history, 1},
    # **Coinbase's convert is the two-step form, not the one-step one.** Advanced Trade
    # publishes `POST /convert/quote`, `POST /convert/trade/{id}` and
    # `GET /convert/trade/{id}` — quote, commit, read — which is `quote_conversion/4` and
    # friends. There is a one-step `POST /conversions`, but it belongs to the **Exchange**
    # API, a different product this package does not reach. So `convert/4` has no endpoint
    # on this package's surface.
    {:convert, 4},
    # Advanced Trade places one order per request: `POST /orders` takes a single order, and
    # `/orders/batch_cancel` is a batch *cancel*, which destroys rather than creates.
    {:place_orders, 3},
    # **Advanced Trade publishes no allowlist, no networks list and no fiat registration.**
    # Addresses are managed in Coinbase's own interface, not through this API, and there is
    # no path that names a network. `add_payment_method/2` is the same: a bank is linked
    # through the consumer product's flow, which needs a person. Without a network there is
    # nothing to give `get_deposit_address/3` or `withdraw/5`, and this is the group where
    # guessing one sends funds to a chain the venue does not credit.
    {:get_deposit_address, 3},
    {:list_approved_addresses, 1},
    {:estimate_withdrawal_fee, 4},
    {:request_approved_address, 4},
    {:remove_approved_address, 3},
    {:list_networks, 2},
    {:add_payment_method, 2},
    {:withdraw, 5},
    # **`/transaction_summary` is a fee-and-volume summary, not a transaction list.** It
    # reports what the account traded in a window and what that cost; it does not enumerate
    # deposits, fees and adjustments. Returning it here would answer a different question
    # while looking like this one.
    {:get_transactions, 2},
    # No fee promotions, no FX publication, no notional valuation and no custody product on
    # this surface — checked against the venue's own reference on 2026-09-01.
    {:list_fee_promos, 1},
    {:get_fx_rate, 3},
    {:get_notional_balances, 3},
    {:list_custody_fees, 2},
    # **A crypto exchange, not a broker.** Advanced Trade lists no options, no watchlists,
    # no issuer data and no screener — checked against the venue's reference, 2026-09-01.
    {:get_option_chain, 2},
    {:get_option_expirations, 2},
    {:get_option_greeks, 2},
    {:list_watchlists, 1},
    {:get_watchlist, 2},
    {:create_watchlist, 3},
    {:update_watchlist, 2},
    {:delete_watchlist, 2},
    {:get_financials, 3},
    {:get_corporate_events, 1},
    {:get_filings, 2},
    {:get_news, 1},
    {:get_screener, 2},
    # **No bulk cancel here — checked against the venue's reference on 2026-09-01.**
    # `POST /orders/batch_cancel` takes an explicit `order_ids` list; it is the endpoint
    # `cancel_order/3` already uses, one id at a time. There is no "cancel everything"
    # call, and building one from `get_orders/2` plus a batch of ids would be N partial
    # outcomes with no way to reach an order that appeared between the listing and the
    # cancel — a bulk cancel that is not one.
    {:cancel_all_orders, 2},
    # **This venue runs no auctions and publishes no footprints.** A crypto book trades
    # continuously — there is no opening or closing auction to have an imbalance in — and
    # the venue publishes no volume-at-price split. Not "unimplemented": there is nothing
    # to implement.
    {:get_auction_imbalance, 2},
    {:get_volume_profile, 3},
    # No transfer ledger on this surface; transfers happen in the consumer product.
    {:get_transfers, 2},
    # The venue meters by header rather than by endpoint: there is no call that reports
    # what a credential has left.
    {:get_rate_limit_status, 2}
  ]

  # Not ported yet. **The venue serves these**; this package does not implement them.
  @not_ported [
    # Perpetual funding and contract statistics live behind the INTX endpoints, which this
    # package does not reach — see `supported_instrument_types`.
    {:get_funding, 2},
    {:get_contract_stats, 2}
  ]

  @unsupported @venue_does_not_serve ++ @not_ported

  # --- lifecycle ---------------------------------------------------------

  @impl true
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @impl true
  def start_link(opts), do: Supervisor.start_link(opts)

  # --- declaration -------------------------------------------------------

  @impl true
  def provider_name, do: "Coinbase"

  @impl true
  def runtime_id, do: :coinbase

  @impl true
  def asset_classes, do: [:crypto]

  @doc """
  Endpoints the **venue** does not serve, as distinct from ones this package has not ported.

  Both answer `{:error, :not_supported}`, and a caller acts the same way on either — but
  they mean different things to anyone deciding what to build next, so they are told apart
  here rather than flattened into one list.

  Every entry is recorded with its source and the date consulted in
  `docs/reference/coinbase/negative-claims.md`.
  """
  @spec venue_does_not_serve() :: [{atom(), arity()}]
  def venue_does_not_serve, do: @venue_does_not_serve

  @impl true
  def capabilities do
    Capabilities.new(
      endpoints: endpoint_maturities(),
      supported_quotes: ~w(USDC USD EUR GBP BTC USDT ETH INR AUD CAD SGD),
      # `:future` joined on 2026-09-01 with the CFM surface — US derivatives are dated
      # futures, margined in a separate account. `:perp` is **not** here: Advanced Trade's
      # perpetuals live behind the INTX endpoints, which are `APPROVED-SKIP` as deprecated,
      # and a declaration for a surface this package does not reach would be a claim about
      # the venue standing in for one about the package.
      supported_instrument_types: [:spot, :future],
      supports_short_selling: false,
      # Both were `false`, on an unchecked claim that the venue publishes neither endpoint.
      # It publishes `/orders/preview` and `/orders/edit`, and the second matters more than
      # a convenience: `supports_order_replace: false` told a caller to cancel and re-place,
      # which opens a window where no order is live. The package was describing a risk it
      # was creating by not implementing the endpoint that avoids it.
      supports_order_preview: true,
      supports_order_replace: true,
      # `level2` was recognised and decoded but never subscribed — `Socket` already had
      # the auth machinery for it, and the only thing standing between that and a real
      # declaration was `Feed` asking for it. Now sharded (100 pairs/socket, the number
      # from the incident that made sharding necessary) and subscribed on every shard.
      streamable: [:quotes, :order_book],
      historical_timeframes: Rest.granularities(),
      max_candles_per_request: Rest.max_candles(),
      reports_trade_volume: true,
      catalog_size: :small,

      # Credentials buy a higher ceiling here, not access: almost all market data is
      # served publicly. The three-way answer is the point — a boolean could only say
      # "required" or "not", and neither is true for the package as a whole. The one
      # exception is `get_top_of_book/2`, which genuinely has no public form — see its
      # own doc and `docs/reference/coinbase/endpoint-inventory.md` — but one endpoint's
      # exception does not make `:required` the honest word for the other forty-five.
      credential_benefit: :higher_ceiling,
      public_ceiling: %{limit: 3, per_ms: 1_000},
      authenticated_ceiling: %{limit: 10, per_ms: 1_000},

      # Rank 3 of D13's hierarchy, and labelled as such. The granularities and page size
      # were measured against the live venue on this date; the CEILINGS were not — they
      # are inherited from the prior adapter's moduledoc, because the vendor's
      # rate-limit page could not be located and probing a limit means deliberately
      # exceeding a third party's. An unlabelled number would be worse than a missing one.
      measured_at: ~D[2026-08-28],
      measured_against:
        "granularities and the 350-candle boundary measured live against " <>
          "api.coinbase.com/api/v3/brokerage; ceilings NOT measured and NOT confirmed " <>
          "against Coinbase documentation — inherited from the prior adapter"
    )
  end

  # Everything implemented is `:experimental` — the honest state for code no one has run
  # in production. The rest are `:unsupported` and return the atom, which the conformance
  # suite checks in both directions.
  defp endpoint_maturities do
    active =
      for {name, arity} <- Venue.behaviour_info(:callbacks),
          {name, arity} not in @unsupported,
          into: %{},
          do: {{name, arity}, :experimental}

    Enum.reduce(@unsupported, active, &Map.put(&2, &1, :unsupported))
  end

  # --- market data -------------------------------------------------------

  @impl true
  def get_price(symbol, opts \\ []), do: Rest.get_price(symbol, opts)

  @impl true
  def get_top_of_book(symbol, opts \\ []), do: Rest.get_top_of_book(symbol, opts)

  @impl true
  def get_historical_prices(symbol, timeframe, range \\ [], opts \\ []),
    do: Rest.get_historical_prices(symbol, timeframe, range, opts)

  @impl true
  def get_symbols(opts \\ []), do: Rest.get_symbols(opts)

  @impl true
  @doc """
  The order book for `symbol`.

  See `DpExchange.Coinbase.Rest.get_order_book/2` — including why the levels are not
  re-sorted here, and why an undated book is refused.
  """
  def get_order_book(symbol, opts \\ []), do: Rest.get_order_book(symbol, opts)

  @doc """
  Recent public trades — the tape.

  See `DpExchange.Coinbase.Rest.get_trades/2`: `get_price/2` reads the same payload and
  keeps only the newest print.
  """
  @impl true
  def get_trades(symbol, opts \\ []), do: Rest.get_trades(symbol, opts)

  @impl true
  def get_market_overview(opts \\ []), do: Rest.get_market_overview(opts)

  @impl true
  def get_auction_imbalance(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_volume_profile(_symbol, _timeframe, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_instruments(opts \\ []), do: Rest.list_instruments(opts)

  # --- account and trading -----------------------------------------------

  @impl true
  @doc """
  Every balance the credential can see, one per account.

  See `DpExchange.Coinbase.Rest.get_balances/2` — in particular why the total is the sum of
  the venue's two numbers and `nil` when either is missing.
  """
  def get_balances(credentials, opts), do: Rest.get_balances(credentials, opts)

  @impl true
  @doc """
  The venue's own account records — uuid, platform, portfolio, tradability.

  Separate from `get_balances/2` because a caller routing an order needs the uuid and a
  caller sizing one needs the balance. `opts[:uuid]` reads a single account.
  """
  def get_accounts(credentials, opts), do: Rest.get_accounts(credentials, opts)

  @doc """
  The fee schedule that applies to this credential.

  See `DpExchange.Coinbase.Rest.get_fees/2`. Both the promotional tier and the tier without
  the promotion travel, because they differ while one is running and it can end between two
  calls.
  """
  @impl true
  def get_fees(credentials, opts), do: Rest.get_fees(credentials, opts)

  @impl true
  def get_transfers(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def place_order(credentials, request, opts \\ []),
    do: Rest.place_order(credentials, request, opts)

  @doc """
  **Not supported.** Advanced Trade places one order per request.

  `POST /orders` takes a single order and `POST /orders/batch_cancel` is a batch *cancel* —
  the venue's only bulk order operation, and it destroys rather than creates. Calling
  `place_order/3` in a loop is what a consumer must do here, with the reconciliation that
  implies.
  """
  @impl true
  def place_orders(_credentials, _requests, _opts), do: Venue.not_supported()

  @doc """
  Previews an order without placing it.

  **This used to read "this venue publishes no order-preview endpoint".** It publishes
  `POST /api/v3/brokerage/orders/preview`, and `supports_order_preview` was declared `false`
  on the strength of that claim. Neither was checked against the venue's reference.
  """
  @impl true
  def preview_order(credentials, request, opts \\ []),
    do: Rest.preview_order(credentials, request, opts)

  @doc """
  Changes the price or size of a working order, in place.

  **This used to read "this venue has no atomic replace; a caller cancels and re-places",
  and called that a claim about risk.** The risk was real and the claim was wrong: Coinbase
  publishes `POST /api/v3/brokerage/orders/edit`, which amends without ever leaving the
  order un-live. The window this package warned a caller about was one it was creating by
  not implementing the endpoint that avoids it.
  """
  @impl true
  def replace_order(credentials, order_id, changes, opts \\ []),
    do: Rest.replace_order(credentials, order_id, changes, opts)

  @doc """
  Prices an amendment to a working order without making it.

  See `DpExchange.Coinbase.Rest.preview_replace/4` — in particular why this is not
  `preview_order/3` with an order id.
  """
  @impl true
  def preview_replace(credentials, order_id, changes, opts \\ []),
    do: Rest.preview_replace(credentials, order_id, changes, opts)

  @doc """
  Flattens an open position by having the venue place the closing order.

  See `DpExchange.Coinbase.Rest.close_position/3`, including why the returned order carries
  no side.
  """
  @impl true
  def close_position(credentials, symbol, opts \\ []),
    do: Rest.close_position(credentials, symbol, opts)

  @impl true
  def cancel_all_orders(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def cancel_order(credentials, order_id, opts \\ []),
    do: Rest.cancel_order(credentials, order_id, opts)

  @impl true
  def get_order(credentials, order_id, opts \\ []),
    do: Rest.get_order(credentials, order_id, opts)

  @impl true
  def get_orders(credentials, opts \\ []), do: Rest.get_orders(credentials, opts)

  @impl true
  @doc """
  Past fills for the credential.

  See `DpExchange.Coinbase.Rest.get_trade_history/2` — in particular why only `FILL` rows
  come back unless `opts[:trade_types]` says otherwise.
  """
  def get_trade_history(credentials, opts), do: Rest.get_trade_history(credentials, opts)

  # --- streaming ---------------------------------------------------------

  @impl true
  def subscribe(symbols, opts \\ []), do: Feed.subscribe(feed(opts), symbols, opts)

  @impl true
  def unsubscribe(symbols, opts \\ []), do: Feed.unsubscribe(feed(opts), symbols)

  @impl true
  def update_symbols(symbols, opts \\ []), do: Feed.update_symbols(feed(opts), symbols)

  # NOT declarable `:unsupported`: `coverage/1` returns a map, so it has no way to
  # answer `{:error, :not_supported}`. It always answers, and an empty map is the honest
  # answer for a venue delivering nothing — which is the same reason a venue that cannot
  # observe delivery reports `:not_covered` rather than claiming success.
  @impl true
  def coverage(opts \\ []) do
    feed = feed(opts)
    if alive?(feed), do: Feed.coverage(feed), else: %{}
  end

  @impl true
  def subscribe_notices(opts \\ []), do: Feed.subscribe_notices(feed(opts), opts)

  # The feed process. Named so a consumer running two of this venue — different
  # credentials, different scopes — keeps them apart; defaulting to the module name
  # covers the single-venue case without ceremony.
  defp feed(opts), do: Keyword.get(opts, :feed, Feed)

  defp alive?(name) when is_atom(name), do: is_pid(GenServer.whereis(name))
  defp alive?(pid) when is_pid(pid), do: Process.alive?(pid)

  # --- health ------------------------------------------------------------

  @doc """
  Whether the venue is reachable and the credential, if given, is accepted.

  See `DpExchange.Coinbase.Rest.test_connection/2`. Without credentials it reads the public
  clock; with them it reads the key's permissions, which is both a reachability check and an
  answer about what the key can do.
  """
  @impl true
  def test_connection(credentials, opts), do: Rest.test_connection(credentials, opts)

  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def market_status(_opts), do: {:ok, :open}

  @impl true
  @doc """
  What the venue will actually accept for `symbol`.

  See `DpExchange.Coinbase.Rest.quantization/2` — in particular why the price and quantity
  increments are different fields.
  """
  def quantization(symbol), do: Rest.quantization(symbol, [])

  # --- Declared but not yet implemented -----------------------------------
  #
  # Core 0.1.16 widened the facade to the surface the venues actually publish. These answer
  # `{:error, :not_supported}` and are declared `:unsupported` in `capabilities/0`, so a
  # consumer routing on the declaration is told the truth.
  #
  # **`:unsupported` here is a statement about this package, not about the venue.** That
  # distinction is the one Phase 1 had to correct after a package spent a year asserting a
  # venue had no streaming API when it had fifteen services. Where the venue genuinely does
  # not offer something, the comment beside it says so.

  @doc """
  Open futures positions in the CFM account.

  See `DpExchange.Coinbase.Rest.get_positions/2`. `:realised_pnl` is `nil` because the venue
  publishes a *daily* figure and this field means the position's; `list_futures_positions/1`
  returns the venue's own rows, where it keeps its own name.
  """
  @impl true
  def get_positions(opts),
    do: Rest.get_positions(Keyword.get(opts, :credentials, %{}), opts)

  @doc """
  The venue's own futures position rows, unnormalised.

  See `DpExchange.Coinbase.Rest.list_futures_positions/2`.
  """
  @spec list_futures_positions(keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_futures_positions(opts),
    do: Rest.list_futures_positions(Keyword.get(opts, :credentials, %{}), opts)

  @doc """
  One futures position by product id — expiry included.

  See `DpExchange.Coinbase.Rest.get_futures_position/3`.
  """
  @spec get_futures_position(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_futures_position(credentials, product_id, opts),
    do: Rest.get_futures_position(credentials, product_id, opts)

  @doc """
  The futures account's balances and margin.

  See `DpExchange.Coinbase.Rest.get_futures_balance_summary/2`. Two accounts are named —
  the spot one held with Coinbase Inc and the futures one held with Coinbase Financial
  Markets — and only the second margins a position.
  """
  @spec get_futures_balance_summary(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_futures_balance_summary(credentials, opts),
    do: Rest.get_futures_balance_summary(credentials, opts)

  @doc """
  Pending and processing sweeps out of the futures account.

  See `DpExchange.Coinbase.Rest.list_futures_sweeps/2`. A listed sweep has not happened yet.
  """
  @spec list_futures_sweeps(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_futures_sweeps(credentials, opts),
    do: Rest.list_futures_sweeps(credentials, opts)

  @doc """
  Schedules a sweep from the futures account to the spot one. **This moves funds.**

  See `DpExchange.Coinbase.Rest.schedule_futures_sweep/2` — omitting the amount sweeps every
  available excess dollar, which is the venue's default and not this package's.
  """
  @spec schedule_futures_sweep(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def schedule_futures_sweep(credentials, opts),
    do: Rest.schedule_futures_sweep(credentials, opts)

  @doc """
  Cancels *the* pending sweep — the venue takes no id.

  See `DpExchange.Coinbase.Rest.cancel_futures_sweep/2`.
  """
  @spec cancel_futures_sweep(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def cancel_futures_sweep(credentials, opts),
    do: Rest.cancel_futures_sweep(credentials, opts)

  @doc """
  The account's intraday margin setting.

  See `DpExchange.Coinbase.Rest.get_intraday_margin_setting/2`. `UNSPECIFIED` is the venue
  declining to say, and is not `STANDARD`.
  """
  @spec get_intraday_margin_setting(map(), keyword()) ::
          {:ok, String.t()} | {:error, term()} | {:refused, term()}
  def get_intraday_margin_setting(credentials, opts),
    do: Rest.get_intraday_margin_setting(credentials, opts)

  @doc """
  Sets the account's intraday margin setting. **This changes how much leverage it gets.**

  See `DpExchange.Coinbase.Rest.set_intraday_margin_setting/3`.
  """
  @spec set_intraday_margin_setting(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def set_intraday_margin_setting(credentials, setting, opts),
    do: Rest.set_intraday_margin_setting(credentials, setting, opts)

  @doc """
  Which margin window the account is in now, and whether the kill switches are on.

  See `DpExchange.Coinbase.Rest.get_current_margin_window/2`.
  """
  @spec get_current_margin_window(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_current_margin_window(credentials, opts),
    do: Rest.get_current_margin_window(credentials, opts)

  @impl true
  def get_funding(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_contract_stats(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_staking_rates(_opts), do: Venue.not_supported()

  @impl true
  def get_staking_balances(_opts), do: Venue.not_supported()

  @impl true
  def get_staking_rewards(_opts), do: Venue.not_supported()

  @impl true
  def get_staking_history(_opts), do: Venue.not_supported()

  @doc """
  Stakes `amount` of `asset` through **Coinbase Prime**. **This moves funds.**

  Prime, not Advanced Trade: a different host, a different signing scheme and a separate
  credential triple. `opts[:credentials]` carries Prime's `%{access_key:, passphrase:,
  signing_key:}`; the CDP key pair the rest of this package uses is not accepted there.

  **`opts[:portfolio_id]` is required and is not defaulted.** Missing it is
  `{:error, :missing_portfolio}` before a request is made — picking the first portfolio
  would stake in one the caller never named.

  **The scope follows what the caller said, and nothing more.** With `opts[:wallet_id]`
  this stakes on that wallet; without, it stakes across the portfolio. The two are
  different operations, so neither is inferred from the other.

  See `DpExchange.Coinbase.Prime` for the endpoints themselves and for what has and has
  not been measured.
  """
  @impl true
  def stake(asset, amount, opts) do
    prime_write(:stake, asset, amount, opts)
  end

  @doc """
  Redeems `amount` of a staked `asset` through **Coinbase Prime**.

  **Returns before the redemption completes.** The asset unbonds on the chain's schedule
  and arrives in parts; `DpExchange.Coinbase.Prime.unstake_status/4` is what reports
  progress. A caller treating this return value as settled will spend an asset it does not
  have yet.

  Scope and credentials work exactly as they do on `stake/3`.
  """
  @impl true
  def unstake(asset, amount, opts) do
    prime_write(:unstake, asset, amount, opts)
  end

  defp prime_write(operation, asset, amount, opts) do
    credentials = Keyword.get(opts, :credentials, %{})

    case {Keyword.get(opts, :portfolio_id), Keyword.get(opts, :wallet_id)} do
      {nil, _wallet} ->
        {:error, :missing_portfolio}

      {portfolio, nil} ->
        prime_portfolio(operation, credentials, portfolio, asset, amount, opts)

      {portfolio, wallet} ->
        prime_wallet(operation, credentials, portfolio, wallet, asset, amount, opts)
    end
  end

  defp prime_portfolio(:stake, credentials, portfolio, asset, amount, opts),
    do: Prime.stake_portfolio(credentials, portfolio, asset, amount, opts)

  defp prime_portfolio(:unstake, credentials, portfolio, asset, amount, opts),
    do: Prime.unstake_portfolio(credentials, portfolio, asset, amount, opts)

  defp prime_wallet(:stake, credentials, portfolio, wallet, asset, amount, opts),
    do: Prime.stake_wallet(credentials, portfolio, wallet, asset, amount, opts)

  defp prime_wallet(:unstake, credentials, portfolio, wallet, asset, amount, opts),
    do: Prime.unstake_wallet(credentials, portfolio, wallet, asset, amount, opts)

  @doc """
  Quotes a conversion. **Nothing moves.**

  See `DpExchange.Coinbase.Rest.quote_conversion/5`. Coinbase names accounts by currency, and
  `expires_at` is `nil` because Advanced Trade states none — which is "not stated", not
  "open-ended".
  """
  @impl true
  def quote_conversion(from, to, amount, opts),
    do: Rest.quote_conversion(Keyword.get(opts, :credentials, %{}), from, to, amount, opts)

  @doc """
  Commits a quoted conversion. **This moves funds.**

  See `DpExchange.Coinbase.Rest.commit_conversion/3`. The venue re-asks for both accounts and
  this package fills neither in — `opts[:from]` and `opts[:to]` are required.
  """
  @impl true
  def commit_conversion(id, opts),
    do: Rest.commit_conversion(Keyword.get(opts, :credentials, %{}), id, opts)

  @doc """
  A conversion's current state.

  See `DpExchange.Coinbase.Rest.get_conversion/3`. Both accounts are required query
  parameters here — the venue's own rule, and unusual for a read.
  """
  @impl true
  def get_conversion(id, opts),
    do: Rest.get_conversion(Keyword.get(opts, :credentials, %{}), id, opts)

  @impl true
  def convert(_from, _to, _amount, _opts), do: Venue.not_supported()

  @doc """
  What this account has traded.

  See `DpExchange.Coinbase.Rest.get_trade_volume/2`. This package claimed until 2026-09-01
  that Advanced Trade does not aggregate it; the transaction summary does, and the claim had
  been made from the *market* volume endpoint's absence, which is a different question.
  """
  @impl true
  def get_trade_volume(credentials, opts), do: Rest.get_trade_volume(credentials, opts)

  @doc """
  The portfolios this credential can address.

  See `DpExchange.Coinbase.Rest.list_portfolios/2`. A portfolio is an address, not a value,
  and deleted ones stay in the listing because old orders still name them.
  """
  @impl true
  def list_portfolios(opts),
    do: Rest.list_portfolios(Keyword.get(opts, :credentials, %{}), opts)

  @doc """
  One portfolio's full breakdown — balances, positions and margin inside it.

  See `DpExchange.Coinbase.Rest.get_portfolio_breakdown/3`. **Not `list_portfolios/1`
  narrowed to one**: the listing names portfolios, this returns what is inside one.
  """
  @spec get_portfolio_breakdown(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_portfolio_breakdown(credentials, portfolio_uuid, opts),
    do: Rest.get_portfolio_breakdown(credentials, portfolio_uuid, opts)

  @doc """
  Deletes a portfolio. **Irreversible from this package's side.**

  See `DpExchange.Coinbase.Rest.delete_portfolio/3` — the venue refuses while the portfolio
  holds funds or open orders, which is the venue's guard and not this one's.
  """
  @spec delete_portfolio(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def delete_portfolio(credentials, portfolio_uuid, opts),
    do: Rest.delete_portfolio(credentials, portfolio_uuid, opts)

  @impl true
  def get_deposit_address(_asset, _network, _opts), do: Venue.not_supported()

  @impl true
  def list_approved_addresses(_opts), do: Venue.not_supported()

  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts), do: Venue.not_supported()

  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts), do: Venue.not_supported()

  @doc """
  The funding sources this account can move fiat through.

  See `DpExchange.Coinbase.Rest.list_payment_methods/2`. `verified`, `allow_deposit` and
  `allow_withdraw` disagree with each other routinely; presence is not usability.
  """
  @impl true
  def list_payment_methods(credentials, opts),
    do: Rest.list_payment_methods(credentials, opts)

  @doc """
  One funding source by id.

  See `DpExchange.Coinbase.Rest.get_payment_method/3`. This is the read;
  `list_payment_methods/2` is a snapshot.
  """
  @impl true
  def get_payment_method(credentials, id, opts),
    do: Rest.get_payment_method(credentials, id, opts)

  @doc """
  Moves funds between two of this account's portfolios.

  See `DpExchange.Coinbase.Rest.transfer_internal/4`. Nothing leaves Coinbase, and both
  portfolio uuids are required — `opts[:from]` and `opts[:to]`, neither defaulted.
  """
  @impl true
  def transfer_internal(asset, amount, opts, request_opts),
    do:
      Rest.transfer_internal(
        Keyword.get(request_opts, :credentials, %{}),
        asset,
        amount,
        Keyword.merge(request_opts, opts)
      )

  @impl true
  def add_payment_method(_details, _opts), do: Venue.not_supported()

  @impl true
  def request_approved_address(_asset, _network, _address, _opts), do: Venue.not_supported()

  @impl true
  def remove_approved_address(_network, _address, _opts), do: Venue.not_supported()

  @impl true
  def list_networks(_asset, _opts), do: Venue.not_supported()

  @impl true
  def get_transactions(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def list_fee_promos(_opts), do: Venue.not_supported()

  @impl true
  def get_fx_rate(_pair, _at, _opts), do: Venue.not_supported()

  @impl true
  def get_notional_balances(_credentials, _currency, _opts), do: Venue.not_supported()

  @impl true
  def list_custody_fees(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def get_option_chain(_underlying, _opts), do: Venue.not_supported()

  @impl true
  def get_option_expirations(_underlying, _opts), do: Venue.not_supported()

  @impl true
  def get_option_greeks(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def list_watchlists(_opts), do: Venue.not_supported()

  @impl true
  def get_watchlist(_id, _opts), do: Venue.not_supported()

  @impl true
  def create_watchlist(_name, _symbols, _opts), do: Venue.not_supported()

  @impl true
  def update_watchlist(_id, _opts), do: Venue.not_supported()

  @impl true
  def delete_watchlist(_id, _opts), do: Venue.not_supported()

  @impl true
  def get_financials(_symbol, _kind, _opts), do: Venue.not_supported()

  @impl true
  def get_corporate_events(_opts), do: Venue.not_supported()

  @impl true
  def get_filings(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_news(_opts), do: Venue.not_supported()

  @impl true
  def get_screener(_name, _opts), do: Venue.not_supported()

  @doc """
  Creates a portfolio, which is what this venue calls a sub-account.

  `opts[:name]` is required. See `DpExchange.Coinbase.Rest.create_portfolio/2`.

  **Advanced Trade has no notion of creating an *account*** — an account is opened by a
  person with Coinbase. A portfolio is the subdivision an API can make, and it is what this
  callback means here.
  """
  @impl true
  def create_account(opts),
    do: Rest.create_portfolio(Keyword.get(opts, :credentials, %{}), opts)

  @doc """
  Renames a portfolio.

  See `DpExchange.Coinbase.Rest.rename_portfolio/4`. The only thing this edits is the name.
  """
  @impl true
  def rename_account(id, name, opts),
    do: Rest.rename_portfolio(Keyword.get(opts, :credentials, %{}), id, name, opts)

  @doc """
  What this API key is allowed to do.

  See `DpExchange.Coinbase.Rest.get_key_permissions/2`. Three separate permissions, and
  `can_transfer` is the one that moves money. Carries the portfolio the key is scoped to.
  """
  @impl true
  def get_roles(opts),
    do: Rest.get_key_permissions(Keyword.get(opts, :credentials, %{}), opts)

  @doc """
  The venue's own clock. **Public.**

  See `DpExchange.Coinbase.Rest.get_server_time/1`. Worth reading because this venue's JWT
  window is two minutes: a host clock further out than that produces authentication failures
  that look like a credential problem.
  """
  @spec get_server_time(keyword()) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_server_time(opts \\ []), do: Rest.get_server_time(opts)
end

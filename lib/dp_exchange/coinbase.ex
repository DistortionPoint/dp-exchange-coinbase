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

  **Credentials choose the endpoint; they do not gate it.** Coinbase serves the same
  market data publicly and authenticated. Pass credentials and this package uses the
  authenticated path, which has the higher ceiling; pass none and it uses the public one.
  Either way you get the same `Core.Types.*` back, and `capabilities/0` tells you what the
  difference bought.

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

  alias DpExchange.Coinbase.{Feed, Rest, Supervisor}
  alias DpExchange.Core.{Capabilities, Venue}

  @unsupported [
    # Core 0.1.16's wider facade — declared, not yet implemented. Each is a Phase 3–13
    # item. `:unsupported` is about this package unless the note says otherwise.
    {:get_positions, 1},
    {:get_funding, 2},
    {:get_contract_stats, 2},
    {:get_staking_rates, 1},
    {:get_staking_balances, 1},
    {:get_staking_rewards, 1},
    {:get_staking_history, 1},
    {:stake, 3},
    {:unstake, 3},
    # **Coinbase's convert is the two-step form, not the one-step one.** Advanced Trade
    # publishes `POST /convert/quote`, `POST /convert/trade/{id}` and
    # `GET /convert/trade/{id}` — quote, commit, read — which is `quote_conversion/4` and
    # friends, still unimplemented and scheduled on their own. There is a one-step
    # `POST /conversions`, but it belongs to the **Exchange** API, a different product this
    # package does not reach. So `convert/4` has no endpoint on this package's surface.
    {:convert, 4},
    # `/products/volume-summary` is **market** volume and lives on the Exchange API too.
    # `get_trade_volume/2` asks what *this account* traded, which Advanced Trade does not
    # aggregate — it reports fills, and summing them here would be this package's
    # arithmetic rather than the venue's ledger.
    {:get_trade_volume, 2},
    {:quote_conversion, 4},
    {:commit_conversion, 2},
    {:get_conversion, 2},
    {:list_portfolios, 1},
    {:get_deposit_address, 3},
    {:list_approved_addresses, 1},
    {:estimate_withdrawal_fee, 4},
    {:withdraw, 5},
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
    {:create_account, 1},
    {:rename_account, 3},
    {:get_roles, 1},
    # **No bulk cancel here — checked against the venue's reference on 2026-09-01.**
    # `POST /orders/batch_cancel` takes an explicit `order_ids` list; it is the endpoint
    # `cancel_order/3` already uses, one id at a time. There is no "cancel everything"
    # call, and building one from `get_orders/2` plus a batch of ids would be N partial
    # outcomes with no way to reach an order that appeared between the listing and the
    # cancel — a bulk cancel that is not one.
    {:cancel_all_orders, 2},
    {:get_transfers, 2},
    {:quantization, 1},
    {:get_market_overview, 1},
    {:list_instruments, 1},
    {:get_fees, 2},
    {:get_order_book, 2},
    {:get_trade_history, 2},
    {:test_connection, 2},
    {:get_rate_limit_status, 2}
  ]

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

  @impl true
  def capabilities do
    Capabilities.new(
      endpoints: endpoint_maturities(),
      supported_quotes: ~w(USDC USD EUR GBP BTC USDT ETH INR AUD CAD SGD),
      supported_instrument_types: [:spot],
      supports_short_selling: false,
      # Both were `false`, on an unchecked claim that the venue publishes neither endpoint.
      # It publishes `/orders/preview` and `/orders/edit`, and the second matters more than
      # a convenience: `supports_order_replace: false` told a caller to cancel and re-place,
      # which opens a window where no order is live. The package was describing a risk it
      # was creating by not implementing the endpoint that avoids it.
      supports_order_preview: true,
      supports_order_replace: true,
      streamable: [:quotes],
      historical_timeframes: Rest.granularities(),
      max_candles_per_request: Rest.max_candles(),
      reports_trade_volume: true,
      catalog_size: :small,

      # Credentials buy a higher ceiling here, not access: the same market data is
      # served publicly. The three-way answer is the point — a boolean could only say
      # "required" or "not", and neither is true.
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
  def get_order_book(_symbol, _opts), do: Venue.not_supported()

  @impl true
  def get_market_overview(_opts), do: Venue.not_supported()

  @impl true
  def list_instruments(_opts), do: Venue.not_supported()

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

  @impl true
  def get_fees(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def get_transfers(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def place_order(credentials, request, opts \\ []),
    do: Rest.place_order(credentials, request, opts)

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
  def get_trade_history(_credentials, _opts), do: Venue.not_supported()

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

  @impl true
  def test_connection(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def market_status(_opts), do: {:ok, :open}

  @impl true
  def quantization(_symbol), do: Venue.not_supported()

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

  @impl true
  def get_positions(_opts), do: Venue.not_supported()

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

  @impl true
  def stake(_asset, _amount, _opts), do: Venue.not_supported()

  @impl true
  def unstake(_asset, _amount, _opts), do: Venue.not_supported()

  @impl true
  def quote_conversion(_from, _to, _amount, _opts), do: Venue.not_supported()

  @impl true
  def commit_conversion(_id, _opts), do: Venue.not_supported()

  @impl true
  def get_conversion(_id, _opts), do: Venue.not_supported()

  @impl true
  def convert(_from, _to, _amount, _opts), do: Venue.not_supported()

  @impl true
  def get_trade_volume(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def list_portfolios(_opts), do: Venue.not_supported()

  @impl true
  def get_deposit_address(_asset, _network, _opts), do: Venue.not_supported()

  @impl true
  def list_approved_addresses(_opts), do: Venue.not_supported()

  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts), do: Venue.not_supported()

  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts), do: Venue.not_supported()

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

  @impl true
  def create_account(_opts), do: Venue.not_supported()

  @impl true
  def rename_account(_id, _name, _opts), do: Venue.not_supported()

  @impl true
  def get_roles(_opts), do: Venue.not_supported()
end

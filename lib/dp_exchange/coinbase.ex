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
    # Neither exists on this venue. `preview_order/3` has no endpoint at all;
    # `replace_order/4` means a caller cancels and re-places, which is NOT equivalent —
    # it opens a window in which no order is live.
    {:preview_order, 3},
    {:replace_order, 4},
    {:get_transfers, 2},
    {:quantization, 1},
    {:get_market_overview, 1},
    {:list_instruments, 1},
    {:get_accounts, 2},
    {:get_fees, 2},
    {:get_order_book, 2},
    {:place_order, 3},
    {:cancel_order, 3},
    {:get_order, 3},
    {:get_orders, 2},
    {:get_trade_history, 2},
    {:get_balances, 2},
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
  def get_balances(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def get_accounts(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def get_fees(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def get_transfers(_credentials, _opts), do: Venue.not_supported()

  @impl true
  def place_order(_credentials, _request, _opts), do: Venue.not_supported()

  @doc """
  **Not supported.** This venue publishes no order-preview endpoint.

  Declared through `supports_order_preview: false`, so a consumer routes around it rather
  than discovering the refusal at call time.
  """
  @impl true
  def preview_order(_credentials, _request, _opts \\ []), do: Venue.not_supported()

  @doc """
  **Not supported.** This venue has no atomic replace; a caller cancels and re-places.

  That is not equivalent — it opens a window in which no order is live — which is why
  `supports_order_replace: false` is a claim about **risk** rather than convenience.
  """
  @impl true
  def replace_order(_credentials, _id, _request, _opts \\ []), do: Venue.not_supported()

  @impl true
  def cancel_order(_credentials, _id, _opts), do: Venue.not_supported()

  @impl true
  def get_order(_credentials, _id, _opts), do: Venue.not_supported()

  @impl true
  def get_orders(_credentials, _opts), do: Venue.not_supported()

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
end

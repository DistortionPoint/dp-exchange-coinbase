defmodule DpExchange.Coinbase.OptionKeys do
  @moduledoc """
  Which option keys each facade function reads, in one place, and the check that refuses
  the rest.

  A misspelt `limt:` or `symbl:` that is silently ignored answers a different question than
  the one asked. Every facade function that takes keyword `opts` calls `check/2` at the
  boundary, before anything is sent and before an internal key (`:limiter`) is added; the
  answer is `DpExchange.Core.Options.check/2`'s, so a stray key is
  `{:error, {:unknown_option, key}}` and options that are not a keyword list are
  `{:error, {:invalid_options, opts}}`. `DpExchange.Coinbase.Fake` calls the same function,
  so the two cannot disagree about a key.

  ## What is allowed

  A function's own keys (the table below) plus `DpExchange.Core.Options.transport_options/0`
  (`:credentials`, `:plug`, `:timeout`, the retry and limiter knobs, ...). A key that selects
  nothing for this venue is not here: `:environment` and `:base_url` are accepted as shared
  transport keys but this package reads neither.

  The streaming calls read only what routes them: `subscribe/2` and `subscribe_notices/1`
  take `:to` (the subscriber) and `:feed` (which feed process); `unsubscribe/2`,
  `update_symbols/2`, `coverage/1`, `wanted/1` and `coverage_by_kind/1` take `:feed`. A
  start option such as `:url` or `:name` handed to them was ignored, and is now refused.
  `DpExchange.Coinbase.Fake` also reads `:channels` on `subscribe/2`, its own seam.

  A function that answers `Venue.not_supported()` is not in the table and does not consult
  it: the endpoint's absence is the more useful answer whatever the options.

  ## The table

  The map under `@keys` in this module is the source; this list mirrors it.

    * no own keys: `get_price`, `get_top_of_book`, `get_symbols`, `get_market_overview`,
      `list_instruments`, `get_alias_map`, the order calls `place_order`, `preview_order`, `replace_order`,
      `preview_replace`, `cancel_order` and `get_order`, `list_payment_methods`,
      `get_payment_method`, `get_roles`, `get_server_time`, `test_connection`,
      `market_status`, `rename_account`, `delete_portfolio`, `staking_status`,
      `unstake_status` and `preview_unstake_wallet`
    * `get_historical_prices`: `:limit`, `:include_partial`
    * `get_order_book`: `:depth`, `:aggregation_price_increment` (`:limit` is refused by name)
    * `get_trades`: `:limit`, `:since`, `:end`, `:include_broken`
    * `get_balances`: `:limit`, `:portfolio`
    * `get_accounts`: `:uuid`, `:limit`, `:portfolio` (`:uuid` with either of the other two
      is refused as `{:unsupported_option, key}`: the single-account read takes neither)
    * `get_fees`, `get_trade_volume`: `:product_type`, `:contract_expiry_type`,
      `:product_venue`
    * `get_orders`: `:status`, `:symbol`, `:limit`, `:portfolio`
    * `get_trade_history`: `:trade_types`, `:symbol`, `:order_id`, `:start`, `:end`,
      `:limit`, `:portfolio`
    * `close_position`: `:client_order_id`, `:size`
    * `transfer_internal`, `commit_conversion`, `get_conversion`: `:from`, `:to`
    * `create_account`: `:name`
    * `list_portfolios`: `:portfolio_type`
    * `get_portfolio_breakdown`: `:currency`
    * `quote_conversion`: `:trade_incentive_metadata`
    * the futures reads, `cancel_futures_sweep` and `set_intraday_margin_setting`:
      `:portfolio` (named only to be refused as `{:unsupported_option, :portfolio}`)
    * `schedule_futures_sweep`: `:usd_amount`
    * `get_current_margin_window`: `:margin_profile_type`
    * `stake`, `unstake`: `:idempotency_key`, `:extra`, `:metadata`, `:portfolio_id`,
      `:wallet_id`
    * `query_transaction_validators`: `:transaction_ids`, `:extra`
    * `claim_rewards`: `:amount`, `:body`, `:idempotency_key`
  """

  alias DpExchange.Core.Options

  @portfolio_scope [:portfolio]
  @summary_filters [:product_type, :contract_expiry_type, :product_venue]
  @from_to [:from, :to]
  @stake_keys [:idempotency_key, :extra, :metadata, :portfolio_id, :wallet_id]
  @feed_route [:feed]
  @subscriber [:to, :feed]

  @keys %{
    get_price: [],
    get_top_of_book: [],
    get_historical_prices: [:limit, :include_partial],
    get_symbols: [],
    get_market_overview: [],
    list_instruments: [],
    get_alias_map: [],
    subscribe: @subscriber,
    subscribe_notices: @subscriber,
    unsubscribe: @feed_route,
    update_symbols: @feed_route,
    coverage: @feed_route,
    wanted: @feed_route,
    coverage_by_kind: @feed_route,
    get_order_book: [:depth, :aggregation_price_increment, :limit],
    get_trades: [:limit, :since, :end, :include_broken],
    get_balances: [:limit, :portfolio],
    get_accounts: [:uuid, :limit, :portfolio],
    get_fees: @summary_filters,
    get_trade_volume: @summary_filters,
    get_orders: [:status, :symbol, :limit, :portfolio],
    get_trade_history: [:trade_types, :symbol, :order_id, :start, :end, :limit, :portfolio],
    place_order: [],
    preview_order: [],
    replace_order: [],
    preview_replace: [],
    cancel_order: [],
    get_order: [],
    close_position: [:client_order_id, :size],
    list_payment_methods: [],
    get_payment_method: [],
    get_roles: [],
    get_server_time: [],
    test_connection: [],
    market_status: [],
    transfer_internal: @from_to,
    create_account: [:name],
    rename_account: [],
    delete_portfolio: [],
    list_portfolios: [:portfolio_type],
    get_portfolio_breakdown: [:currency],
    quote_conversion: [:trade_incentive_metadata],
    commit_conversion: @from_to,
    get_conversion: @from_to,
    get_positions: @portfolio_scope,
    list_futures_positions: @portfolio_scope,
    get_futures_position: @portfolio_scope,
    get_futures_balance_summary: @portfolio_scope,
    list_futures_sweeps: @portfolio_scope,
    cancel_futures_sweep: @portfolio_scope,
    get_intraday_margin_setting: @portfolio_scope,
    set_intraday_margin_setting: @portfolio_scope,
    schedule_futures_sweep: [:usd_amount],
    get_current_margin_window: [:margin_profile_type],
    stake: @stake_keys,
    unstake: @stake_keys,
    query_transaction_validators: [:transaction_ids, :extra],
    staking_status: [],
    unstake_status: [],
    preview_unstake_wallet: [],
    claim_rewards: [:amount, :body, :idempotency_key]
  }

  @doc """
  The keys `function` reads itself, without the shared transport keys.

  Raises `KeyError` for a function that is not in the table, so a typo in a call site fails
  loudly instead of allowing everything.
  """
  @spec own_keys(atom()) :: [atom()]
  def own_keys(function), do: Map.fetch!(@keys, function)

  @doc """
  Every key `function` accepts: its own keys and `DpExchange.Core.Options.transport_options/0`.
  """
  @spec allowed(atom()) :: [atom()]
  def allowed(function), do: Options.transport_options() ++ own_keys(function)

  @doc """
  Checks `opts` against what `function` reads.

  `:ok`, `{:error, {:unknown_option, key}}` for the first key it does not read, or
  `{:error, {:invalid_options, opts}}` when `opts` is not a keyword list.
  """
  @spec check(atom(), term()) ::
          :ok | {:error, {:unknown_option, atom()} | {:invalid_options, term()}}
  def check(function, opts), do: Options.check(opts, allowed(function))

  @doc """
  Merges two option lists, `opts` winning, for a call that takes both (`transfer_internal/4`).

  An argument that is not a keyword list cannot be merged: it is returned as given, so the
  `check/2` that follows answers `{:error, {:invalid_options, v}}` instead of the merge
  raising.
  """
  @spec merge(term(), term()) :: term()
  def merge(request_opts, opts) do
    cond do
      not Keyword.keyword?(request_opts) -> request_opts
      not Keyword.keyword?(opts) -> opts
      true -> Keyword.merge(request_opts, opts)
    end
  end

  @doc """
  The same check for the calls that answer a plain value, with no error channel
  (`coverage/1`, `wanted/1`, `coverage_by_kind/1`): raises `ArgumentError` naming the
  problem instead of answering an error.
  """
  @spec check!(atom(), term()) :: :ok
  def check!(function, opts) do
    case check(function, opts) do
      :ok ->
        :ok

      {:error, {:unknown_option, key}} ->
        raise ArgumentError, "#{function}/1 does not read the option #{inspect(key)}"

      {:error, {:invalid_options, value}} ->
        raise ArgumentError,
              "#{function}/1 takes a keyword list of options, got: #{inspect(value)}"
    end
  end
end

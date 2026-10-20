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

  A call that sends an HTTP request allows its own keys (the table below) plus
  `DpExchange.Core.Options.transport_options/0` minus the keys this package cannot honour:

    * `:environment` - the REST hosts are module constants; this package selects no sandbox
    * `:base_url` - the same constants; no call reads an override

  Both are refused as `{:unknown_option, key}` on every call. Every other shared key is
  forwarded to `Core.HttpClient` by `forwarded/0` (`:timeout`, `:retry_attempts`,
  `:retry_delay`, `:plug`, `:adapter`, `:req_adapter`, `:weight`, `:rate_limit_blocking`,
  `:max_retry_after_s`, `:max_body_bytes`, `:log_requests`), `:limiter` is resolved against
  this venue's own default, and `:credentials` signs the request.

  ## Sent-once calls read no retry keys

  `cancel_order`, `replace_order`, `transfer_internal`, `create_account`,
  `delete_portfolio`, `commit_conversion`, `schedule_futures_sweep` and
  `cancel_futures_sweep` are always sent exactly once: no idempotency key the venue honours
  exists for them, and a repeat after a lost answer moves funds twice or reports a refusal
  for a write that took effect. They do not read `:retry_attempts` or `:retry_delay`, so a
  caller passing either (any value, `0` and `1` included) gets
  `{:error, {:unknown_option, key}}` before anything is sent, `Fake` included. A write that
  is retried under an idempotency key (`place_order`, `close_position`, the Prime staking
  writes) keeps both keys.

  A call that sends no request allows only its own keys plus `:credentials` (exempt: a
  consumer hands one credential set to every call, and one a call does not need changes no
  answer). Any other transport key, `timeout: 5_000` for one, is refused. These are
  `subscribe/2`, `subscribe_notices/1`, `unsubscribe/2`, `update_symbols/2`, `coverage/1`,
  `wanted/1`, `coverage_by_kind/1` and `market_status/1`. `subscribe/2` and
  `subscribe_notices/1` take `:to` (the subscriber) and `:feed` (which feed process); the
  rest of the feed calls take `:feed`. A start option such as `:url` or `:name` handed to
  them was ignored, and is refused. `DpExchange.Coinbase.Fake` also reads `:channels` on
  `subscribe/2`, its own seam. The plain-value reads (`coverage/1`, `wanted/1`,
  `coverage_by_kind/1`) raise `ArgumentError` instead.

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
  # `:name` is the tree's own name (`DpExchange.Coinbase.child_spec/1`'s), from which the feed's,
  # the limiter's and the ledger's names are derived when they are not given.
  @feed_route [:feed, :name]
  @subscriber [:to, :feed, :name]

  # The calls that send no HTTP request. They allow their own keys and `:credentials`.
  @no_request [
    :subscribe,
    :subscribe_notices,
    :unsubscribe,
    :update_symbols,
    :coverage,
    :wanted,
    :coverage_by_kind,
    :market_status
  ]

  # The calls that are always sent exactly once, whatever the caller passes: an unkeyed write
  # (`Rest.post_once/4`, `Rest.once/1` force one attempt) the venue cannot tell from its own
  # repeat. They do not read `:retry_attempts` or `:retry_delay`, so both are refused as
  # `{:unknown_option, key}` rather than accepted and overwritten. A write that IS retried
  # under an idempotency key (`place_order`, `close_position`, the Prime staking calls) keeps
  # both keys.
  @sent_once [
    :cancel_order,
    :replace_order,
    :transfer_internal,
    :create_account,
    :delete_portfolio,
    :commit_conversion,
    :schedule_futures_sweep,
    :cancel_futures_sweep
  ]
  @retry_keys [:retry_attempts, :retry_delay]

  # Shared transport keys this package cannot honour on a request, and why. A key listed here
  # is refused as `{:unknown_option, key}` on every call.
  @not_read [
    environment: "the REST hosts are module constants; this package selects no sandbox",
    base_url: "the REST hosts are module constants; no call reads an override"
  ]

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
  The transport keys a request call hands to `Core.HttpClient`: every shared key except
  `:credentials` (read to sign), `:limiter` (resolved with this venue's own default) and the
  keys this package cannot honour (see the moduledoc).
  """
  @spec forwarded() :: [atom()]
  def forwarded do
    Options.transport_options() -- [:credentials, :limiter | Keyword.keys(@not_read)]
  end

  @doc """
  Every key `function` accepts.

  A call that sends a request: `transport_options() -- not_read` plus its own keys (and
  without `:retry_attempts` / `:retry_delay` when the call is always sent once, see the
  moduledoc). A call
  that sends none (`no_request/0`): its own keys plus `:credentials` only.
  """
  @spec allowed(atom()) :: [atom()]
  def allowed(function) when function in @no_request,
    do: [:credentials | own_keys(function)]

  def allowed(function) when function in @sent_once,
    do:
      (Options.transport_options() -- (Keyword.keys(@not_read) ++ @retry_keys)) ++
        own_keys(function) ++ tree_name(function)

  def allowed(function),
    do:
      (Options.transport_options() -- Keyword.keys(@not_read)) ++
        own_keys(function) ++ tree_name(function)

  # A request is metered in the limiter of the tree it names: `:name` derives it when `:limiter`
  # is not given (`DpExchange.Coinbase.Supervisor.limiter_name/1`). `create_account/1` reads
  # `:name` as the new portfolio's own name, so it cannot also name a tree and keeps `:limiter`.
  defp tree_name(function) do
    if :name in own_keys(function), do: [], else: [:name]
  end

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

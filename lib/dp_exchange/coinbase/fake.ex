defmodule DpExchange.Coinbase.Fake do
  @moduledoc """
  An in-process Coinbase, for a consumer's tier-1 tests and for the conformance suite's
  active-endpoint assertion.

  **It is not a mock.** Nothing is stubbed, no expectation is recorded, and no call is
  verified. It is a real implementation of `DpExchange.Core.Venue` that answers from
  memory instead of from the network, and it runs the *same* conformance suite as the
  real adapter.

  ## Two rules, from thirteen real bug reports about a comparable fake

  Eleven of those thirteen were the fake diverging from the real client. Six were loud —
  the fake rejecting what the real thing accepts — which costs time and nothing else.
  Three were silent, and those are the ones this is designed against.

  **Less capable is allowed. Differently capable is not.** Where this cannot answer, it
  returns an error. It never returns an empty success for something unsupported: the
  original answered `{:ok, []}` to an unsupported query and dropped clauses it could not
  parse, so callers got plausible wrong answers rather than failures.

  **It never rewrites a value the caller supplied.** The original discarded the caller's
  timestamp and substituted the current clock, landing points written 900 seconds apart
  microseconds apart.

  ## It models Coinbase's refusals, not just its successes

  A fake where everything works proves only half the contract. This one refuses a symbol
  it does not carry with `{:refused, :not_listed}` — permanent, distinct from a transient
  error — and refuses a timeframe Coinbase does not serve, including `12h`, which the
  shared vocabulary models and this venue does not.

  It also enforces the **350-candle boundary as a refusal rather than a truncation**,
  because that is what the venue does: 351 candles requested returns zero and an error,
  not the first 350.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Coinbase.Rest
  alias DpExchange.Core.{Notice, Types, Venue}

  @symbols ~w(BTC-USD BTC-USDC ETH-USD ETH-EUR)

  @price %{
    "BTC-USD" => "78776.85",
    "BTC-USDC" => "78780.10",
    "ETH-USD" => "2951.40",
    "ETH-EUR" => "2703.85"
  }

  # Fixed, not `utc_now/0`. A fake that stamps the current clock cannot be used to test
  # anything about freshness, and stamping now is the substitution this family refuses.
  @at ~U[2026-08-28 12:00:00Z]

  @impl true
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @impl true
  def start_link(_opts), do: :ignore

  @impl true
  def provider_name, do: DpExchange.Coinbase.provider_name()

  @impl true
  def runtime_id, do: DpExchange.Coinbase.runtime_id()

  @impl true
  def asset_classes, do: DpExchange.Coinbase.asset_classes()

  # The real declaration, deliberately. A fake declaring different capabilities from the
  # venue it stands in for is a fake a consumer cannot use to test capability branching.
  @impl true
  def capabilities, do: DpExchange.Coinbase.capabilities()

  @impl true
  def get_price(symbol, _opts \\ []) do
    case Map.fetch(@price, symbol) do
      {:ok, price} ->
        {:ok,
         %Types.Quote{
           symbol: symbol,
           price: Decimal.new(price),
           volume: Decimal.new("1234.5"),
           timestamp: @at,
           provider: :coinbase
         }}

      :error ->
        {:refused, :not_listed}
    end
  end

  @impl true
  def get_top_of_book(symbol, _opts \\ []) do
    case Map.fetch(@price, symbol) do
      {:ok, price} ->
        {:ok,
         %Types.TopOfBook{
           symbol: symbol,
           # A spread around the fake's price, and the bid deliberately not equal to it: a
           # test that passes only when they coincide is not testing the split.
           bid: Decimal.sub(Decimal.new(price), Decimal.new("0.40")),
           ask: Decimal.add(Decimal.new(price), Decimal.new("0.60")),
           bid_size: nil,
           ask_size: nil,
           venue_time: @at,
           observed_at: @at,
           provider: :coinbase
         }}

      :error ->
        {:refused, :not_listed}
    end
  end

  @impl true
  def get_historical_prices(symbol, timeframe, range \\ [], _opts \\ []) do
    cond do
      symbol not in @symbols ->
        {:refused, :not_listed}

      timeframe not in Rest.granularities() ->
        # Includes `12h`, which the shared vocabulary models and Coinbase does not serve.
        {:error, {:unsupported_timeframe, timeframe}}

      requested(range, timeframe) > Rest.max_candles() ->
        {:error,
         {:range_too_wide, requested: requested(range, timeframe), max: Rest.max_candles()}}

      true ->
        # A bar, not a quote. The fake returned `get_price/2`'s `Quote` here, which agreed
        # with the real package's own defect — a suite reproducing the bug it is meant to
        # catch.
        {:ok, [fake_candle(symbol, timeframe)]}
    end
  end

  defp fake_candle(symbol, timeframe) do
    price = Decimal.new(@price[symbol])

    %Types.Candle{
      symbol: symbol,
      timeframe: timeframe,
      opened_at: @at,
      # A bar with a real range, so a caller reading `high` gets something a `close` is not.
      open: Decimal.sub(price, Decimal.new("5")),
      high: Decimal.add(price, Decimal.new("12")),
      low: Decimal.sub(price, Decimal.new("9")),
      close: price,
      volume: Decimal.new("3.5"),
      provider: :coinbase
    }
  end

  @impl true
  def get_symbols(_opts \\ []), do: {:ok, @symbols}

  @impl true
  def get_order_book(symbol, opts \\ []) do
    case Map.fetch(@price, symbol) do
      {:ok, price} ->
        mid = Decimal.new(price)
        limit = Keyword.get(opts, :limit, 3)

        {:ok,
         %Types.OrderBook{
           symbol: symbol,
           # Descending bids, ascending asks — the venue's own ordering, and the sizes
           # differ per level so a caller reading only the top learns it is reading a book.
           bids: book_side(mid, limit, :sub),
           asks: book_side(mid, limit, :add),
           timestamp: @at,
           # The venue publishes no sequence on this endpoint, so neither does the fake: a
           # caller must not learn to detect stream gaps from a REST book.
           sequence: nil,
           provider: :coinbase
         }}

      :error ->
        {:refused, :not_listed}
    end
  end

  @impl true
  def get_trades(symbol, _opts \\ []) do
    case Map.fetch(@price, symbol) do
      {:ok, price} ->
        # More than one print, because the whole point of the tape is that get_price/2
        # keeps only the newest and this does not.
        {:ok,
         [
           %Types.Trade{
             id: "t-1",
             symbol: symbol,
             side: :buy,
             price: Decimal.new(price),
             quantity: Decimal.new("0.25"),
             timestamp: @at,
             broken: false,
             provider: :coinbase
           },
           %Types.Trade{
             id: "t-2",
             symbol: symbol,
             side: :sell,
             price: Decimal.sub(Decimal.new(price), Decimal.new("1.50")),
             quantity: Decimal.new("0.10"),
             timestamp: DateTime.add(@at, -5, :second),
             broken: false,
             provider: :coinbase
           }
         ]}

      :error ->
        {:refused, :not_listed}
    end
  end

  defp book_side(mid, limit, direction) do
    for step <- 1..limit do
      offset = Decimal.mult(Decimal.new("0.50"), Decimal.new(step))
      price = if direction == :sub, do: Decimal.sub(mid, offset), else: Decimal.add(mid, offset)
      {price, Decimal.mult(Decimal.new("0.1"), Decimal.new(step))}
    end
  end

  @impl true
  def get_market_overview(_opts), do: Venue.not_supported()

  @impl true
  def get_auction_imbalance(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_volume_profile(_symbol, _timeframe, _opts \\ []), do: Venue.not_supported()
  @impl true
  def list_instruments(_opts), do: Venue.not_supported()
  @impl true
  def get_balances(_credentials, _opts) do
    # A held amount that is not zero, so a consumer reading `available_balance` as the
    # total fails here rather than in production. The real venue reports both and no total.
    available = Decimal.new("1.25")
    hold = Decimal.new("0.25")

    {:ok,
     [
       %Types.Balance{
         currency: "BTC",
         balance: Decimal.add(available, hold),
         available_balance: available,
         hold: hold,
         # When we asked. A balance has no venue event time.
         timestamp: DateTime.utc_now(),
         provider: :coinbase
       },
       %Types.Balance{
         currency: "USD",
         balance: Decimal.new("10000"),
         available_balance: Decimal.new("10000"),
         hold: Decimal.new("0"),
         timestamp: DateTime.utc_now(),
         provider: :coinbase
       }
     ]}
  end

  @impl true
  def get_accounts(_credentials, opts) do
    accounts = [
      %{
        "uuid" => "8bfc20d7-f7c6-4422-bf07-8243ca4169fe",
        "name" => "BTC Wallet",
        "currency" => "BTC",
        "available_balance" => %{"value" => "1.25", "currency" => "BTC"},
        "hold" => %{"value" => "0.25", "currency" => "BTC"},
        "active" => true,
        "ready" => true,
        "platform" => "ACCOUNT_PLATFORM_CONSUMER"
      }
    ]

    case Keyword.get(opts, :uuid) do
      nil -> {:ok, accounts}
      "8bfc20d7-f7c6-4422-bf07-8243ca4169fe" -> {:ok, accounts}
      # An id the venue does not hold. `{:ok, []}` would read as "this account has nothing".
      _unknown -> {:refused, :not_found}
    end
  end

  @impl true
  def get_fees(_credentials, _opts) do
    # A promotion running, so the two tiers differ — the case a consumer that read only one
    # of them would get wrong.
    {:ok,
     %{
       "total_fees" => 25,
       "fee_tier" => %{
         "pricing_tier" => "<$10k",
         "taker_fee_rate" => "0.0010",
         "maker_fee_rate" => "0.0020"
       },
       "fee_tier_without_promotion" => %{
         "pricing_tier" => "Advanced 3",
         "current_tier" => %{"taker_fee_rate" => "0.0060", "maker_fee_rate" => "0.0040"}
       },
       "advanced_trade_only_volume" => 1000,
       "coinbase_pro_volume" => 250,
       "volume_breakdown" => [%{"volume_type" => "VOLUME_TYPE_SPOT", "volume" => 1000}]
     }}
  end

  @impl true
  def get_transfers(_credentials, _opts), do: Venue.not_supported()
  # Both refused, matching the real venue. A fake that answered where the real one
  # refuses lets a consumer's suite go green against behaviour that cannot happen.

  @impl true
  def get_trade_history(_credentials, opts) do
    # A REVERSAL alongside the FILL, because that is the distinction a consumer must handle:
    # summing a mixed list produces a position and a cost basis that are both wrong and both
    # plausible. The fake filters the same way the real package does.
    wanted = Keyword.get(opts, :trade_types, ["FILL"])

    rows = [
      {"FILL",
       %Types.Fill{
         order_id: "abc-123",
         trade_id: "t-1",
         symbol: "BTC-USD",
         side: :buy,
         quantity: Decimal.new("0.25"),
         price: Decimal.new("40100.5"),
         fee: Decimal.new("1.20"),
         fee_currency: nil,
         timestamp: @at,
         liquidity: :taker,
         provider: :coinbase
       }},
      {"REVERSAL",
       %Types.Fill{
         order_id: "abc-123",
         trade_id: "t-2",
         symbol: "BTC-USD",
         side: :sell,
         quantity: Decimal.new("0.25"),
         price: Decimal.new("40100.5"),
         fee: Decimal.new("0"),
         fee_currency: nil,
         timestamp: @at,
         liquidity: nil,
         provider: :coinbase
       }}
    ]

    {:ok, for({type, fill} <- rows, type in wanted, do: fill)}
  end

  # Streaming, in memory. The fake pushes immediately on subscribe, which is what the
  # real venue's first tick does from the caller's side — and the caller cannot tell the
  # difference, which is the property the facade exists to hold.
  @impl true
  def subscribe(symbols, opts \\ []) do
    target = Keyword.get(opts, :to, self())

    for symbol <- symbols, symbol in @symbols do
      case get_price(symbol, []) do
        {:ok, quote_struct} -> send(target, {:dp_exchange, :coinbase, quote_struct})
        _refused -> :ok
      end
    end

    Process.put(__MODULE__, MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
    :ok
  end

  @impl true
  def unsubscribe(symbols, _opts \\ []) do
    Process.put(__MODULE__, MapSet.difference(subscribed(), MapSet.new(symbols)))
    :ok
  end

  @impl true
  def update_symbols(symbols, _opts \\ []) do
    Process.put(__MODULE__, MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
    :ok
  end

  # Observed, not intended — the fake models the real rule rather than shortcutting it.
  # It reports only symbols it actually pushed for, so a consumer testing the
  # subscribed-but-not-delivering case gets the same shape the real venue would give.
  @impl true
  def coverage(_opts \\ []), do: Map.new(subscribed(), &{&1, :stream})

  @impl true
  def subscribe_notices(opts \\ []) do
    send(
      Keyword.get(opts, :to, self()),
      {:dp_exchange, :coinbase, Notice.new(:link_up, :coinbase)}
    )

    :ok
  end

  defp subscribed, do: Process.get(__MODULE__, MapSet.new())
  @impl true
  def test_connection(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def market_status(_opts), do: {:ok, :open}
  @impl true
  def quantization(symbol) do
    if Map.has_key?(@price, symbol) do
      {:ok,
       %{
         # Deliberately different from quantity_increment: a fake where they match would
         # never catch a caller rounding a price to the base increment.
         price_increment: Decimal.new("0.01"),
         quantity_increment: Decimal.new("0.00000001"),
         min_quantity: Decimal.new("0.00000001"),
         min_quote_size: Decimal.new("1"),
         max_quantity: Decimal.new("1000"),
         max_quote_size: Decimal.new("50000000"),
         status: "online"
       }}
    else
      {:refused, :not_listed}
    end
  end

  defp requested(range, timeframe) do
    finish = Keyword.get(range, :end, @at)
    {:ok, width} = DpExchange.Core.Timeframe.seconds(timeframe)

    case Keyword.get(range, :start) do
      nil -> 0
      start -> div(DateTime.diff(finish, start, :second), width)
    end
  end

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
  def get_positions(_opts \\ []) do
    # A short, and a `realised_pnl` of nil — the two things the mapping has to get right.
    {:ok,
     [
       %Types.Position{
         symbol: "BIT-28JUL23-CDE",
         side: :short,
         quantity: Decimal.new("3"),
         instrument_type: :future,
         average_cost: Decimal.new("30000"),
         mark_price: Decimal.new("29500"),
         notional_value: nil,
         # The venue publishes a daily figure and no lifetime one; this field means the
         # second. `list_futures_positions/1` is where the daily number lives.
         realised_pnl: nil,
         unrealised_pnl: Decimal.new("1500"),
         liquidation_price: nil,
         leverage: nil,
         venue_time: nil,
         provider: :coinbase
       }
     ]}
  end

  @impl true
  def get_funding(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_contract_stats(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_rates(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_balances(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_rewards(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_staking_history(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def stake(asset, amount, opts \\ []) do
    # Same guard as the package: a portfolio or nothing. A fake that defaulted one would
    # let a consumer ship a stake into a portfolio it never named.
    with {:ok, portfolio} <- fake_portfolio(opts) do
      {:ok,
       %{
         "currency" => String.upcase(asset),
         "amount" => Decimal.to_string(amount, :normal),
         "portfolio_id" => portfolio,
         "wallet_id" => Keyword.get(opts, :wallet_id),
         "scope" => fake_scope(opts)
       }}
    end
  end

  @impl true
  def unstake(asset, amount, opts \\ []) do
    with {:ok, portfolio} <- fake_portfolio(opts) do
      # Nothing has arrived. An unstake that reported itself settled would teach a consumer
      # to spend an asset that is still unbonding.
      {:ok,
       %{
         "currency" => String.upcase(asset),
         "amount" => Decimal.to_string(amount, :normal),
         "portfolio_id" => portfolio,
         "wallet_id" => Keyword.get(opts, :wallet_id),
         "scope" => fake_scope(opts),
         "settled" => false
       }}
    end
  end

  defp fake_portfolio(opts) do
    case Keyword.get(opts, :portfolio_id) do
      nil -> {:error, :missing_portfolio}
      portfolio -> {:ok, portfolio}
    end
  end

  defp fake_scope(opts) do
    if Keyword.get(opts, :wallet_id), do: "wallet", else: "portfolio"
  end

  @impl true
  def quote_conversion(from, to, amount, _opts \\ []) do
    # `:quoted`, and no expiry — the two things a consumer must handle. A fake that returned
    # `:settled` would let one ship code that never commits.
    {:ok,
     %Types.Conversion{
       id: "convert-1",
       status: :quoted,
       from_asset: from,
       to_asset: to,
       from_amount: amount,
       to_amount: amount,
       rate: nil,
       fee: Decimal.new("0"),
       expires_at: nil,
       venue_time: nil,
       provider: :coinbase
     }}
  end

  @impl true
  def commit_conversion(id, opts \\ []) do
    # Both accounts or nothing, as in the package: committing against accounts the caller
    # did not name converts between the wrong two balances.
    with {:ok, from, to} <- fake_convert_accounts(opts) do
      {:ok,
       %Types.Conversion{
         id: id,
         status: :committed,
         from_asset: from,
         to_asset: to,
         from_amount: nil,
         to_amount: nil,
         rate: nil,
         fee: nil,
         expires_at: nil,
         venue_time: nil,
         provider: :coinbase
       }}
    end
  end

  @impl true
  def get_conversion(id, opts \\ []) do
    with {:ok, from, to} <- fake_convert_accounts(opts) do
      {:ok,
       %Types.Conversion{
         id: id,
         status: :settled,
         from_asset: from,
         to_asset: to,
         from_amount: nil,
         to_amount: nil,
         rate: nil,
         fee: nil,
         expires_at: nil,
         venue_time: nil,
         provider: :coinbase
       }}
    end
  end

  defp fake_convert_accounts(opts) do
    case {Keyword.get(opts, :from), Keyword.get(opts, :to)} do
      {from, to} when is_binary(from) and is_binary(to) -> {:ok, from, to}
      _missing -> {:error, :from_and_to_required}
    end
  end

  @impl true
  def convert(_from, _to, _amount, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_trade_volume(_credentials, _opts \\ []) do
    # The Advanced Trade and Pro totals ride alongside the breakdown rather than being
    # folded into it: the venue documents the first as non-inclusive of the second, so
    # adding either to the breakdown double counts.
    {:ok,
     [
       %{
         "volume_type" => "VOLUME_TYPE_SPOT",
         "volume" => 1000,
         "advanced_trade_only_volume" => 1000,
         "coinbase_pro_volume" => 250,
         "total_fees" => 25
       }
     ]}
  end

  @impl true
  def list_portfolios(_opts \\ []) do
    # A deleted one alongside a live one: the venue keeps deleted portfolios in the listing
    # because old orders still name them, and a fake that returned only live ones would let
    # a consumer treat a historical id as one that never existed.
    {:ok,
     [
       %Types.Portfolio{
         id: "pf-1",
         name: "Default",
         type: "DEFAULT",
         deleted: false,
         provider: :coinbase
       },
       %Types.Portfolio{
         id: "pf-2",
         name: "Retired",
         type: "CONSUMER",
         deleted: true,
         provider: :coinbase
       }
     ]}
  end

  @impl true
  def get_deposit_address(_asset, _network, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_approved_addresses(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_chain(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_expirations(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_option_greeks(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def list_watchlists(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def create_watchlist(_name, _symbols, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def update_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def delete_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_financials(_symbol, _kind, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_corporate_events(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_filings(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_news(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def get_screener(_name, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def create_account(opts \\ []) do
    case Keyword.get(opts, :name) do
      name when is_binary(name) ->
        {:ok,
         %Types.Portfolio{
           id: "pf-new",
           name: name,
           type: "CONSUMER",
           deleted: false,
           provider: :coinbase
         }}

      _missing ->
        {:error, :name_required}
    end
  end

  @impl true
  def rename_account(id, name, _opts \\ []) do
    {:ok,
     %Types.Portfolio{
       id: id,
       name: name,
       type: "CONSUMER",
       deleted: false,
       provider: :coinbase
     }}
  end

  @impl true
  def get_roles(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @impl true
  def place_order(_credentials, request, _opts \\ []) do
    # The fake accepts what the venue accepts and refuses what it refuses. The combination
    # table is the venue's, so a caller that would be rejected upstream is rejected here —
    # a fake that accepted everything would let a consumer's test pass on an order the
    # venue will not take.
    case {Map.get(request, :order_type, :limit), Map.get(request, :time_in_force, :gtc)} do
      pair
      when pair in [
             {:market, :ioc},
             {:market, :fok},
             {:limit, :gtc},
             {:limit, :gtd},
             {:limit, :fok},
             {:stop_limit, :gtc},
             {:stop_limit, :gtd}
           ] ->
        {type, tif} = pair

        {:ok,
         %Types.Order{
           id: "fake-order-1",
           symbol: Map.fetch!(request, :symbol),
           side: Map.fetch!(request, :side),
           order_type: type,
           time_in_force: tif,
           quantity: Map.get(request, :quantity),
           price: Map.get(request, :price),
           status: :pending,
           provider: :coinbase
         }}

      {type, tif} ->
        {:error, {:unsupported_order_combination, type, tif}}
    end
  end

  @impl true
  def cancel_all_orders(_credentials, _opts \\ []), do: Venue.not_supported()
  @impl true
  def cancel_order(_credentials, order_id, _opts \\ []) do
    # The fake refuses the same way the venue does: an order that is not open cannot be
    # cancelled, and saying :ok would let a consumer's retry logic go untested.
    case order_id do
      "fake-order-1" -> {:ok, :cancelled}
      "already-filled" -> {:refused, {:cancel_rejected, "UNKNOWN_CANCEL_FAILURE_REASON"}}
      _unknown -> {:refused, {:cancel_rejected, "UNKNOWN_CANCEL_ORDER"}}
    end
  end

  @impl true
  def get_order(_credentials, order_id, _opts \\ []) do
    case order_id do
      "fake-order-1" -> {:ok, fake_order()}
      _unknown -> {:refused, :not_found}
    end
  end

  @impl true
  def get_orders(_credentials, _opts \\ []), do: {:ok, [fake_order()]}

  defp fake_order do
    %Types.Order{
      id: "fake-order-1",
      symbol: "BTC-USD",
      side: :buy,
      order_type: :limit,
      time_in_force: :gtc,
      quantity: Decimal.new("0.5"),
      filled_quantity: Decimal.new("0"),
      price: Decimal.new("40000"),
      status: :open,
      provider: :coinbase
    }
  end

  @impl true
  def preview_order(_credentials, request, _opts \\ []) do
    with :ok <- fake_combination(request) do
      {:ok,
       %{
         order_total: Decimal.new("20000.00"),
         commission_total: Decimal.new("10.00"),
         base_size: Map.get(request, :quantity),
         quote_size: nil,
         best_bid: Decimal.new("39990"),
         best_ask: Decimal.new("40010"),
         slippage: Decimal.new("0.001"),
         warning: nil,
         preview_id: "fake-preview-1"
       }}
    end
  end

  @impl true
  def replace_order(_credentials, order_id, changes, _opts \\ []) do
    # The fake enforces the venue's edit surface: price and size only. A fake that accepted
    # a side change would let a consumer's test pass on an edit the venue refuses.
    case Map.keys(changes) -- [:price, :quantity] do
      [] ->
        # Read back, as the real package does: the venue's edit response carries no order.
        {:ok,
         %{fake_order() | id: order_id, price: Map.get(changes, :price) || fake_order().price}}

      unsupported ->
        {:error, {:unsupported_order_edit, unsupported}}
    end
  end

  @impl true
  def preview_replace(_credentials, order_id, changes, _opts \\ []) do
    # The same edit surface replace_order/4 enforces — price and size only. Anything else is
    # an edit the venue refuses, and a fake that priced it would let a consumer's suite go
    # green on a call that cannot be made.
    case Map.keys(changes) -- [:price, :quantity] do
      [] ->
        {:ok,
         %{
           order_total: Decimal.new("20000.00"),
           commission_total: Decimal.new("10.00"),
           base_size: Map.get(changes, :quantity),
           quote_size: nil,
           best_bid: Decimal.new("39990"),
           best_ask: Decimal.new("40010"),
           average_filled_price: Decimal.new("40000"),
           order_margin_total: nil,
           slippage: Decimal.new("0.001"),
           order_id: order_id
         }}

      unsupported ->
        {:error, {:unsupported_order_edit, unsupported}}
    end
  end

  @impl true
  def close_position(_credentials, symbol, _opts \\ []) do
    # Side stays nil, as it does in the real package: the venue never states it and this
    # package never read the position. A fake that filled in :sell would teach a consumer
    # to rely on a field that is nil in production.
    {:ok,
     %Types.Order{
       id: "fake-close-1",
       symbol: symbol,
       side: nil,
       order_type: :market,
       time_in_force: :ioc,
       quantity: Decimal.new("1"),
       status: :pending,
       provider: :coinbase
     }}
  end

  @impl true
  def list_payment_methods(_credentials, _opts \\ []) do
    # One method verified for deposit but not withdrawal, because the two flags disagree
    # routinely and a fake that set them together would hide the case that bites.
    {:ok,
     [
       %{
         "id" => "pm-1",
         "type" => "ACH",
         "verified" => true,
         "allow_deposit" => true,
         "allow_withdraw" => false
       },
       %{
         "id" => "pm-2",
         "type" => "FIAT_ACCOUNT",
         "verified" => true,
         "allow_deposit" => true,
         "allow_withdraw" => true
       }
     ]}
  end

  @impl true
  def get_payment_method(_credentials, id, _opts \\ []),
    do: {:ok, %{"id" => id, "type" => "ACH", "verified" => true, "allow_withdraw" => false}}

  @impl true
  def transfer_internal(asset, amount, opts, _request_opts) do
    # Both uuids or nothing. A fake that defaulted one would let a consumer ship a move
    # between portfolios it never named.
    with from when is_binary(from) <- Keyword.get(opts, :from),
         to when is_binary(to) <- Keyword.get(opts, :to) do
      {:ok,
       %{
         "source_portfolio_uuid" => from,
         "target_portfolio_uuid" => to,
         "funds" => %{"value" => Decimal.to_string(amount, :normal), "currency" => asset}
       }}
    else
      _missing -> {:error, :missing_portfolio}
    end
  end

  @impl true
  def add_payment_method(_details, _opts \\ []), do: Venue.not_supported()

  @impl true
  def request_approved_address(_asset, _network, _address, _opts \\ []),
    do: Venue.not_supported()

  @impl true
  def remove_approved_address(_network, _address, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_networks(_asset, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_transactions(_credentials, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_fee_promos(_opts \\ []), do: Venue.not_supported()

  @impl true
  def get_fx_rate(_pair, _at, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_notional_balances(_credentials, _currency, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_custody_fees(_credentials, _opts \\ []), do: Venue.not_supported()

  defp fake_combination(request) do
    pair = {Map.get(request, :order_type, :limit), Map.get(request, :time_in_force, :gtc)}

    if pair in [
         {:market, :ioc},
         {:market, :fok},
         {:limit, :gtc},
         {:limit, :gtd},
         {:limit, :fok},
         {:stop_limit, :gtc},
         {:stop_limit, :gtd}
       ] do
      :ok
    else
      {type, tif} = pair
      {:error, {:unsupported_order_combination, type, tif}}
    end
  end
end

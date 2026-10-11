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

  ## Failure injection

  Every function below with a real success path (not an unconditional
  `Venue.not_supported()`) checks `DpExchange.Core.FakeInjection.next_outcome/1` or `/2`
  first — a queued or always-set outcome from `FakeInjection.queue_failures/2,3` or
  `fail_always/2,3` short-circuits the fake's normal logic and is returned as-is. See that
  module for the full contract, and `DpExchange.Robinhood.Fake` for the same wiring
  applied to a venue whose `Fake` also gates credentials.

  `subscribe/2`, `unsubscribe/2` and `update_symbols/2` are NOT wired — each takes a list
  of symbols in one call, and "this one symbol in the batch fails, the rest succeed" is a
  case whole-call injection cannot express. `coverage/1` and `subscribe_notices/1` are not
  wired either: both are local bookkeeping reads/writes that always succeed by
  construction, not a call standing in for one the real venue could refuse.

  ## Credentials, validation and order — the real path's, not a copy

  Every private function checks its credential with `Rest.validate_credentials/1` (`nil`,
  `%{}` and a map that cannot sign are `{:error, {:missing_credentials, :coinbase}}`), after
  the injected outcome and after the same local argument checks, in the same order, as the
  real function. The checks themselves are `Rest`'s (`validate_order_request/1`,
  `validate_order_edit/1`, `validate_candle_request/2`, ...), called rather than re-stated, so
  the two cannot drift. This fake used to inspect no credential at all, so a consumer that
  forgot them saw green tests and a production `:missing_credentials`.

  Public market data (`get_price/2`, `get_order_book/2`, `get_trades/2`, ...) needs none, as on
  the venue; `get_top_of_book/2` is the one public-shaped call that does.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Coinbase.{Rest, SymbolFormat}
  alias DpExchange.Core.{Capabilities, Config, FakeInjection, Instrument, Notice, Types, Venue}

  @symbols ~w(BTC-USD BTC-USDC ETH-USD ETH-EUR)

  # Process-dictionary key for the symbols subscribed WITH `:trades` — see `subscribe/2`.
  @trades_key {__MODULE__, :trades}
  @order_book_key {__MODULE__, :order_book}
  @conversions_key {__MODULE__, :conversions}

  @price %{
    "BTC-USD" => "78776.85",
    "BTC-USDC" => "78780.10",
    "ETH-USD" => "2951.40",
    "ETH-EUR" => "2703.85"
  }

  # Fixed, not `utc_now/0`. A fake that stamps the current clock cannot be used to test
  # anything about freshness, and stamping now is the substitution this family refuses.
  @at ~U[2026-08-28 12:00:00Z]

  # Portfolio and preview ids as the venue issues them: UUIDs (`PortfolioResponse.uuid`,
  # `get_roles`' `portfolio_uuid` and `preview_id` all carry UUID examples in
  # `docs/reference/coinbase/openapi/at-spec.yaml`). The fake used `pf-1`, `pf-new` and
  # `fake-preview-1`, which no consumer validating a venue uuid would accept. The default
  # portfolio is the one `get_roles/1` reports the key attached to, so the two agree.
  @default_portfolio_id "3f2a9c1e-7b64-4d08-9e15-a0c2b7d4f681"
  @retired_portfolio_id "c9d41e72-05af-4b3c-8a96-1e7f20b5d3a4"
  @new_portfolio_id "0e6b8d25-9c3a-4f71-b2d8-5a41c7e90f36"
  @preview_id "b40bbff9-17ce-4726-8b64-9de7ae57ad26"

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
  def get_price(symbol, _opts \\ []), do: with_injection(symbol, fn -> fake_quote(symbol) end)

  # Outside `with_injection/2`, so `subscribe/2` builds its push without consuming a failure
  # a test queued for `get_price/2` (found 2026-10-10).
  defp fake_quote(symbol) do
    case Map.fetch(@price, native(symbol)) do
      {:ok, price} ->
        {:ok,
         %Types.Quote{
           symbol: symbol,
           price: Decimal.new(price),
           volume: Decimal.new("1234.5"),
           # As the real `get_price/2`: the latest trade's size, one print.
           volume_window: :print,
           venue_time: @at,
           observed_at: @at,
           provider: :coinbase
         }}

      :error ->
        {:refused, :not_listed}
    end
  end

  # **`get_top_of_book/2` is the one endpoint on this venue with no public form** — see
  # `DpExchange.Coinbase.Rest.get_top_of_book/2`'s moduledoc: `/best_bid_ask` answers `401`
  # unauthenticated and has no `/market/...` counterpart, so the real client errors with
  # `{:error, {:missing_credentials, :coinbase}}` before a request is even built — never
  # `{:refused, _}`, which `DpExchange.Core.Venue`'s own moduledoc reserves for the venue's
  # own permanent word about a request it actually received; a credential that never left
  # this process was never seen by anything at Coinbase. A fake that answered `:ok`
  # regardless of `opts[:credentials]` would be *more* capable than the venue on exactly
  # the one call where that gap matters — a consumer's test would pass without credentials
  # and the same call would refuse in production, which is the silent "differently
  # capable" divergence this module's own moduledoc says it exists to prevent.
  @impl true
  def get_top_of_book(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      # `Rest`'s own test, so `%{}` — which the real path reads as no credential — refuses
      # here too. This checked only `nil`, and a consumer passing `%{}` got a book.
      with :ok <- Rest.validate_credentials(Keyword.get(opts, :credentials)) do
        case Map.fetch(@price, native(symbol)) do
          {:ok, price} ->
            {:ok,
             %Types.TopOfBook{
               symbol: symbol,
               # A spread around the fake's price, and the bid deliberately not equal to it: a
               # test that passes only when they coincide is not testing the split.
               bid: Decimal.sub(Decimal.new(price), Decimal.new("0.40")),
               ask: Decimal.add(Decimal.new(price), Decimal.new("0.60")),
               # `nil` would claim nobody is quoting either side; the real endpoint carries
               # sizes (`best_level/1` in `Rest`), so the fake does too.
               bid_size: Decimal.new("0.5"),
               ask_size: Decimal.new("0.25"),
               venue_time: @at,
               observed_at: @at,
               provider: :coinbase
             }}

          :error ->
            {:refused, :not_listed}
        end
      end
    end)
  end

  @impl true
  def get_historical_prices(symbol, timeframe, range \\ [], _opts \\ []) do
    with_injection(symbol, fn ->
      # The real path's order: the timeframe and the window are refused locally, before any
      # request, so they win over an unlisted symbol (which only the venue can name). The
      # check is `Rest`'s own — this used to re-state it and answered `:not_listed` first.
      # `12h`, which the shared vocabulary models and Coinbase does not serve, fails here.
      with :ok <- Rest.validate_candle_request(timeframe, range) do
        if native(symbol) in @symbols do
          # A bar, not a quote. The fake returned `get_price/2`'s `Quote` here, which agreed
          # with the real package's own defect — a suite reproducing the bug it is meant to
          # catch.
          {:ok, [fake_candle(symbol, timeframe)]}
        else
          {:refused, :not_listed}
        end
      end
    end)
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
  def get_symbols(_opts \\ []) do
    with_injection(fn -> {:ok, @symbols} end)
  end

  @impl true
  def get_order_book(symbol, opts \\ []),
    do: with_injection(symbol, fn -> fake_order_book(symbol, opts) end)

  # The real path's order: the options are refused locally, before any request, so they win
  # over an unlisted symbol (which only the venue can name). The check is `Rest`'s own.
  defp fake_order_book(symbol, opts) do
    with :ok <- Rest.validate_book_options(opts) do
      case Map.fetch(@price, native(symbol)) do
        {:ok, price} ->
          limit = Keyword.get(opts, :limit) || 3
          {:ok, fake_book(symbol, Decimal.new(price), limit)}

        :error ->
          {:refused, :not_listed}
      end
    end
  end

  defp fake_book(symbol, mid, limit) do
    %Types.OrderBook{
      symbol: symbol,
      # Descending bids, ascending asks — the venue's own ordering, and the sizes
      # differ per level so a caller reading only the top learns it is reading a book.
      bids: book_side(mid, limit, :sub),
      asks: book_side(mid, limit, :add),
      venue_time: @at,
      observed_at: @at,
      # The venue publishes no sequence on this endpoint, so neither does the fake: a
      # caller must not learn to detect stream gaps from a REST book.
      sequence: nil,
      provider: :coinbase
    }
  end

  @impl true
  def get_trades(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      # The real package refuses locally when `opts[:limit]` is absent — the venue's
      # `limit` query param is `required: true`
      # (docs/reference/coinbase/openapi/at-spec.yaml:523-528) and documents no default. A
      # fake that answered anyway would let a consumer's suite go green on a call the real
      # venue refuses.
      with {:ok, limit} <- required_trades_limit(opts) do
        get_trades_result(symbol, limit)
      end
    end)
  end

  # `Rest.get_trades/2`'s own rule: absent is `:missing_limit`, and anything but a positive
  # integer is `{:invalid_limit, value}`. This accepted `0`, `-1` and `"5"`.
  defp required_trades_limit(opts) do
    case Keyword.get(opts, :limit) do
      nil -> {:error, :missing_limit}
      limit when is_integer(limit) and limit > 0 -> {:ok, limit}
      other -> {:error, {:invalid_limit, other}}
    end
  end

  # Oldest first, as `Rest.get_trades/2` returns them (it sorts by the venue's own time), and
  # at most `limit` of them, the newest. This returned the newest first, so a consumer reading
  # `List.last/1` as "the latest print" passed here and failed against the venue.
  defp get_trades_result(symbol, limit) do
    case Map.fetch(@price, native(symbol)) do
      {:ok, price} ->
        # More than one print, because the whole point of the tape is that get_price/2
        # keeps only the newest and this does not.
        {:ok,
         Enum.take(
           [
             %Types.Trade{
               id: "t-2",
               symbol: symbol,
               side: :sell,
               price: Decimal.sub(Decimal.new(price), Decimal.new("1.50")),
               quantity: Decimal.new("0.10"),
               timestamp: DateTime.add(@at, -5, :second),
               broken: false,
               provider: :coinbase
             },
             %Types.Trade{
               id: "t-1",
               symbol: symbol,
               side: :buy,
               price: Decimal.new(price),
               quantity: Decimal.new("0.25"),
               timestamp: @at,
               broken: false,
               provider: :coinbase
             }
           ],
           -limit
         )}

      :error ->
        {:refused, :not_listed}
    end
  end

  defp book_side(mid, limit, direction) do
    # `//1`: a `limit` of 0 made `1..0` a descending range, so the book had two levels
    # (`1` and `0`) where the caller asked for none.
    for step <- 1..limit//1 do
      offset = Decimal.mult(Decimal.new("0.50"), Decimal.new(step))
      price = if direction == :sub, do: Decimal.sub(mid, offset), else: Decimal.add(mid, offset)
      {price, Decimal.mult(Decimal.new("0.1"), Decimal.new(step))}
    end
  end

  @impl true
  def get_market_overview(_opts) do
    with_injection(fn ->
      {:ok,
       Map.new(@symbols, fn symbol ->
         price = Decimal.new(@price[symbol])

         {symbol,
          %{
            price: price,
            price_change_24h_pct: Decimal.new("1.25"),
            volume_24h: Decimal.new("1200.5"),
            high_24h: Decimal.add(price, Decimal.new("500")),
            low_24h: Decimal.sub(price, Decimal.new("500")),
            status: "online"
          }}
       end)}
    end)
  end

  @impl true
  def get_auction_imbalance(_symbol, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_volume_profile(_symbol, _timeframe, _opts \\ []), do: Venue.not_supported()

  @impl true
  def list_instruments(_opts) do
    with_injection(fn ->
      {:ok,
       Enum.map(@symbols, fn symbol ->
         [base, quote_asset] = String.split(symbol, "-")

         Instrument.new(
           symbol: symbol,
           base: base,
           quote: quote_asset,
           instrument: :spot,
           status: :tradable
         )
       end)}
    end)
  end

  @impl true
  def get_balances(credentials, _opts) do
    with_credentials(credentials, fn ->
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
    end)
  end

  @impl true
  def get_accounts(credentials, opts) do
    with_credentials(credentials, fn ->
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
        # The venue answers 404, which `Rest` classifies `{:refused, :not_listed}` — the fake
        # said `:not_found`, a reason the real package can never return.
        _unknown -> {:refused, :not_listed}
      end
    end)
  end

  @impl true
  def get_fees(credentials, _opts) do
    with_credentials(credentials, fn ->
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
    end)
  end

  @impl true
  def get_transfers(_credentials, _opts), do: Venue.not_supported()
  # Both refused, matching the real venue. A fake that answered where the real one
  # refuses lets a consumer's suite go green against behaviour that cannot happen.

  @impl true
  def get_trade_history(credentials, opts) do
    # The real function's local filter checks first, then the credential, in that order.
    with :ok <- Rest.validate_fill_filters(opts) do
      do_get_trade_history(credentials, opts)
    end
  end

  defp do_get_trade_history(credentials, opts) do
    with_credentials(credentials, fn ->
      # A REVERSAL alongside the FILL, because that is the distinction a consumer must handle:
      # summing a mixed list produces a position and a cost basis that are both wrong and both
      # plausible. The fake filters the same way the real package does.
      wanted = Config.opt(opts, :trade_types, ["FILL"])

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

      # `:order_id`, `:symbol`, `:start` and `:end` are filters the real package sends to the
      # venue, so they narrow here too. Ignoring them returned a BTC-USD fill to a caller
      # asking for ETH-USD's — a plausible answer to a question that was not asked.
      {:ok,
       for {type, fill} <- rows, type in wanted, fill_matches?(fill, opts) do
         fill
       end}
    end)
  end

  defp fill_matches?(fill, opts) do
    matches?(Keyword.get(opts, :order_id), fill.order_id) and
      matches?(canonical_symbol(Keyword.get(opts, :symbol)), fill.symbol) and
      after_start?(fill.timestamp, Keyword.get(opts, :start)) and
      before_end?(fill.timestamp, Keyword.get(opts, :end))
  end

  defp matches?(nil, _actual), do: true
  defp matches?(wanted, actual) when is_list(wanted), do: actual in wanted
  defp matches?(wanted, actual), do: wanted == actual

  defp canonical_symbol(nil), do: nil
  defp canonical_symbol(symbols) when is_list(symbols), do: Enum.map(symbols, &canonical_symbol/1)
  defp canonical_symbol(symbol), do: SymbolFormat.to_canonical_symbol(symbol)

  defp after_start?(_at, nil), do: true
  defp after_start?(at, %DateTime{} = start), do: DateTime.compare(at, start) == :gt
  defp after_start?(_at, _unreadable), do: true

  defp before_end?(_at, nil), do: true
  defp before_end?(at, %DateTime{} = finish), do: DateTime.compare(at, finish) == :lt
  defp before_end?(_at, _unreadable), do: true

  # Streaming, in memory. The fake pushes immediately on subscribe, which is what the
  # real venue's first tick does from the caller's side — and the caller cannot tell the
  # difference, which is the property the facade exists to hold.
  #
  # `opts[:channels]` mirrors `DpExchange.Coinbase.Feed`'s `:channels` (see its moduledoc's
  # "`:trades` is opt-in" section), per call here because this fake has no connection to
  # configure. `:trades` in the list also pushes one `Types.Trade` per carried symbol. The
  # default is `[:quotes]` — exactly what this fake pushed before `:trades` existed; it
  # has never pushed a book, which `coverage_by_kind/1` says.
  @impl true
  def subscribe(symbols, opts \\ []) do
    symbols = canonical_case(symbols)
    target = Config.opt(opts, :to, self())
    channels = Config.opt(opts, :channels, [:quotes])

    for symbol <- symbols, symbol in @symbols do
      case fake_quote(symbol) do
        # The real stream's volume is `volume_24_h`, a rolling total, where `get_price/2`'s is
        # one print — so the pushed quote says what the real one says.
        {:ok, quote_struct} ->
          streamed = %{quote_struct | volume_window: :rolling_24h}
          send(target, {:dp_exchange, :coinbase, streamed})

        _refused ->
          :ok
      end

      if :trades in channels, do: send(target, {:dp_exchange, :coinbase, trade_for(symbol)})

      # The level2 channel opens with a snapshot, which this fake pushed none of, so a
      # consumer's book handling had nothing to run against. Deltas are not modelled.
      if :order_book in channels do
        with {:ok, book} <- fake_order_book(symbol, []),
             do: send(target, {:dp_exchange, :coinbase, book})
      end
    end

    # Unioned, and only for symbols this call pushed a trade for: a symbol subscribed
    # earlier without `:trades` does not gain trade coverage from a later call for others.
    if :order_book in channels do
      Process.put(
        @order_book_key,
        MapSet.union(subscribed_books(), MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
      )
    end

    if :trades in channels do
      Process.put(
        @trades_key,
        MapSet.union(subscribed_trades(), MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
      )
    end

    # **Added to, never replacing.** This was the identical line `update_symbols/2`
    # carries below — the two callbacks were byte-for-byte the same function — so a
    # second `subscribe/2` dropped whatever the first had subscribed. The real
    # facade unions (`wanted: MapSet.union(state.wanted, MapSet.new(symbols))` in
    # `Feed`), so a consumer's tier-1 tests against this fake certified the opposite
    # of what the venue does: subscribe twice, keep one symbol here, keep both there.
    #
    # The contract settles which is right without needing a new sentence in it.
    # `c:DpExchange.Core.Venue.update_symbols/2` exists to "change a live
    # subscription's symbol set", and `c:unsubscribe/2` to stop delivery for named
    # symbols. Neither has any purpose if `subscribe/2` already replaces — you would
    # just subscribe the new list. Two callbacks the contract distinguishes,
    # implemented as one function, is the tell.
    Process.put(
      __MODULE__,
      MapSet.union(subscribed(), MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
    )

    :ok
  end

  @impl true
  def unsubscribe(symbols, _opts \\ []) do
    symbols = canonical_case(symbols)
    Process.put(__MODULE__, MapSet.difference(subscribed(), MapSet.new(symbols)))
    Process.put(@trades_key, MapSet.difference(subscribed_trades(), MapSet.new(symbols)))
    Process.put(@order_book_key, MapSet.difference(subscribed_books(), MapSet.new(symbols)))
    :ok
  end

  @impl true
  def update_symbols(symbols, _opts \\ []) do
    symbols = canonical_case(symbols)
    wanted = MapSet.new(Enum.filter(symbols, &(&1 in @symbols)))

    # A symbol this adds is pushed for, as `subscribe/2` pushes, so `coverage/1` never
    # answers `:stream` for one that delivered nothing. To the caller, with the default
    # channel: the contract's callback takes neither a `to:` nor `:channels` (2026-10-10).
    for symbol <- MapSet.difference(wanted, subscribed()) do
      with {:ok, quote_struct} <- fake_quote(symbol),
           do:
             send(
               self(),
               {:dp_exchange, :coinbase, %{quote_struct | volume_window: :rolling_24h}}
             )
    end

    Process.put(__MODULE__, wanted)
    # Narrowed, never widened: `update_symbols/2` carries no `:channels`, so a symbol it
    # adds cannot be assumed to want trades.
    Process.put(@trades_key, MapSet.intersection(subscribed_trades(), wanted))
    Process.put(@order_book_key, MapSet.intersection(subscribed_books(), wanted))
    :ok
  end

  # Observed, not intended — the fake models the real rule rather than shortcutting it.
  # It reports only symbols it actually pushed for, so a consumer testing the
  # subscribed-but-not-delivering case gets the same shape the real venue would give.
  @impl true
  def coverage(_opts \\ []), do: Map.new(subscribed(), &{&1, :stream})

  @doc """
  `coverage/1`, split by kind — see `DpExchange.Coinbase.coverage_by_kind/1`.

  `subscribe/2` above only ever pushes a `DpExchange.Core.Types.Quote` (it never
  synthesises a `DpExchange.Core.Types.OrderBook`), so every symbol this fake reports
  arrives under `:quotes` and `:quotes` alone — anything else would claim delivery this
  fake never actually sends, which is exactly the "differently capable" divergence this
  module's own moduledoc forbids. Less capable than the real venue here is honest; a
  fabricated `:order_book` entry would not be.

  `:trades` appears only for symbols a `subscribe/2` call named it for, through
  `opts[:channels]`, and is absent otherwise — the same "only what arrived" rule the real
  `Feed` follows.
  """
  @impl true
  @spec coverage_by_kind(keyword()) :: %{Capabilities.data_kind() => %{String.t() => atom()}}
  def coverage_by_kind(_opts \\ []) do
    # A kind appears only once something of it was pushed, as before for `:trades`.
    [quotes: subscribed(), trades: subscribed_trades(), order_book: subscribed_books()]
    |> Enum.reject(fn {kind, symbols} -> kind != :quotes and MapSet.size(symbols) == 0 end)
    |> Map.new(fn {kind, symbols} -> {kind, Map.new(symbols, &{&1, :stream})} end)
  end

  @impl true
  def subscribe_notices(opts \\ []) do
    send(
      Config.opt(opts, :to, self()),
      {:dp_exchange, :coinbase, Notice.new(:link_up, :coinbase)}
    )

    :ok
  end

  defp subscribed, do: Process.get(__MODULE__, MapSet.new())

  # Kept apart from `subscribed/0`: a symbol can be subscribed for quotes without trades.
  defp subscribed_trades, do: Process.get(@trades_key, MapSet.new())

  defp subscribed_books, do: Process.get(@order_book_key, MapSet.new())

  # One print, shaped as `Socket`'s decode of a `market_trades` `update` row: a real id, a
  # taker `side`, `broken: false` because the channel has no bust flag, and a fixed non-nil
  # timestamp.
  defp trade_for(symbol) do
    %Types.Trade{
      id: "fake-trade-1",
      symbol: symbol,
      side: :buy,
      price: Decimal.new(@price[symbol]),
      quantity: Decimal.new("0.25"),
      timestamp: @at,
      broken: false,
      provider: :coinbase
    }
  end

  @impl true
  def test_connection(credentials, _opts) do
    with_injection(fn ->
      # With a credential the fake answers what the key can do; without one it answers
      # reachability only, which is the same split the package makes. A credential that
      # cannot sign (`%{api_key: "k"}`) is not "none" — the real path reads
      # `/key_permissions` with it and fails signing, so it refuses here too.
      if credentials in [nil, %{}] do
        {:ok, %{"reachable" => true, "time" => %{"iso" => "2026-09-01T20:00:00Z"}}}
      else
        with :ok <- Rest.validate_credentials(credentials) do
          {:ok,
           %{
             "reachable" => true,
             "can_view" => true,
             "can_trade" => true,
             "can_transfer" => false
           }}
        end
      end
    end)
  end

  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def market_status(_opts) do
    with_injection(fn -> {:ok, :open} end)
  end

  @impl true
  def quantization(symbol) do
    with_injection(symbol, fn ->
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
    end)
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
  def get_positions(opts \\ []) do
    with_credentials(opts_credentials(opts), fn ->
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
    end)
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
    with_injection(fn ->
      # Same guard as the package: a portfolio or nothing. A fake that defaulted one would
      # let a consumer ship a stake into a portfolio it never named.
      with {:ok, portfolio} <- fake_portfolio(opts),
           :ok <- fake_prime_checks(asset, amount, opts) do
        {:ok,
         %{
           "currency" => asset && String.upcase(asset),
           "amount" => Decimal.to_string(amount, :normal),
           "portfolio_id" => portfolio,
           "wallet_id" => Keyword.get(opts, :wallet_id),
           "scope" => fake_scope(opts)
         }}
      end
    end)
  end

  @impl true
  def unstake(asset, amount, opts \\ []) do
    with_injection(fn ->
      with {:ok, portfolio} <- fake_portfolio(opts),
           :ok <- fake_prime_checks(asset, amount, opts) do
        # Nothing has arrived. An unstake that reported itself settled would teach a consumer
        # to spend an asset that is still unbonding.
        {:ok,
         %{
           "currency" => asset && String.upcase(asset),
           "amount" => Decimal.to_string(amount, :normal),
           "portfolio_id" => portfolio,
           "wallet_id" => Keyword.get(opts, :wallet_id),
           "scope" => fake_scope(opts),
           "settled" => false
         }}
      end
    end)
  end

  # The real facade's own checks, in its order: a portfolio-scoped write wants an asset, both
  # scopes want a positive finite Decimal, and Prime wants all three of its credentials.
  # Without the last, a consumer's test staked with no Prime key and production refused it.
  defp fake_prime_checks(asset, amount, opts) do
    cond do
      is_nil(Keyword.get(opts, :wallet_id)) and not (is_binary(asset) and asset != "") ->
        {:error, {:invalid_asset, asset}}

      not (is_struct(amount, Decimal) and not Decimal.nan?(amount) and not Decimal.inf?(amount) and
               Decimal.positive?(amount)) ->
        {:error, {:invalid_amount, amount}}

      not prime_credentials?(Keyword.get(opts, :credentials)) ->
        {:error, :missing_prime_credentials}

      true ->
        :ok
    end
  end

  defp prime_credentials?(%{access_key: key, passphrase: phrase, signing_key: signing}),
    do: is_binary(key) and is_binary(phrase) and is_binary(signing)

  defp prime_credentials?(_other), do: false

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
  def quote_conversion(from, to, amount, opts \\ []) do
    with_credentials(opts_credentials(opts), fn ->
      # `:quoted`, and no expiry — the two things a consumer must handle. A fake that returned
      # `:settled` would let one ship code that never commits.
      # Remembered, so a commit or a read names a conversion this fake actually quoted.
      Process.put(@conversions_key, Map.put(conversions(), "convert-1", :quoted))

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
    end)
  end

  @impl true
  def commit_conversion(id, opts \\ []) do
    with_injection(fn ->
      # Both accounts or nothing, as in the package: committing against accounts the caller
      # did not name converts between the wrong two balances. Then the credential, then the
      # venue's own answer about the id — the real order.
      with {:ok, from, to} <- Rest.convert_accounts(opts),
           :ok <- Rest.validate_credentials(opts_credentials(opts)),
           {:ok, _status} <- fake_conversion(id) do
        Process.put(@conversions_key, Map.put(conversions(), id, :committed))

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
    end)
  end

  @impl true
  def get_conversion(id, opts \\ []) do
    with_injection(fn ->
      with {:ok, from, to} <- Rest.convert_accounts(opts),
           :ok <- Rest.validate_credentials(opts_credentials(opts)),
           {:ok, known} <- fake_conversion(id) do
        {:ok,
         %Types.Conversion{
           id: id,
           # A quote read back is still a quote; a committed one has settled here.
           status: if(known == :committed, do: :settled, else: known),
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
    end)
  end

  # **An id this fake never quoted is the venue's 404**, `{:refused, :not_listed}` from
  # `Rest`'s `classify/1`. Every id used to commit and read back `:settled`, so a consumer's
  # test could commit a conversion it never quoted and pass (found 2026-10-10).
  defp fake_conversion(id) do
    case Map.fetch(conversions(), id) do
      {:ok, status} -> {:ok, status}
      :error -> {:refused, :not_listed}
    end
  end

  defp conversions, do: Process.get(@conversions_key, %{})

  @impl true
  def convert(_from, _to, _amount, _opts \\ []), do: Venue.not_supported()

  @impl true
  def get_trade_volume(credentials, _opts \\ []) do
    with_credentials(credentials, fn ->
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
    end)
  end

  @impl true
  def list_portfolios(opts \\ []) do
    with_credentials(opts_credentials(opts), fn ->
      # A deleted one alongside a live one: the venue keeps deleted portfolios in the listing
      # because old orders still name them, and a fake that returned only live ones would let
      # a consumer treat a historical id as one that never existed.
      {:ok,
       [
         %Types.Portfolio{
           id: @default_portfolio_id,
           name: "Default",
           type: "DEFAULT",
           deleted: false,
           provider: :coinbase
         },
         %Types.Portfolio{
           id: @retired_portfolio_id,
           name: "Retired",
           type: "CONSUMER",
           deleted: true,
           provider: :coinbase
         }
       ]}
    end)
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
    with_injection(fn ->
      # The name first, then the credential: `Rest.create_portfolio/2`'s order.
      with {:ok, name} <- Rest.required_name(opts),
           :ok <- Rest.validate_credentials(opts_credentials(opts)) do
        {:ok,
         %Types.Portfolio{
           id: @new_portfolio_id,
           name: name,
           type: "CONSUMER",
           deleted: false,
           provider: :coinbase
         }}
      end
    end)
  end

  @impl true
  def rename_account(id, name, opts \\ []) do
    with_credentials(opts_credentials(opts), fn ->
      {:ok,
       %Types.Portfolio{
         id: id,
         name: name,
         type: "CONSUMER",
         deleted: false,
         provider: :coinbase
       }}
    end)
  end

  @impl true
  def get_roles(opts \\ []) do
    with_credentials(opts_credentials(opts), fn ->
      # `can_transfer` false beside two trues: a key routinely holds some and not all, and a
      # fake that granted everything would let a consumer ship a withdrawal path it cannot use.
      {:ok,
       %{
         "can_view" => true,
         "can_trade" => true,
         "can_transfer" => false,
         "portfolio_uuid" => @default_portfolio_id,
         "portfolio_type" => "DEFAULT"
       }}
    end)
  end

  @impl true
  def place_order(credentials, request, _opts \\ []) do
    with_injection(fn ->
      # The fake accepts what the venue accepts and refuses what it refuses, by running the
      # real package's own checks in its order: the request (identity, the sparse
      # type/time-in-force table, each leaf's required and refused fields), then the
      # credential. This re-stated the table alone, so an order with no symbol raised
      # `KeyError`, a limit order with no price was "placed", and `%{}` credentials passed —
      # each refused by the real path.
      with :ok <- Rest.validate_order_request(request),
           :ok <- Rest.validate_credentials(credentials) do
        placed = %Types.Order{
          id: next_order_id(),
          symbol: Map.fetch!(request, :symbol),
          side: Map.fetch!(request, :side),
          order_type: Map.get(request, :order_type, :limit),
          time_in_force: Map.get(request, :time_in_force, :gtc),
          # Decimals, as the real return: it casts the caller's value, string or float.
          quantity: cast_decimal(Map.get(request, :quantity)),
          price: cast_decimal(Map.get(request, :price)),
          status: :pending,
          provider: :coinbase
        }

        # Remembered (per process) as the working order a later read finds: placed, not
        # filled. `get_order/3`, `get_orders/2` and `cancel_order/3` answer from this, so a
        # place -> read -> cancel -> read test sees the order it placed, as on the venue.
        remember_order(%{placed | status: :open, filled_quantity: Decimal.new("0")})
        {:ok, placed}
      end
    end)
  end

  # A new id per placement. The fake issued the literal `fake-order-1` for every order, so
  # two placements were one order, and read back a BTC-USD buy whatever had been placed.
  @order_id_prefix "d2c4f6a8-1b3e-4c5d-8f70-"
  @orders_key {__MODULE__, :orders}

  defp next_order_id do
    count = map_size(orders()) + 1
    @order_id_prefix <> (count |> Integer.to_string(16) |> String.pad_leading(12, "0"))
  end

  defp orders, do: Process.get(@orders_key, %{})

  defp remember_order(%Types.Order{id: id} = order) do
    Process.put(@orders_key, Map.put(orders(), id, order))
    order
  end

  # An order this process placed, else the one canned order that exists before anything is
  # placed. Anything else is an id the fake never issued.
  defp find_order(order_id) do
    case Map.fetch(orders(), order_id) do
      {:ok, _order} = found -> found
      :error when order_id == "fake-order-1" -> {:ok, fake_order()}
      :error -> :error
    end
  end

  defp cast_decimal(nil), do: nil

  defp cast_decimal(value) do
    case Decimal.cast(value) do
      {:ok, decimal} -> decimal
      :error -> nil
    end
  end

  @impl true
  def place_orders(_credentials, _requests, _opts), do: Venue.not_supported()

  @impl true
  def cancel_all_orders(_credentials, _opts \\ []), do: Venue.not_supported()
  @impl true
  def cancel_order(credentials, order_id, _opts \\ []) do
    with_credentials(credentials, fn ->
      # The fake refuses the same way the venue does: an order that is not open cannot be
      # cancelled, and saying :ok would let a consumer's retry logic go untested.
      cancel_found(find_order(order_id), order_id)
    end)
  end

  # Marked cancelled, so the next read says so. An order already cancelled or filled is not
  # open, and the venue refuses it as it refuses `already-filled`.
  defp cancel_found({:ok, %Types.Order{status: :open} = order}, _order_id) do
    remember_order(%{order | status: :cancelled})
    {:ok, :cancelled}
  end

  defp cancel_found({:ok, _closed}, _order_id),
    do: {:refused, {:cancel_rejected, "UNKNOWN_CANCEL_FAILURE_REASON"}}

  defp cancel_found(:error, "already-filled"),
    do: {:refused, {:cancel_rejected, "UNKNOWN_CANCEL_FAILURE_REASON"}}

  defp cancel_found(:error, _unknown),
    do: {:refused, {:cancel_rejected, "UNKNOWN_CANCEL_ORDER"}}

  @impl true
  def get_order(credentials, order_id, _opts \\ []) do
    with_credentials(credentials, fn ->
      case find_order(order_id) do
        {:ok, order} -> {:ok, order}
        # The venue's 404, which `Rest` classifies `{:refused, :not_listed}`. This said
        # `:not_found`, a reason the real package can never return.
        :error -> {:refused, :not_listed}
      end
    end)
  end

  # `:status` and `:symbol` narrow the list as the real package's venue-side filters do.
  # They were ignored, so a caller asking for FILLED orders or ETH-USD's was handed the one
  # open BTC-USD order — the "plausible answer to a question not asked" this fake must not give.
  @impl true
  def get_orders(credentials, opts \\ []) do
    # The real function's local filter checks first, then the credential, in that order.
    with :ok <- Rest.validate_order_filters(opts) do
      do_get_orders(credentials, opts)
    end
  end

  defp do_get_orders(credentials, opts) do
    with_credentials(credentials, fn ->
      # The canned order, unless it was cancelled here and so is stored, then what this
      # process placed in id order.
      canned = if Map.has_key?(orders(), "fake-order-1"), do: [], else: [fake_order()]
      placed = orders() |> Map.values() |> Enum.sort_by(& &1.id)

      matching =
        Enum.filter(canned ++ placed, fn order ->
          status_matches?(Keyword.get(opts, :status), order.status) and
            matches?(canonical_symbol(Keyword.get(opts, :symbol)), order.symbol)
        end)

      {:ok, matching}
    end)
  end

  defp status_matches?(nil, _actual), do: true

  defp status_matches?(wanted, actual) when is_atom(wanted) or is_binary(wanted),
    do: String.upcase(to_string(wanted)) == String.upcase(to_string(actual))

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
  def preview_order(credentials, request, _opts \\ []) do
    with_injection(fn ->
      # The same request checks `place_order/3` runs, then the credential — as the real path.
      with :ok <- Rest.validate_order_request(request, :preview),
           :ok <- Rest.validate_credentials(credentials) do
        {:ok,
         %{
           order_total: Decimal.new("20000.00"),
           commission_total: Decimal.new("10.00"),
           base_size: cast_decimal(Map.get(request, :quantity)),
           quote_size: nil,
           best_bid: Decimal.new("39990"),
           best_ask: Decimal.new("40010"),
           slippage: Decimal.new("0.001"),
           warning: nil,
           preview_id: @preview_id
         }}
      end
    end)
  end

  @impl true
  def replace_order(credentials, order_id, changes, _opts \\ []) do
    with_injection(fn ->
      # The fake enforces the venue's edit surface: price and size only, both required. A fake
      # that accepted a side change, or only one of the two, would let a consumer's test pass
      # on an edit the real venue refuses — `EditOrderRequest` declares order_id, price AND
      # size all required (docs/reference/coinbase/openapi/at-spec.yaml:6809-6852), the same
      # requirement `Rest.replace_order/4` enforces — and `Rest`'s own check is what runs.
      with :ok <- Rest.validate_order_edit(changes),
           :ok <- Rest.validate_credentials(credentials) do
        # Read back, as the real package does: the venue's edit response carries no order.
        # Both edited fields show in it — the size was left at the original, so the read-back
        # of an edit disagreed with the edit it followed.
        # Of the order this process placed when it is one, so an edit keeps its symbol and
        # side; the canned order otherwise.
        # An id the fake never issued is the venue's 404 on that read-back, so it is refused
        # here rather than answered with the canned order under an id nothing can read.
        case find_order(order_id) do
          {:ok, base} ->
            edited = %{
              base
              | id: order_id,
                price: cast_decimal(Map.get(changes, :price)),
                quantity: cast_decimal(Map.get(changes, :quantity))
            }

            # Remembered, so `get_order/3` and `cancel_order/3` on the same id answer it.
            {:ok, remember_order(edited)}

          :error ->
            {:refused, :not_listed}
        end
      end
    end)
  end

  @impl true
  def preview_replace(credentials, order_id, changes, _opts \\ []) do
    with_injection(fn ->
      # The same edit surface replace_order/4 enforces — price and size, both required.
      # Anything less is an edit the venue refuses, and a fake that priced it would let a
      # consumer's suite go green on a call that cannot be made.
      with :ok <- Rest.validate_order_edit(changes),
           :ok <- Rest.validate_credentials(credentials) do
        {:ok,
         %{
           order_total: Decimal.new("20000.00"),
           commission_total: Decimal.new("10.00"),
           base_size: cast_decimal(Map.get(changes, :quantity)),
           quote_size: nil,
           best_bid: Decimal.new("39990"),
           best_ask: Decimal.new("40010"),
           average_filled_price: Decimal.new("40000"),
           order_margin_total: nil,
           slippage: Decimal.new("0.001"),
           order_id: order_id
         }}
      end
    end)
  end

  @impl true
  def close_position(credentials, symbol, _opts \\ []) do
    with_credentials(credentials, symbol, fn ->
      # Side stays nil, as it does in the real package: the venue never states it and this
      # package never read the position. A fake that filled in :sell would teach a consumer
      # to rely on a field that is nil in production.
      closing = %Types.Order{
        id: next_order_id(),
        symbol: symbol,
        side: nil,
        order_type: :market,
        time_in_force: :ioc,
        quantity: Decimal.new("1"),
        status: :pending,
        provider: :coinbase
      }

      # Remembered (per process) as a working order, so the id it returns reads back through
      # `get_order/3` and answers `cancel_order/3`, as place_order's does.
      remember_order(%{closing | status: :open, filled_quantity: Decimal.new("0")})
      {:ok, closing}
    end)
  end

  @impl true
  def list_payment_methods(credentials, _opts \\ []) do
    with_credentials(credentials, fn ->
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
    end)
  end

  @impl true
  def get_payment_method(credentials, id, _opts \\ []) do
    with_credentials(credentials, fn ->
      {:ok, %{"id" => id, "type" => "ACH", "verified" => true, "allow_withdraw" => false}}
    end)
  end

  @impl true
  def transfer_internal(_asset, _amount, opts, request_opts) do
    with_injection(fn ->
      # Both uuids or nothing. A fake that defaulted one would let a consumer ship a move
      # between portfolios it never named. Merged and read as the facade does (`opts` over
      # `request_opts`), then the credential from `request_opts` — the real order.
      with {:ok, from, to} <- Rest.transfer_portfolios(Keyword.merge(request_opts, opts)),
           :ok <- Rest.validate_credentials(opts_credentials(request_opts)) do
        # `MovePortfolioFundsResponse` (at-spec.yaml:7934) is the two uuids and nothing else. A
        # `funds` echo was a field a consumer could come to read that the venue never sends.
        {:ok,
         %{
           "source_portfolio_uuid" => from,
           "target_portfolio_uuid" => to
         }}
      end
    end)
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

  # A private read or write: the injected outcome first, as everywhere, then the credential
  # check `Rest` runs before it builds any request. This fake had no credential check at
  # all (see the moduledoc), so a consumer that forgot its credentials saw its tests pass and
  # production answer `{:error, {:missing_credentials, :coinbase}}`.
  defp with_credentials(credentials, symbol \\ nil, fun) do
    with_injection(symbol, fn ->
      with :ok <- Rest.validate_credentials(credentials), do: fun.()
    end)
  end

  # Where the facade carries no credential argument, it reads `opts[:credentials]` and
  # defaults to `%{}` — which `Rest` treats as none.
  defp opts_credentials(opts), do: Keyword.get(opts, :credentials, %{})

  # The spelling `Rest` sends: `SymbolFormat.to_exchange_symbol/1`, which upper-cases and
  # nothing more. `btc-usd` is the product `BTC-USD`; `BTC/USD` is not a pair it can split
  # and is refused by the venue as unlisted, so it is here too. A non-string is left as it
  # is and matches nothing.
  defp native(symbol) when is_binary(symbol), do: SymbolFormat.to_exchange_symbol(symbol)
  defp native(symbol), do: symbol

  defp with_injection(symbol \\ nil, fun) do
    case FakeInjection.next_outcome(:coinbase, symbol) do
      {:override, outcome} -> outcome
      :none -> fun.()
    end
  end

  # Upper-cased on the way in, as the real facade does, so a lower-case subscription gets
  # the same answer here as against the venue. Without it the fake delivered nothing for
  # `btc-usd` while the real package delivered `BTC-USD` (checked 2026-09-28).
  defp canonical_case(symbols) when is_list(symbols),
    do: Enum.map(symbols, fn s -> if is_binary(s), do: String.upcase(s), else: s end)

  defp canonical_case(other), do: other
end

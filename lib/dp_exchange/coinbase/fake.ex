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
  real function. The checks themselves are `Rest`'s (`order_plan/2`,
  `validate_order_edit/1`, `validate_candle_request/3`, ...), called rather than re-stated, so
  the two cannot drift. This fake used to inspect no credential at all, so a consumer that
  forgot them saw green tests and a production `:missing_credentials`.

  Public market data (`get_price/2`, `get_order_book/2`, `get_trades/2`, ...) needs none, as on
  the venue; `get_top_of_book/2` is the one public-shaped call that does.
  """

  @behaviour DpExchange.Core.Venue

  alias DpExchange.Coinbase.{Feed, IdempotencyKey, OptionKeys, Prime, Rest, SymbolFormat}
  alias DpExchange.Core.{Capabilities, Config, FakeInjection, Fanout, Instrument, Types, Venue}

  @symbols ~w(BTC-USD BTC-USDC ETH-USD ETH-EUR)

  # The most levels a side of the fake's book carries, whatever `:depth` asks for.
  @max_book_depth 50

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

  @doc """
  A child spec for this fake; `opts[:name]` or this module is the child id.

  `start_link/1` returns `:ignore`, so nothing is started. See
  `c:DpExchange.Core.Venue.child_spec/1`.
  """
  @impl true
  def child_spec(opts),
    do: %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}

  @doc """
  Starts nothing and answers `:ignore`: this fake keeps its state in the calling process.

  See `c:DpExchange.Core.Venue.start_link/1`.
  """
  @impl true
  def start_link(_opts), do: :ignore

  @doc """
  The real venue's display name, `DpExchange.Coinbase.provider_name/0`.

  See `c:DpExchange.Core.Venue.provider_name/0`.
  """
  @impl true
  def provider_name, do: DpExchange.Coinbase.provider_name()

  @doc """
  The real venue's runtime id, `DpExchange.Coinbase.runtime_id/0`.

  See `c:DpExchange.Core.Venue.runtime_id/0`.
  """
  @impl true
  def runtime_id, do: DpExchange.Coinbase.runtime_id()

  @doc """
  The real venue's asset classes, `DpExchange.Coinbase.asset_classes/0`.

  See `c:DpExchange.Core.Venue.asset_classes/0`.
  """
  @impl true
  def asset_classes, do: DpExchange.Coinbase.asset_classes()

  # The real declaration, deliberately. A fake declaring different capabilities from the
  # venue it stands in for is a fake a consumer cannot use to test capability branching.
  @doc """
  The real venue's declaration, `DpExchange.Coinbase.capabilities/0`, unchanged.

  See `c:DpExchange.Core.Venue.capabilities/0`.
  """
  @impl true
  def capabilities, do: DpExchange.Coinbase.capabilities()

  @doc """
  In-memory price for a listed symbol (`BTC-USD`, `BTC-USDC`, `ETH-USD`, `ETH-EUR`);
  `{:refused, :not_listed}` for any other. A credential is optional but must be well formed
  if given.

  See `c:DpExchange.Core.Venue.get_price/2`.
  """
  @impl true
  def get_price(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      # As `Rest.get_price/2`: the symbol, then a credential only if one was given — it is
      # signed with when present, so a malformed one is refused rather than read as none.
      with :ok <- Rest.validate_symbol(symbol),
           :ok <- OptionKeys.check(:get_price, opts),
           :ok <- Rest.validate_optional_credentials(Keyword.get(opts, :credentials)) do
        fake_quote(symbol)
      end
    end)
  end

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
  @doc """
  In-memory best bid and ask with sizes. Needs a credential, as the venue does: without one
  it answers `{:error, {:missing_credentials, :coinbase}}`.

  See `c:DpExchange.Core.Venue.get_top_of_book/2`.
  """
  @impl true
  def get_top_of_book(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      # `Rest`'s own test, so `%{}` — which the real path reads as no credential — refuses
      # here too. This checked only `nil`, and a consumer passing `%{}` got a book.
      # `Rest.get_top_of_book/2` checks the symbol before the credential.
      with :ok <- Rest.validate_symbol(symbol),
           :ok <- OptionKeys.check(:get_top_of_book, opts),
           :ok <- Rest.validate_credentials(Keyword.get(opts, :credentials)) do
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

  @doc """
  One in-memory candle, kept or dropped by the real range rules. A timeframe the venue does
  not serve (including `12h`) or an over-wide range is refused locally, as on the venue.

  See `c:DpExchange.Core.Venue.get_historical_prices/4`.
  """
  @impl true
  def get_historical_prices(symbol, timeframe, range \\ [], opts \\ []) do
    with_injection(symbol, fn ->
      # The real path's order: the timeframe, the symbol's shape, then the options and the
      # window, all refused locally before any request, so they win over an unlisted symbol
      # (which only the venue can name). The check is `Rest`'s own — this used to re-state it
      # and answered `:not_listed` first. `12h`, which the shared vocabulary models and
      # Coinbase does not serve, fails here.
      with :ok <- Rest.validate_timeframe(timeframe),
           :ok <- Rest.validate_symbol(symbol),
           :ok <- Rest.validate_candle_request(timeframe, range, opts) do
        if native(symbol) in @symbols do
          # A bar, not a quote. The fake returned `get_price/2`'s `Quote` here, which agreed
          # with the real package's own defect — a suite reproducing the bug it is meant to
          # catch. Through `Rest.select_candles/4`, so the fake's one bar is kept or dropped
          # by the same range and forming-bar rules (MD1, MD2) as the venue's.
          {:ok, Rest.select_candles([fake_candle(symbol, timeframe)], timeframe, range, opts)}
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

  @doc """
  The four symbols this fake carries: `BTC-USD`, `BTC-USDC`, `ETH-USD`, `ETH-EUR`.

  See `c:DpExchange.Core.Venue.get_symbols/1`.
  """
  @impl true
  def get_symbols(opts \\ []) do
    # As `Rest.fetch_products/1`: a credential, when given, is signed with, so a malformed
    # one is refused rather than read as none.
    with_injection(fn ->
      with :ok <- OptionKeys.check(:get_symbols, opts),
           :ok <- Rest.validate_optional_credentials(Keyword.get(opts, :credentials)),
           do: {:ok, @symbols}
    end)
  end

  @doc """
  An in-memory book around the symbol's price: `opts[:depth]` levels (default 3, at most 50)
  a side, bids descending and asks ascending, with no sequence.

  See `c:DpExchange.Core.Venue.get_order_book/2`.
  """
  @impl true
  def get_order_book(symbol, opts \\ []),
    do: with_injection(symbol, fn -> fake_order_book(symbol, opts) end)

  # The real path's order: the options are refused locally, before any request, so they win
  # over an unlisted symbol (which only the venue can name). The check is `Rest`'s own.
  defp fake_order_book(symbol, opts) do
    with :ok <- Rest.validate_symbol(symbol),
         :ok <- Rest.validate_book_options(opts) do
      case Map.fetch(@price, native(symbol)) do
        {:ok, price} ->
          # `Rest` accepts any depth up to the spec's `int32`, and the venue answers with the
          # levels it has: a book is never as deep as the number asked for. This built one
          # level per step of `:depth`, so `depth: 2_000_000_000` (valid) never returned.
          # Capped at what a real book plausibly holds; fewer than asked is an ordinary reply.
          depth = min(Keyword.get(opts, :depth) || 3, @max_book_depth)
          {:ok, fake_book(symbol, Decimal.new(price), depth)}

        :error ->
          {:refused, :not_listed}
      end
    end
  end

  defp fake_book(symbol, mid, depth) do
    %Types.OrderBook{
      symbol: symbol,
      # Descending bids, ascending asks — the venue's own ordering, and the sizes
      # differ per level so a caller reading only the top learns it is reading a book.
      bids: book_side(mid, depth, :sub),
      asks: book_side(mid, depth, :add),
      venue_time: @at,
      observed_at: @at,
      # The venue publishes no sequence on this endpoint, so neither does the fake: a
      # caller must not learn to detect stream gaps from a REST book.
      sequence: nil,
      provider: :coinbase
    }
  end

  @doc """
  Two in-memory prints, oldest first, at most `opts[:limit]` of them. `opts[:limit]` is
  required, as on the venue; `:since` and `:end` narrow the window.

  See `c:DpExchange.Core.Venue.get_trades/2`.
  """
  @impl true
  def get_trades(symbol, opts \\ []) do
    with_injection(symbol, fn ->
      # The real package refuses locally when `opts[:limit]` is absent — the venue's
      # `limit` query param is `required: true`
      # (docs/reference/coinbase/openapi/at-spec.yaml:523-528) and documents no default. A
      # fake that answered anyway would let a consumer's suite go green on a call the real
      # venue refuses. `Rest.trades_options/1` is that check (the limit, then `:since` and
      # `:end`), called rather than re-stated.
      with :ok <- Rest.validate_symbol(symbol),
           {:ok, limit, since, finish} <- Rest.trades_options(opts) do
        trades_for(symbol, limit, since, finish)
      end
    end)
  end

  # Oldest first, as `Rest.get_trades/2` returns them (it sorts by the venue's own time), and
  # at most `limit` of them, the newest. This returned the newest first, so a consumer reading
  # `List.last/1` as "the latest print" passed here and failed against the venue.
  #
  # `:since` (inclusive) and `:end` (exclusive) narrow the window as the venue's `start` and
  # `end` do; a `:since` read that fills the page may have a hole, as `Rest.get_trades/2`
  # reports it (MD4).
  defp trades_for(symbol, limit, since, finish) do
    case Map.fetch(@price, native(symbol)) do
      {:ok, price} ->
        in_window =
          symbol
          |> tape(price)
          |> Enum.filter(&since_or_later?(&1, since))
          |> Rest.trades_before(finish)

        if since != nil and length(in_window) >= limit,
          do: {:error, :history_truncated},
          else: {:ok, Enum.take(in_window, -limit)}

      :error ->
        {:refused, :not_listed}
    end
  end

  defp since_or_later?(%Types.Trade{timestamp: at}, since),
    do: is_nil(since) or DateTime.compare(at, since) != :lt

  defp tape(symbol, price) do
    # More than one print, because the whole point of the tape is that get_price/2
    # keeps only the newest and this does not.
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
    ]
  end

  defp book_side(mid, depth, direction) do
    # `//1`: a depth of 0 makes `1..0` a descending range. `Rest` refuses a depth below 1, so
    # this is never reached with one, and stays an empty range if it ever is.
    for step <- 1..depth//1 do
      offset = Decimal.mult(Decimal.new("0.50"), Decimal.new(step))
      price = if direction == :sub, do: Decimal.sub(mid, offset), else: Decimal.add(mid, offset)
      {price, Decimal.mult(Decimal.new("0.1"), Decimal.new(step))}
    end
  end

  @doc """
  An in-memory snapshot (price, 24h change, volume, high/low, status) for each carried symbol.

  See `c:DpExchange.Core.Venue.get_market_overview/1`.
  """
  @impl true
  def get_market_overview(opts \\ []) do
    with_injection(fn ->
      with :ok <- OptionKeys.check(:get_market_overview, opts),
           :ok <- Rest.validate_optional_credentials(Keyword.get(opts, :credentials)) do
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
      end
    end)
  end

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_auction_imbalance/2`.
  """
  @impl true
  def get_auction_imbalance(_symbol, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_volume_profile/3`.
  """
  @impl true
  def get_volume_profile(_symbol, _timeframe, _opts \\ []), do: Venue.not_supported()

  @doc """
  The carried symbols as spot `DpExchange.Core.Instrument` structs, all `:tradable`.

  See `c:DpExchange.Core.Venue.list_instruments/1`.
  """
  @impl true
  def list_instruments(opts \\ []) do
    with_injection(fn ->
      with :ok <- OptionKeys.check(:list_instruments, opts),
           :ok <- Rest.validate_optional_credentials(Keyword.get(opts, :credentials)) do
        {:ok, Enum.map(@symbols, &fake_instrument/1)}
      end
    end)
  end

  defp fake_instrument(symbol) do
    [base, quote_asset] = String.split(symbol, "-")

    Instrument.new(
      symbol: symbol,
      base: base,
      quote: quote_asset,
      instrument: :spot,
      status: :tradable
    )
  end

  @doc """
  Two in-memory balances (BTC with a non-zero hold, and USD). Needs a credential; another
  `opts[:portfolio]` than the default holds nothing.

  See `c:DpExchange.Core.Venue.get_balances/2`.
  """
  @impl true
  def get_balances(credentials, opts) do
    with_checks(credentials, Rest.validate_balance_options(opts), fn ->
      # A held amount that is not zero, so a consumer reading `available_balance` as the
      # total fails here rather than in production. The real venue reports both and no total.
      available = Decimal.new("1.25")
      hold = Decimal.new("0.25")

      balances = [
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
      ]

      # `opts[:portfolio]` scopes the read (`retail_portfolio_id`); see `in_portfolio?/1`.
      {:ok, if(in_portfolio?(opts), do: balances, else: [])}
    end)
  end

  @doc """
  One in-memory account record in the venue's own shape. `opts[:uuid]` reads it by id; an
  unknown id is `{:refused, :not_found}`. Needs a credential.

  See `c:DpExchange.Core.Venue.get_accounts/2`.
  """
  @impl true
  def get_accounts(credentials, opts) do
    with_checks(credentials, Rest.validate_account_options(opts), fn ->
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
        nil -> {:ok, if(in_portfolio?(opts), do: accounts, else: [])}
        "8bfc20d7-f7c6-4422-bf07-8243ca4169fe" -> {:ok, accounts}
        # An id the venue does not hold. `{:ok, []}` would read as "this account has nothing".
        # The venue answers 404, which `Rest` classifies `{:refused, :not_found}`.
        _unknown -> {:refused, :not_found}
      end
    end)
  end

  @doc """
  An in-memory fee summary with a promotion running, so the promotional and non-promotional
  tiers differ. Needs a credential.

  See `c:DpExchange.Core.Venue.get_fees/2`.
  """
  @impl true
  def get_fees(credentials, opts) do
    with_checks(credentials, Rest.validate_summary_filters(opts), fn ->
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

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_transfers/2`.
  """
  @impl true
  def get_transfers(_credentials, _opts), do: Venue.not_supported()
  # Both refused, matching the real venue. A fake that answered where the real one
  # refuses lets a consumer's suite go green against behaviour that cannot happen.

  @doc """
  A `FILL` and a `REVERSAL` row; only `FILL` comes back unless `opts[:trade_types]` says
  otherwise. `:order_id`, `:symbol`, `:start` and `:end` narrow the rows. Needs a credential.

  See `c:DpExchange.Core.Venue.get_trade_history/2`.
  """
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

  # Everything this fake holds belongs to its one default portfolio. `opts[:portfolio]` is
  # honoured as the real reads honour it (the spec's `retail_portfolio_id`): another
  # portfolio holds nothing here, rather than being ignored and handed this one's rows.
  defp in_portfolio?(opts), do: Keyword.get(opts, :portfolio) in [nil, @default_portfolio_id]

  defp fill_matches?(fill, opts) do
    in_portfolio?(opts) and
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
  defp after_start?(at, %DateTime{} = start), do: DateTime.compare(at, start) != :lt

  # `Rest.validate_fill_filters/1` has already refused any bound that is not a `DateTime`, so
  # there is no "unreadable bound" to wave through here.
  defp before_end?(_at, nil), do: true
  defp before_end?(at, %DateTime{} = finish), do: DateTime.compare(at, finish) == :lt

  # Streaming, in memory. The fake pushes immediately on subscribe, which is what the
  # real venue's first tick does from the caller's side — and the caller cannot tell the
  # difference, which is the property the facade exists to hold.
  #
  # `opts[:channels]` mirrors `DpExchange.Coinbase.Feed`'s `:channels` (see its moduledoc's
  # "`:trades` is opt-in" section), per call here because this fake has no connection to
  # configure. Each kind named is pushed per carried symbol and no other: `:quotes` a
  # `Types.Quote`, `:trades` a `Types.Trade`, `:order_book` a `Types.OrderBook` snapshot (never
  # a delta), so `channels: [:trades]` pushes no quote, as the real feed opens only
  # `market_trades` then. The default is `[:quotes]`, and `coverage_by_kind/1` reports only
  # the kinds a call actually pushed.
  @doc """
  Pushes at once, to `opts[:to]` (default the caller), one message per carried symbol for each
  kind in `opts[:channels]` (default `[:quotes]`), and unions the symbols into the subscription.

  Symbols are upper-cased and refused as `DpExchange.Coinbase.Feed` refuses them. See
  `c:DpExchange.Core.Venue.subscribe/2`.
  """
  @impl true
  def subscribe(symbols, opts \\ []) do
    symbols = canonical_case(symbols)

    # Refused as `Feed.subscribe/3` refuses, in the same order: symbols, options, then
    # subscriber. `:channels` is this fake's own documented seam (the real feed takes it at
    # start, not here). An unknown `:channels` kind raises when a real Feed starts; this has
    # no start step, so it is refused here, before anything is pushed.
    with :ok <- Feed.check_symbols(symbols),
         :ok <- DpExchange.Core.Options.check(opts, [:channels | OptionKeys.allowed(:subscribe)]),
         channels = Config.opt(opts, :channels, [:quotes]),
         {:ok, target} <- Feed.valid_subscriber(Config.opt(opts, :to, self())),
         :ok <- Feed.check_channels(channels) do
      do_subscribe(symbols, target, channels)
    end
  end

  # What the real stream pushes (MD7): a rolling 24-hour volume, and no `venue_time`, because
  # a `ticker` row states no trade time and the envelope's is a send time.
  defp streamed_quote(%Types.Quote{} = quote_struct),
    do: %{quote_struct | volume_window: :rolling_24h, venue_time: nil}

  defp do_subscribe(symbols, target, channels) do
    for symbol <- symbols, symbol in @symbols do
      # `channels: [:trades]` opens `market_trades` and nothing else on the real feed, so a
      # quote is pushed (and covered, below) only when `:quotes` was asked for.
      with true <- :quotes in channels,
           # The real stream's volume is `volume_24_h`, a rolling total, where `get_price/2`'s
           # is one print — so the pushed quote says what the real one says.
           {:ok, quote_struct} <- fake_quote(symbol) do
        deliver(target, {:dp_exchange, :coinbase, streamed_quote(quote_struct)})
      end

      if :trades in channels, do: deliver(target, {:dp_exchange, :coinbase, trade_for(symbol)})

      # The level2 channel opens with a snapshot, which this fake pushed none of, so a
      # consumer's book handling had nothing to run against. Deltas are not modelled.
      if :order_book in channels do
        with {:ok, book} <- fake_order_book(symbol, []),
             do: deliver(target, {:dp_exchange, :coinbase, book})
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
    if :quotes in channels do
      Process.put(
        __MODULE__,
        MapSet.union(subscribed(), MapSet.new(Enum.filter(symbols, &(&1 in @symbols))))
      )
    end

    :ok
  end

  @doc """
  Removes the named symbols from every subscribed kind (quotes, trades, order book).

  See `c:DpExchange.Core.Venue.unsubscribe/2`.
  """
  @impl true
  def unsubscribe(symbols, opts \\ []) do
    symbols = canonical_case(symbols)

    with :ok <- Feed.check_symbols(symbols),
         :ok <- OptionKeys.check(:unsubscribe, opts) do
      Process.put(__MODULE__, MapSet.difference(subscribed(), MapSet.new(symbols)))
      Process.put(@trades_key, MapSet.difference(subscribed_trades(), MapSet.new(symbols)))
      Process.put(@order_book_key, MapSet.difference(subscribed_books(), MapSet.new(symbols)))
      :ok
    end
  end

  @doc """
  Replaces the subscription's symbol set. A symbol it adds gets a quote pushed to the caller;
  trade and order-book subscriptions are only narrowed, never widened.

  See `c:DpExchange.Core.Venue.update_symbols/2`.
  """
  @impl true
  def update_symbols(symbols, opts \\ []) do
    symbols = canonical_case(symbols)

    with :ok <- Feed.check_symbols(symbols),
         :ok <- OptionKeys.check(:update_symbols, opts) do
      do_update_symbols(symbols)
    end
  end

  defp do_update_symbols(symbols) do
    wanted = MapSet.new(Enum.filter(symbols, &(&1 in @symbols)))

    # A symbol this adds is pushed for, as `subscribe/2` pushes, so `coverage/1` never
    # answers `:stream` for one that delivered nothing. To the caller, with the default
    # channel: the contract's callback takes neither a `to:` nor `:channels` (2026-10-10).
    added = MapSet.difference(wanted, all_subscribed())

    for symbol <- added do
      with {:ok, quote_struct} <- fake_quote(symbol),
           do: send(self(), {:dp_exchange, :coinbase, streamed_quote(quote_struct)})
    end

    # A symbol subscribed only for trades or the book does not gain quote coverage here.
    Process.put(__MODULE__, MapSet.union(MapSet.intersection(subscribed(), wanted), added))
    # Narrowed, never widened: `update_symbols/2` carries no `:channels`, so a symbol it
    # adds cannot be assumed to want trades.
    Process.put(@trades_key, MapSet.intersection(subscribed_trades(), wanted))
    Process.put(@order_book_key, MapSet.intersection(subscribed_books(), wanted))
    :ok
  end

  # Observed, not intended — the fake models the real rule rather than shortcutting it.
  # It reports only symbols it actually pushed for, so a consumer testing the
  # subscribed-but-not-delivering case gets the same shape the real venue would give.
  @doc """
  `:stream` for every symbol this process subscribed (any kind) and pushed for.

  See `c:DpExchange.Core.Venue.coverage/1`.
  """
  @impl true
  def coverage(opts \\ []) do
    OptionKeys.check!(:coverage, opts)
    Map.new(all_subscribed(), &{&1, :stream})
  end

  @doc """
  The symbols this process subscribed (any kind), sorted. The fake carries four symbols and
  ignores any other, so a symbol it never carried is not wanted here either.

  See `DpExchange.Coinbase.wanted/1`.
  """
  @spec wanted(keyword()) :: [String.t()]
  @impl true
  def wanted(opts \\ []) do
    OptionKeys.check!(:wanted, opts)
    all_subscribed() |> MapSet.to_list() |> Enum.sort()
  end

  @doc """
  `coverage/1`, split by kind — see `DpExchange.Coinbase.coverage_by_kind/1`.

  `subscribe/2` pushes, for every carried symbol, what `opts[:channels]` names (the default
  is `[:quotes]`): a `DpExchange.Core.Types.Quote` for `:quotes`, a
  `DpExchange.Core.Types.Trade` for `:trades` and a `DpExchange.Core.Types.OrderBook`
  snapshot for `:order_book`, and nothing for a kind not named, as the real feed opens
  only the channels it was given. It never pushes an `OrderBookDelta`. A kind appears here
  only for the symbols a `subscribe/2` call actually pushed it for, and a kind with no
  symbols is omitted — the same "only what arrived" rule the real `Feed` follows. Claiming a kind this fake never
  sent would be the "differently capable" divergence this module's own moduledoc forbids.
  """
  @impl true
  @spec coverage_by_kind(keyword()) :: %{Capabilities.data_kind() => %{String.t() => atom()}}
  def coverage_by_kind(opts \\ []) do
    OptionKeys.check!(:coverage_by_kind, opts)
    # A kind appears only once something of it was pushed, as before for `:trades`.
    # Every kind, `:quotes` included, is omitted while empty — the real feed's rule.
    [quotes: subscribed(), trades: subscribed_trades(), order_book: subscribed_books()]
    |> Enum.reject(fn {_kind, symbols} -> MapSet.size(symbols) == 0 end)
    |> Map.new(fn {kind, symbols} -> {kind, Map.new(symbols, &{&1, :stream})} end)
  end

  @doc """
  Registers `opts[:to]` (default the caller) for notices and sends nothing: the real feed
  announces no `:link_up` on registration either.

  See `c:DpExchange.Core.Venue.subscribe_notices/1`.
  """
  @impl true
  def subscribe_notices(opts \\ []) do
    # Registers and sends nothing: the real feed announces no `:link_up` on registration
    # (only on an actual link change), so a consumer's test must not see one either.
    with :ok <- Feed.validate_subscribe_options(opts),
         {:ok, _target} <- Feed.valid_subscriber(Config.opt(opts, :to, self())),
         do: :ok
  end

  # As the real `Core.Fanout` delivers: a pid that is gone, or an atom naming no registered
  # process, is nobody and skipped — `send/2` to an unregistered atom raises ArgumentError.
  defp deliver(target, message) do
    case Fanout.resolve(target) do
      nil -> :ok
      pid -> send(pid, message)
    end

    :ok
  end

  defp subscribed, do: Process.get(__MODULE__, MapSet.new())

  # Any kind: `coverage/1` is "what is delivering", whichever channel carries it.
  defp all_subscribed do
    subscribed() |> MapSet.union(subscribed_trades()) |> MapSet.union(subscribed_books())
  end

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

  @doc """
  Reachability without a credential; with one, the key's permissions (`can_view`,
  `can_trade`, `can_transfer: false`). A credential that cannot sign is refused.

  See `c:DpExchange.Core.Venue.test_connection/2`.
  """
  @impl true
  def test_connection(credentials, opts) do
    with_injection(fn ->
      with :ok <- OptionKeys.check(:test_connection, opts), do: connection_status(credentials)
    end)
  end

  # With a credential the fake answers what the key can do; without one it answers
  # reachability only, which is the same split the package makes. A credential that
  # cannot sign (`%{api_key: "k"}`) is not "none" — the real path reads
  # `/key_permissions` with it and fails signing, so it refuses here too.
  defp connection_status(credentials) when credentials in [nil, %{}],
    do: {:ok, %{"reachable" => true, "time" => %{"iso" => "2026-09-01T20:00:00Z"}}}

  defp connection_status(credentials) do
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

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_rate_limit_status/2`.
  """
  @impl true
  def get_rate_limit_status(_credentials, _opts), do: Venue.not_supported()

  @doc """
  Always `{:ok, :open}`, as on the real venue.

  See `c:DpExchange.Core.Venue.market_status/1`.
  """
  @impl true
  def market_status(opts) do
    with_injection(fn ->
      with :ok <- OptionKeys.check(:market_status, opts), do: {:ok, :open}
    end)
  end

  @doc """
  In-memory increments and limits for a carried symbol; the price and quantity increments
  differ on purpose. `{:refused, :not_listed}` for any other.

  See `c:DpExchange.Core.Venue.quantization/1`.
  """
  @impl true
  def quantization(symbol) do
    with_injection(symbol, fn ->
      # `Rest.get_product/2` upper-cases the symbol it sends, so `btc-usd` is listed here too.
      with :ok <- Rest.validate_symbol(symbol) do
        if Map.has_key?(@price, native(symbol)) do
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
    end)
  end

  # --- The wider surface: futures, staking, conversion, portfolios, and the unsupported ----
  #
  # Core 0.1.16 widened the facade to the surface the venues actually publish. The callbacks
  # below that `DpExchange.Coinbase` declares `:unsupported` answer `{:error, :not_supported}`
  # here as there, so a consumer routing on the declaration is told the truth; the rest are
  # modelled in memory.
  #
  # **`:unsupported` can mean the venue's absence or this package's backlog.** That
  # distinction is the one Phase 1 had to correct after a package spent a year asserting a
  # venue had no streaming API when it had fifteen services. `DpExchange.Coinbase`'s
  # `venue_does_not_serve/0` is the first kind. Where the venue genuinely does not offer
  # something, the comment beside it says so.

  @doc """
  One in-memory short futures position with a `nil` `realised_pnl`. Needs a credential in
  `opts[:credentials]`; `opts[:portfolio]` is refused, as the futures endpoints take none.

  See `c:DpExchange.Core.Venue.get_positions/1`.
  """
  @impl true
  def get_positions(opts \\ []) do
    # The futures endpoints take no portfolio scope; refused, as the real read refuses it.
    with :ok <- Rest.reject_portfolio_option(:get_positions, opts) do
      do_get_positions(opts)
    end
  end

  defp do_get_positions(opts) do
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

  @doc """
  Not served by this package: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_funding/2`.
  """
  @impl true
  def get_funding(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this package: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_contract_stats/2`.
  """
  @impl true
  def get_contract_stats(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_staking_rates/1`.
  """
  @impl true
  def get_staking_rates(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_staking_balances/1`.
  """
  @impl true
  def get_staking_balances(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_staking_rewards/1`.
  """
  @impl true
  def get_staking_rewards(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_staking_history/1`.
  """
  @impl true
  def get_staking_history(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  An in-memory stake. Refuses what the real path refuses: no `opts[:portfolio_id]` is
  `{:error, :missing_portfolio}`, Prime credentials are required, and the same
  `DpExchange.Coinbase.Prime` write checks run. A reused idempotency key answers the same
  transaction.

  See `c:DpExchange.Core.Venue.stake/3`.
  """
  @impl true
  def stake(asset, amount, opts \\ []), do: fake_staking(:stake, asset, amount, opts)

  @doc """
  An in-memory unstake, checked as `stake/3` is. Reports nothing paid: `amount_remaining` is
  the whole amount.

  See `c:DpExchange.Core.Venue.unstake/3`.
  """
  @impl true
  def unstake(asset, amount, opts \\ []), do: fake_staking(:unstake, asset, amount, opts)

  # Returns the `Types.StakingTransaction` the real facade returns (W5), built by the same
  # function. Refuses, in the real path's order, what the real path refuses: a portfolio or
  # nothing (a fake that defaulted one would let a consumer ship a stake into a portfolio it
  # never named), the ids, then `Prime.validate_write/3` (asset in BOTH scopes, the amount and
  # its 64-place bound, a UUID idempotency key, a map `:extra`), then Prime's three credentials
  # — without the last, a consumer's test staked with no Prime key and production refused it.
  #
  # The transaction id is derived from the idempotency key, so a unique key (generated when
  # the caller gives none) is a unique transaction and a REUSED key answers with the original,
  # as the venue's "subsequent requests using the same key will not create new transactions".
  #
  # This fake has no wallet inventory, so the real path's wallet-asset check
  # (`{:wallet_asset_mismatch, _, _}`) cannot be modelled: a wallet is taken to hold the asset
  # named. An unstake reports nothing paid (`amount_remaining` is the whole amount), because
  # one that reported itself settled would teach a consumer to spend an asset still unbonding.
  defp fake_staking(type, asset, amount, opts) do
    with_injection(fn ->
      with :ok <- Prime.validate_positional(asset, amount),
           :ok <- Prime.validate_stake_options(opts),
           {:ok, portfolio} <- fake_portfolio(opts),
           :ok <- Prime.validate_scope(portfolio, Keyword.get(opts, :wallet_id)),
           :ok <- Prime.validate_write(asset, amount, opts),
           :ok <- fake_prime_credentials(opts) do
        key = Keyword.get(opts, :idempotency_key) || IdempotencyKey.generate()
        body = %{"transaction_id" => "fake-#{type}-#{key}"}
        Prime.to_staking_transaction(body, type, asset, amount, key)
      end
    end)
  end

  defp fake_prime_credentials(opts) do
    if prime_credentials?(Keyword.get(opts, :credentials)),
      do: :ok,
      else: {:error, :missing_prime_credentials}
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

  @doc """
  An in-memory `:quoted` conversion with a fresh id and no expiry, remembered so a later
  commit or read finds it. Needs a credential.

  See `c:DpExchange.Core.Venue.quote_conversion/4`.
  """
  @impl true
  def quote_conversion(from, to, amount, opts \\ []) do
    checked =
      with :ok <- Rest.validate_conversion_quote(from, to, amount),
           do: OptionKeys.check(:quote_conversion, opts)

    with_checks(opts_credentials(opts), checked, fn ->
      # `:quoted`, and no expiry — the two things a consumer must handle. A fake that returned
      # `:settled` would let one ship code that never commits.
      # Remembered, so a commit or a read names a conversion this fake actually quoted. A new
      # id per quote, as the venue issues: one fixed id made a second quote overwrite the
      # state of a first that had been committed.
      id = "convert-" <> Integer.to_string(map_size(conversions()) + 1)
      Process.put(@conversions_key, Map.put(conversions(), id, :quoted))

      {:ok,
       %Types.Conversion{
         id: id,
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

  @doc """
  Commits a conversion this fake quoted; an unknown id is `{:refused, :not_found}`.
  `opts[:from]` and `opts[:to]` are required, as on the venue.

  See `c:DpExchange.Core.Venue.commit_conversion/2`.
  """
  @impl true
  def commit_conversion(id, opts \\ []) do
    with_injection(fn ->
      # Both accounts or nothing, as in the package: committing against accounts the caller
      # did not name converts between the wrong two balances. Then the credential, then the
      # venue's own answer about the id — the real order.
      with :ok <- Rest.validate_id(id, :trade_id),
           {:ok, from, to} <- Rest.convert_accounts(opts),
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

  @doc """
  A conversion's state: still `:quoted`, or `:settled` once committed here. An unknown id is
  `{:refused, :not_found}`; `opts[:from]` and `opts[:to]` are required.

  See `c:DpExchange.Core.Venue.get_conversion/2`.
  """
  @impl true
  def get_conversion(id, opts \\ []) do
    with_injection(fn ->
      with :ok <- Rest.validate_id(id, :trade_id),
           {:ok, from, to} <- Rest.convert_accounts(opts),
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

  # **An id this fake never quoted is the venue's 404**, `{:refused, :not_found}` from
  # `Rest`'s `classify/1`. Every id used to commit and read back `:settled`, so a consumer's
  # test could commit a conversion it never quoted and pass (found 2026-10-10).
  defp fake_conversion(id) do
    case Map.fetch(conversions(), id) do
      {:ok, status} -> {:ok, status}
      :error -> {:refused, :not_found}
    end
  end

  defp conversions, do: Process.get(@conversions_key, %{})

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.convert/4`.
  """
  @impl true
  def convert(_from, _to, _amount, _opts \\ []), do: Venue.not_supported()

  @doc """
  An in-memory spot volume row, with the Advanced Trade and Pro totals beside the breakdown
  rather than folded into it. Needs a credential.

  See `c:DpExchange.Core.Venue.get_trade_volume/2`.
  """
  @impl true
  def get_trade_volume(credentials, opts \\ []) do
    with_checks(credentials, Rest.validate_summary_filters(opts), fn ->
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

  @doc """
  A live portfolio and a deleted one, since the venue keeps deleted ones in the listing.
  Needs a credential in `opts[:credentials]`.

  See `c:DpExchange.Core.Venue.list_portfolios/1`.
  """
  @impl true
  def list_portfolios(opts \\ []) do
    with_checks(opts_credentials(opts), Rest.validate_portfolio_filter(opts), fn ->
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

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_deposit_address/3`.
  """
  @impl true
  def get_deposit_address(_asset, _network, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.list_approved_addresses/1`.
  """
  @impl true
  def list_approved_addresses(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.estimate_withdrawal_fee/4`.
  """
  @impl true
  def estimate_withdrawal_fee(_asset, _network, _amount, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.withdraw/5`.
  """
  @impl true
  def withdraw(_asset, _network, _amount, _address, _opts \\ []),
    do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_option_chain/2`.
  """
  @impl true
  def get_option_chain(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_option_expirations/2`.
  """
  @impl true
  def get_option_expirations(_underlying, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_option_greeks/2`.
  """
  @impl true
  def get_option_greeks(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.list_watchlists/1`.
  """
  @impl true
  def list_watchlists(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_watchlist/2`.
  """
  @impl true
  def get_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.create_watchlist/3`.
  """
  @impl true
  def create_watchlist(_name, _symbols, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.update_watchlist/2`.
  """
  @impl true
  def update_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.delete_watchlist/2`.
  """
  @impl true
  def delete_watchlist(_id, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_financials/3`.
  """
  @impl true
  def get_financials(_symbol, _kind, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_corporate_events/1`.
  """
  @impl true
  def get_corporate_events(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_filings/2`.
  """
  @impl true
  def get_filings(_symbol, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_news/1`.
  """
  @impl true
  def get_news(_opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_screener/2`.
  """
  @impl true
  def get_screener(_name, _opts \\ []), do: DpExchange.Core.Venue.not_supported()

  @doc """
  Creates an in-memory portfolio (this venue's sub-account) named `opts[:name]`, which is
  required. Needs a credential.

  See `c:DpExchange.Core.Venue.create_account/1`.
  """
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

  @doc """
  Renames a portfolio in memory; only the name changes. Needs a credential.

  See `c:DpExchange.Core.Venue.rename_account/3`.
  """
  @impl true
  def rename_account(id, name, opts \\ []) do
    checked =
      with :ok <- Rest.validate_portfolio_rename(id, name),
           do: OptionKeys.check(:rename_account, opts)

    with_checks(opts_credentials(opts), checked, fn ->
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

  @doc """
  An in-memory key-permissions map: `can_view` and `can_trade` true, `can_transfer` false,
  with the default portfolio. Needs a credential.

  See `c:DpExchange.Core.Venue.get_roles/1`.
  """
  @impl true
  def get_roles(opts \\ []) do
    with_checks(opts_credentials(opts), OptionKeys.check(:get_roles, opts), fn ->
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

  # --- The facade's non-callback surface: futures, Prime staking, portfolio reads, the clock ----
  #
  # Every function below is on `DpExchange.Coinbase` and so must be here: a consumer testing
  # against this fake must never meet an `UndefinedFunctionError` that the real package would not
  # raise (`test/dp_exchange/coinbase/tick_ai_fake_parity_test.exs` asserts the two export the
  # same name/arity set). Each one runs the injected outcome first, then the real function's own
  # argument checks (`Rest.validate_*` / `Prime.validate_*`, called and not re-stated), then the
  # credential, then answers with the shape the vendor spec documents
  # (`docs/reference/coinbase/openapi/`). Amounts are the spec's `{value, currency, cbrn}` object.

  @futures_product "BIT-28JUL23-CDE"
  @fake_wallet_address "0x8f3e1b7c2d4a69f05e1c3b7a9d2f4e6081a3c5d7"
  @fake_validator "0xa1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
  @sweeps_key {__MODULE__, :sweeps}
  @margin_setting_key {__MODULE__, :margin_setting}
  @default_margin_setting "INTRADAY_MARGIN_SETTING_STANDARD"

  @doc """
  The venue's own futures position rows, unnormalised: one short with `daily_realized_pnl`
  and `expiration_time`. Needs a credential in `opts[:credentials]`; `opts[:portfolio]` is
  refused, as the futures endpoints take none.

  See `DpExchange.Coinbase.list_futures_positions/1`.
  """
  @spec list_futures_positions(keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_futures_positions(opts) do
    checked = Rest.reject_portfolio_option(:list_futures_positions, opts)

    with_checks(opts_credentials(opts), checked, fn ->
      {:ok, [futures_position_row()]}
    end)
  end

  @doc """
  The one in-memory futures position by product id; any other product is
  `{:refused, :not_listed}`, as the venue's 404 is. Needs a credential.

  See `DpExchange.Coinbase.get_futures_position/3`.
  """
  @spec get_futures_position(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_futures_position(credentials, product_id, opts) do
    with_checks(credentials, Rest.validate_futures_position(product_id, opts), fn ->
      if product_id == @futures_product,
        do: {:ok, futures_position_row()},
        else: {:refused, :not_listed}
    end)
  end

  defp futures_position_row do
    %{
      "product_id" => @futures_product,
      "expiration_time" => "2023-07-28T15:00:00Z",
      "side" => "SHORT",
      "number_of_contracts" => "3",
      "current_price" => "29500",
      "avg_entry_price" => "30000",
      "unrealized_pnl" => "1500",
      "daily_realized_pnl" => "0"
    }
  end

  @doc """
  An in-memory futures balance summary, every amount the spec's `{value, currency, cbrn}`
  object. Needs a credential.

  See `DpExchange.Coinbase.get_futures_balance_summary/2`.
  """
  @spec get_futures_balance_summary(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_futures_balance_summary(credentials, opts) do
    checked = Rest.reject_portfolio_option(:get_futures_balance_summary, opts)

    with_checks(credentials, checked, fn ->
      {:ok,
       %{
         "futures_buying_power" => usd("9000"),
         "total_usd_balance" => usd("10000"),
         "cbi_usd_balance" => usd("4000"),
         "cfm_usd_balance" => usd("6000"),
         "total_open_orders_hold_amount" => usd("0"),
         "unrealized_pnl" => usd("1500"),
         "daily_realized_pnl" => usd("0"),
         "initial_margin" => usd("1000"),
         "available_margin" => usd("9000"),
         "liquidation_threshold" => usd("500"),
         "liquidation_buffer_amount" => usd("8500"),
         "liquidation_buffer_percentage" => "94.4"
       }}
    end)
  end

  defp usd(value), do: %{"value" => value, "currency" => "USD", "cbrn" => ""}

  @doc """
  The sweeps this process scheduled and has not cancelled (none to begin with, as the venue
  reports an empty queue). Needs a credential.

  See `DpExchange.Coinbase.list_futures_sweeps/2`.
  """
  @spec list_futures_sweeps(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_futures_sweeps(credentials, opts) do
    checked = Rest.reject_portfolio_option(:list_futures_sweeps, opts)

    with_checks(credentials, checked, fn ->
      {:ok, Process.get(@sweeps_key, [])}
    end)
  end

  @doc """
  Schedules a `PENDING` sweep, remembered so `list_futures_sweeps/2` reports it. Omitting
  `opts[:usd_amount]` sweeps everything (`should_sweep_all: true`), as the venue does; a
  present amount is checked by `Rest.validate_sweep_amount/1`. Needs a credential.

  See `DpExchange.Coinbase.schedule_futures_sweep/2`.
  """
  @spec schedule_futures_sweep(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def schedule_futures_sweep(credentials, opts) do
    with_injection(fn ->
      with {:ok, amount} <- Rest.validate_sweep_amount(opts),
           :ok <- Rest.validate_credentials(credentials) do
        sweeps = Process.get(@sweeps_key, [])
        Process.put(@sweeps_key, sweeps ++ [sweep_row(length(sweeps) + 1, amount)])
        {:ok, %{"success" => true}}
      end
    end)
  end

  defp sweep_row(number, amount) do
    base = %{
      "id" => "fake-sweep-#{number}",
      "should_sweep_all" => is_nil(amount),
      "status" => "PENDING",
      "scheduled_time" => DateTime.to_iso8601(@at)
    }

    if amount, do: Map.put(base, "requested_amount", usd(amount)), else: base
  end

  @doc """
  Cancels *the* pending sweep, which the venue does without an id: the oldest one this process
  scheduled. With none pending the answer is `{:refused, :sweep_not_cancelled}`, the venue's
  `success: false` read as the real path reads it. Needs a credential.

  See `DpExchange.Coinbase.cancel_futures_sweep/2`.
  """
  @spec cancel_futures_sweep(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def cancel_futures_sweep(credentials, opts) do
    checked = Rest.reject_portfolio_option(:cancel_futures_sweep, opts)

    with_checks(credentials, checked, fn ->
      case Process.get(@sweeps_key, []) do
        [] ->
          {:refused, :sweep_not_cancelled}

        [_cancelled | remaining] ->
          Process.put(@sweeps_key, remaining)
          {:ok, %{"success" => true}}
      end
    end)
  end

  @doc """
  The margin setting last set in this process, else `INTRADAY_MARGIN_SETTING_STANDARD`.
  Needs a credential.

  See `DpExchange.Coinbase.get_intraday_margin_setting/2`.
  """
  @spec get_intraday_margin_setting(map(), keyword()) ::
          {:ok, String.t()} | {:error, term()} | {:refused, term()}
  def get_intraday_margin_setting(credentials, opts) do
    checked = Rest.reject_portfolio_option(:get_intraday_margin_setting, opts)

    with_checks(credentials, checked, fn ->
      {:ok, Process.get(@margin_setting_key, @default_margin_setting)}
    end)
  end

  @doc """
  Sets the margin setting for this process after `Rest.validate_margin_setting/1`; the venue
  answers an empty object. Needs a credential.

  See `DpExchange.Coinbase.set_intraday_margin_setting/3`.
  """
  @spec set_intraday_margin_setting(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def set_intraday_margin_setting(credentials, setting, opts) do
    checked =
      with :ok <- Rest.validate_margin_setting(setting),
           do: Rest.reject_portfolio_option(:set_intraday_margin_setting, opts)

    with_checks(credentials, checked, fn ->
      Process.put(@margin_setting_key, setting)
      {:ok, %{}}
    end)
  end

  @doc """
  An in-memory overnight margin window with both kill switches off. Checks
  `opts[:margin_profile_type]` as the real call does. Needs a credential.

  See `DpExchange.Coinbase.get_current_margin_window/2`.
  """
  @spec get_current_margin_window(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_current_margin_window(credentials, opts) do
    with_checks(credentials, Rest.validate_margin_window_options(opts), fn ->
      {:ok,
       %{
         "margin_window" => %{
           "margin_window_type" => "MARGIN_WINDOW_TYPE_OVERNIGHT",
           "end_time" => @at |> DateTime.add(3600, :second) |> DateTime.to_iso8601()
         },
         "is_intraday_margin_killswitch_enabled" => false,
         "is_intraday_margin_enrollment_killswitch_enabled" => false
       }}
    end)
  end

  @doc """
  One in-memory portfolio's breakdown for the portfolios `list_portfolios/1` names; any
  other uuid is `{:refused, :not_found}`. Needs a credential.

  See `DpExchange.Coinbase.get_portfolio_breakdown/3`.
  """
  @spec get_portfolio_breakdown(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_portfolio_breakdown(credentials, portfolio_uuid, opts) do
    with_checks(credentials, Rest.validate_portfolio_breakdown(portfolio_uuid, opts), fn ->
      case portfolio_row(portfolio_uuid) do
        nil ->
          {:refused, :not_found}

        row ->
          {:ok,
           %{
             "portfolio" => row,
             "portfolio_balances" => %{
               "total_balance" => usd("10000"),
               "total_futures_balance" => usd("0"),
               "total_cash_equivalent_balance" => usd("2500"),
               "total_crypto_balance" => usd("7500")
             },
             "spot_positions" => [],
             "perp_positions" => [],
             "futures_positions" => []
           }}
      end
    end)
  end

  @doc """
  Deletes a live in-memory portfolio (the default one, or the one `create_account/1` makes) and
  answers the venue's empty object; any other uuid, a deleted one included, is
  `{:refused, :not_found}`. Needs a credential. Nothing is remembered: the next
  `list_portfolios/1` still lists what it always lists.

  See `DpExchange.Coinbase.delete_portfolio/3`.
  """
  @spec delete_portfolio(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def delete_portfolio(credentials, portfolio_uuid, opts) do
    checked =
      with :ok <- Rest.validate_id(portfolio_uuid, :portfolio_uuid),
           do: OptionKeys.check(:delete_portfolio, opts)

    with_checks(credentials, checked, fn ->
      if portfolio_uuid in [@default_portfolio_id, @new_portfolio_id],
        do: {:ok, %{}},
        else: {:refused, :not_found}
    end)
  end

  defp portfolio_row(@default_portfolio_id),
    do: portfolio_map(@default_portfolio_id, "Default", "DEFAULT", false)

  defp portfolio_row(@retired_portfolio_id),
    do: portfolio_map(@retired_portfolio_id, "Retired", "CONSUMER", true)

  defp portfolio_row(@new_portfolio_id),
    do: portfolio_map(@new_portfolio_id, "New", "CONSUMER", false)

  defp portfolio_row(_unknown), do: nil

  defp portfolio_map(uuid, name, type, deleted),
    do: %{"name" => name, "uuid" => uuid, "type" => type, "deleted" => deleted}

  @doc """
  The venue's clock, fixed (never the local one). Public: needs no credential.

  See `DpExchange.Coinbase.get_server_time/1`.
  """
  @spec get_server_time(keyword()) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_server_time(opts \\ []) do
    with_injection(fn ->
      with :ok <- OptionKeys.check(:get_server_time, opts) do
        {:ok,
         %{
           "iso" => DateTime.to_iso8601(@at),
           "epochSeconds" => Integer.to_string(DateTime.to_unix(@at)),
           "epochMillis" => Integer.to_string(DateTime.to_unix(@at, :millisecond))
         }}
      end
    end)
  end

  @doc """
  The endpoints the venue itself does not serve, `DpExchange.Coinbase.venue_does_not_serve/0`,
  unchanged.

  See `DpExchange.Coinbase.venue_does_not_serve/0`.
  """
  @spec venue_does_not_serve() :: [{atom(), arity()}]
  def venue_does_not_serve, do: DpExchange.Coinbase.venue_does_not_serve()

  @doc """
  One in-memory validator association per requested transaction id. Refuses what
  `Prime.validate_validators_query/2` refuses, then needs Prime credentials.

  See `DpExchange.Coinbase.query_transaction_validators/3`.
  """
  @spec query_transaction_validators(Prime.credentials(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def query_transaction_validators(credentials, portfolio_id, opts \\ []) do
    checked = Prime.validate_validators_query(portfolio_id, opts)

    with_prime_checks(credentials, checked, fn ->
      {:ok,
       %{
         "transaction_validators" =>
           Enum.map(Config.opt(opts, :transaction_ids, []), fn id ->
             %{
               "transaction_id" => id,
               "validator_address" => @fake_validator,
               "validator_status" => "VALIDATOR_STATUS_ACTIVE"
             }
           end),
         "pagination" => %{"next_cursor" => "", "sort_direction" => "DESC", "has_next" => false}
       }}
    end)
  end

  @doc """
  One in-memory validator with a top-up stake in progress for the wallet named. Refuses
  what `Prime.validate_wallet_scope/2` refuses, then needs Prime credentials.

  See `DpExchange.Coinbase.staking_status/4`.
  """
  @spec staking_status(Prime.credentials(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def staking_status(credentials, portfolio_id, wallet_id, opts \\ []) do
    checked = Prime.validate_wallet_read(:staking_status, portfolio_id, wallet_id, opts)

    with_prime_checks(credentials, checked, fn ->
      {:ok,
       wallet_status(portfolio_id, wallet_id, [
         %{
           "validator_address" => @fake_validator,
           "statuses" => [
             %{
               "amount" => "16",
               "stake_type" => "STAKE_TYPE_TOP_UP",
               "estimated_stake_date" => "2026-09-27T00:00:00Z",
               "estimated_hours_to_stake" => 672,
               "requested_at" => "2026-08-28T12:00:00Z"
             }
           ]
         }
       ])}
    end)
  end

  @doc """
  One in-memory validator with a partial redemption still unbonding: the answer that says a
  redemption is not finished. Refuses what `Prime.validate_wallet_scope/2` refuses, then needs
  Prime credentials.

  See `DpExchange.Coinbase.unstake_status/4`.
  """
  @spec unstake_status(Prime.credentials(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def unstake_status(credentials, portfolio_id, wallet_id, opts \\ []) do
    checked = Prime.validate_wallet_read(:unstake_status, portfolio_id, wallet_id, opts)

    with_prime_checks(credentials, checked, fn ->
      {:ok,
       wallet_status(portfolio_id, wallet_id, [
         %{
           "validator_address" => @fake_validator,
           "statuses" => [
             %{
               "amount" => "16",
               "unstake_type" => "UNSTAKE_TYPE_PARTIAL",
               "finishing_at" => "2026-09-27T00:00:00Z",
               "remaining_hours" => 672,
               "requested_at" => "2026-08-28T12:00:00Z",
               "estimate_type" => "LIVE",
               "estimate_description" => "Live estimate based on current network conditions"
             }
           ]
         }
       ])}
    end)
  end

  defp wallet_status(portfolio_id, wallet_id, validators) do
    %{
      "portfolio_id" => portfolio_id,
      "wallet_id" => wallet_id,
      "wallet_address" => @fake_wallet_address,
      "current_timestamp" => DateTime.to_iso8601(@at),
      "validators" => validators
    }
  end

  @doc """
  Claims in memory: answers the wallet, a transaction id and an activity id derived from the
  idempotency key (`opts[:idempotency_key]`, else a generated one). Refuses what
  `Prime.validate_claim/3` refuses, then needs Prime credentials.

  See `DpExchange.Coinbase.claim_rewards/4`.
  """
  @spec claim_rewards(Prime.credentials(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def claim_rewards(credentials, portfolio_id, wallet_id, opts \\ []) do
    with_prime_checks(credentials, Prime.validate_claim(portfolio_id, wallet_id, opts), fn ->
      key = Keyword.get(opts, :idempotency_key) || IdempotencyKey.generate()

      {:ok,
       %{
         "wallet_id" => wallet_id,
         "transaction_id" => "fake-claim-#{key}",
         "activity_id" => "fake-activity-#{key}"
       }}
    end)
  end

  @doc """
  What an unstake of `amount` would do, in memory: one validator carrying the whole amount.
  Refuses what `Prime.validate_preview_unstake/4` refuses (the asset is not checked, as in the
  real call), then needs Prime credentials. Nothing is reserved.

  See `DpExchange.Coinbase.preview_unstake_wallet/6`.
  """
  @spec preview_unstake_wallet(
          Prime.credentials(),
          String.t(),
          String.t(),
          String.t(),
          Decimal.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def preview_unstake_wallet(credentials, portfolio_id, wallet_id, _asset, amount, opts \\ []) do
    checked = Prime.validate_preview_unstake(portfolio_id, wallet_id, amount, opts)

    with_prime_checks(credentials, checked, fn ->
      estimated = Decimal.to_string(amount, :normal)

      {:ok,
       %{
         "estimated_amount" => estimated,
         "wallet_id" => wallet_id,
         "wallet_address" => @fake_wallet_address,
         "current_timestamp" => DateTime.to_iso8601(@at),
         "validators" => [
           %{
             "validator_address" => @fake_validator,
             "estimated_unstaking_amount" => estimated,
             "unstake_time_estimate_in_hours" => 672.0,
             "estimated_unstake_date" => "2026-09-27T00:00:00Z"
           }
         ]
       }}
    end)
  end

  # `with_checks/3` for the Prime calls: the credential is Prime's triple (an access key, a
  # passphrase and a signing key), not the CDP key pair, and the answer to a missing one is
  # `{:error, :missing_prime_credentials}`, as `Prime` gives it after its own argument checks.
  defp with_prime_checks(credentials, checked, fun) do
    with_injection(fn ->
      with :ok <- checked do
        if prime_credentials?(credentials),
          do: fun.(),
          else: {:error, :missing_prime_credentials}
      end
    end)
  end

  @doc """
  Places an in-memory order after the real package's own request and credential checks.
  The order is remembered, so a later read or cancel finds it. A repeated caller-supplied
  `client_order_id` answers the original order, as the venue does.

  See `c:DpExchange.Core.Venue.place_order/3`.
  """
  @impl true
  def place_order(credentials, request, opts \\ []) do
    with_injection(fn ->
      # The fake accepts what the venue accepts and refuses what it refuses, by running the
      # real package's own checks in its order (`Rest.order_plan/2`: request, keys, symbol,
      # side, type, time-in-force, quantity, price fields, `client_order_id`), then the
      # credential. It builds the order from the plan, so the side is the atom the real path
      # returns (not the caller's `"buy"`) and the amounts are the real path's Decimals.
      with {:ok, plan} <- Rest.order_plan(request, :place),
           :ok <- OptionKeys.check(:place_order, opts),
           :ok <- Rest.validate_credentials(credentials) do
        place_planned(plan)
      end
    end)
  end

  # **The venue is idempotent on `client_order_id`**: re-sending a used id creates no second
  # order and returns the original. A caller-supplied id seen before answers the order it
  # first placed; a generated id is new every time.
  defp place_planned(%{client_order_id_supplied?: true, client_order_id: id} = plan) do
    case Map.fetch(client_orders(), id) do
      {:ok, original} -> {:ok, original}
      :error -> plan |> create_order() |> remember_client_order(id)
    end
  end

  defp place_planned(plan), do: create_order(plan)

  defp create_order(plan) do
    placed = %Types.Order{
      id: next_order_id(),
      symbol: plan.symbol,
      side: plan.side,
      order_type: plan.order_type,
      time_in_force: plan.time_in_force,
      quantity: plan.quantity,
      price: plan.price,
      stop_price: plan.stop_price,
      status: :pending,
      provider: :coinbase
    }

    # Remembered (per process) as the working order a later read finds: placed, not
    # filled. `get_order/3`, `get_orders/2` and `cancel_order/3` answer from this, so a
    # place -> read -> cancel -> read test sees the order it placed, as on the venue.
    remember_order(%{placed | status: :open, filled_quantity: Decimal.new("0")})
    {:ok, placed}
  end

  @client_orders_key {__MODULE__, :client_orders}

  defp client_orders, do: Process.get(@client_orders_key, %{})

  defp remember_client_order({:ok, placed} = result, client_order_id) do
    Process.put(@client_orders_key, Map.put(client_orders(), client_order_id, placed))
    result
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

  # Only called after `Rest.validate_order_edit/2` has passed, which requires both `price` and
  # `quantity` present and a finite positive integer, `Decimal` or numeric string — exactly
  # what `Decimal.cast/1` accepts. A `nil` or uncastable value cannot arrive here, and the
  # match fails loudly rather than substituting `nil` if that ever changes.
  defp cast_decimal(value) do
    {:ok, decimal} = Decimal.cast(value)
    decimal
  end

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.place_orders/3`.
  """
  @impl true
  def place_orders(_credentials, _requests, _opts), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.cancel_all_orders/2`.
  """
  @impl true
  def cancel_all_orders(_credentials, _opts \\ []), do: Venue.not_supported()

  @doc """
  Cancels an open order this fake holds. An order that is not open, or an unknown id, is
  `{:refused, {:cancel_rejected, reason}}`. Needs a credential.

  See `c:DpExchange.Core.Venue.cancel_order/3`.
  """
  @impl true
  def cancel_order(credentials, order_id, opts \\ []) do
    checked =
      with :ok <- Rest.validate_order_id(order_id), do: OptionKeys.check(:cancel_order, opts)

    with_checks(credentials, checked, fn ->
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

  @doc """
  An order this process placed, or the one canned order `"fake-order-1"`; any other id is
  `{:refused, :not_found}`. Needs a credential.

  See `c:DpExchange.Core.Venue.get_order/3`.
  """
  @impl true
  def get_order(credentials, order_id, opts \\ []) do
    checked = with :ok <- Rest.validate_order_id(order_id), do: OptionKeys.check(:get_order, opts)

    with_checks(credentials, checked, fn ->
      case find_order(order_id) do
        {:ok, order} -> {:ok, order}
        # The venue's 404, which `Rest` classifies `{:refused, :not_found}` (`:not_listed`
        # is for symbols only).
        :error -> {:refused, :not_found}
      end
    end)
  end

  # `:status` and `:symbol` narrow the list as the real package's venue-side filters do.
  # They were ignored, so a caller asking for FILLED orders or ETH-USD's was handed the one
  # open BTC-USD order — the "plausible answer to a question not asked" this fake must not give.
  @doc """
  The canned order plus those this process placed, narrowed by `opts[:status]` (one or a
  list) and `opts[:symbol]`. Needs a credential.

  See `c:DpExchange.Core.Venue.get_orders/2`.
  """
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
          in_portfolio?(opts) and
            status_matches?(Keyword.get(opts, :status), order.status) and
            matches?(canonical_symbol(Keyword.get(opts, :symbol)), order.symbol)
        end)

      {:ok, matching}
    end)
  end

  defp status_matches?(nil, _actual), do: true

  # `Rest.get_orders/2` takes one status or a list (`status: [:open, :pending]`) and the venue
  # answers the union, so a list matches when any member does. It raised
  # `FunctionClauseError` here, in the consumer's test process.
  defp status_matches?(wanted, actual) when is_list(wanted),
    do: Enum.any?(wanted, &status_matches?(&1, actual))

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

  @doc """
  A fixed in-memory preview, after the same request and credential checks `place_order/3`
  runs. Nothing is placed or remembered.

  See `c:DpExchange.Core.Venue.preview_order/3`.
  """
  @impl true
  def preview_order(credentials, request, opts \\ []) do
    with_injection(fn ->
      # The same request checks `place_order/3` runs, then the credential — as the real path.
      with {:ok, plan} <- Rest.order_plan(request, :preview),
           :ok <- OptionKeys.check(:preview_order, opts),
           :ok <- Rest.validate_credentials(credentials) do
        {:ok,
         %{
           order_total: Decimal.new("20000.00"),
           commission_total: Decimal.new("10.00"),
           base_size: plan.quantity,
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

  @doc """
  Edits a working order's price and size, both required as on the venue. An id this fake
  never issued is `{:refused, :not_found}`. Needs a credential.

  See `c:DpExchange.Core.Venue.replace_order/4`.
  """
  @impl true
  def replace_order(credentials, order_id, changes, opts \\ []) do
    with_injection(fn ->
      # The fake enforces the venue's edit surface: price and size only, both required. A fake
      # that accepted a side change, or only one of the two, would let a consumer's test pass
      # on an edit the real venue refuses — `EditOrderRequest` declares order_id, price AND
      # size all required (docs/reference/coinbase/openapi/at-spec.yaml:6809-6852), the same
      # requirement `Rest.replace_order/4` enforces — and `Rest`'s own check is what runs.
      with :ok <- Rest.validate_order_edit(order_id, changes),
           :ok <- OptionKeys.check(:replace_order, opts),
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
            {:refused, :not_found}
        end
      end
    end)
  end

  @doc """
  A fixed in-memory pricing of an edit, with the same price-and-size requirement as
  `replace_order/4`. Nothing is changed.

  See `c:DpExchange.Core.Venue.preview_replace/4`.
  """
  @impl true
  def preview_replace(credentials, order_id, changes, opts \\ []) do
    with_injection(fn ->
      # The same edit surface replace_order/4 enforces — price and size, both required.
      # Anything less is an edit the venue refuses, and a fake that priced it would let a
      # consumer's suite go green on a call that cannot be made.
      with :ok <- Rest.validate_order_edit(order_id, changes),
           :ok <- OptionKeys.check(:preview_replace, opts),
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

  @doc """
  Places an in-memory closing market order with a `nil` side, as the real package returns.
  Needs a credential.

  See `c:DpExchange.Core.Venue.close_position/3`.
  """
  @impl true
  def close_position(credentials, symbol, opts \\ []) do
    with_checks(credentials, symbol, Rest.validate_close_request(symbol, opts), fn ->
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

  @doc """
  Two in-memory payment methods, one verified for deposit only. Needs a credential.

  See `c:DpExchange.Core.Venue.list_payment_methods/2`.
  """
  @impl true
  def list_payment_methods(credentials, opts \\ []) do
    with_checks(credentials, OptionKeys.check(:list_payment_methods, opts), fn ->
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

  @doc """
  An in-memory payment method echoing `id`. Needs a credential.

  See `c:DpExchange.Core.Venue.get_payment_method/3`.
  """
  @impl true
  def get_payment_method(credentials, id, opts \\ []) do
    checked =
      with :ok <- Rest.validate_id(id, :payment_method_id),
           do: OptionKeys.check(:get_payment_method, opts)

    with_checks(credentials, checked, fn ->
      {:ok, %{"id" => id, "type" => "ACH", "verified" => true, "allow_withdraw" => false}}
    end)
  end

  @doc """
  Moves funds between two portfolios in memory, answering the two uuids as the venue does.
  `opts[:from]` and `opts[:to]` are required; the credential is read from `request_opts`.

  See `c:DpExchange.Core.Venue.transfer_internal/4`.
  """
  @impl true
  def transfer_internal(asset, amount, opts, request_opts) do
    with_injection(fn ->
      # The amount, the asset and both uuids, or nothing. A fake that defaulted one would let a
      # consumer ship a move between portfolios it never named. Merged and read as the facade
      # does (`opts` over `request_opts`), then the credential from `request_opts` — the real
      # order.
      merged = OptionKeys.merge(request_opts, opts)

      with {:ok, from, to} <- Rest.validate_transfer(asset, amount, merged),
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

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.add_payment_method/2`.
  """
  @impl true
  def add_payment_method(_details, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.request_approved_address/4`.
  """
  @impl true
  def request_approved_address(_asset, _network, _address, _opts \\ []),
    do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.remove_approved_address/3`.
  """
  @impl true
  def remove_approved_address(_network, _address, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.list_networks/2`.
  """
  @impl true
  def list_networks(_asset, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_transactions/2`.
  """
  @impl true
  def get_transactions(_credentials, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.list_fee_promos/1`.
  """
  @impl true
  def list_fee_promos(_opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_fx_rate/3`.
  """
  @impl true
  def get_fx_rate(_pair, _at, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.get_notional_balances/3`.
  """
  @impl true
  def get_notional_balances(_credentials, _currency, _opts \\ []), do: Venue.not_supported()

  @doc """
  Not served by this venue: answers `{:error, :not_supported}`, as `DpExchange.Coinbase` does.
  See `c:DpExchange.Core.Venue.list_custody_fees/2`.
  """
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

  # `with_credentials/3` for a call whose real function checks its arguments first.
  # `checked` is the (pure) result of the `Rest.validate_*` the real path runs before it builds
  # any request: the injected outcome still comes first, then the local checks, then the
  # credential, then the answer — the real order, and each from the real function's own check.
  defp with_checks(credentials, symbol \\ nil, checked, fun) do
    with_injection(symbol, fn ->
      with :ok <- checked, :ok <- Rest.validate_credentials(credentials) do
        fun.()
      end
    end)
  end

  # Where the facade carries no credential argument, it reads `opts[:credentials]` and
  # defaults to `%{}` — which `Rest` treats as none.
  # Options that are not a keyword list carry none; the option check that runs beside this
  # refuses them as `{:invalid_options, v}`.
  defp opts_credentials(opts) when is_list(opts), do: Keyword.get(opts, :credentials, %{})
  defp opts_credentials(_not_a_list), do: %{}

  # The spelling `Rest` sends: `SymbolFormat.to_exchange_symbol/1`, which upper-cases and
  # nothing more. `btc-usd` is the product `BTC-USD`; `BTC/USD` is not a pair it can split
  # and is refused by the venue as unlisted, so it is here too. Every caller has already
  # passed `Rest.validate_symbol/1` (or filters `subscribe` input to listed binaries), so
  # the argument is always a string; a non-string would fail loudly here, not match nothing.
  defp native(symbol) when is_binary(symbol), do: SymbolFormat.to_exchange_symbol(symbol)

  defp with_injection(symbol \\ nil, fun) do
    case FakeInjection.next_outcome(:coinbase, symbol) do
      {:override, outcome} -> outcome
      :none -> fun.()
    end
  end

  # Upper-cased on the way in, as the real facade does, so a lower-case subscription gets
  # the same answer here as against the venue. Without it the fake delivered nothing for
  # `btc-usd` while the real package delivered `BTC-USD` (checked 2026-09-28).
  # Walks the list itself: `Enum.map/2` raises on an improper list, which
  # `Feed.check_symbols/1` refuses.
  defp canonical_case([symbol | rest]) when is_binary(symbol),
    do: [String.upcase(symbol) | canonical_case(rest)]

  defp canonical_case([other | rest]), do: [other | canonical_case(rest)]
  defp canonical_case(other), do: other
end

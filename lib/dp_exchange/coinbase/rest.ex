defmodule DpExchange.Coinbase.Rest do
  @moduledoc """
  Coinbase Advanced Trade REST — internal. Nothing here is public API; the facade is
  `DpExchange.Coinbase`.

  ## Credentials choose the endpoint, they do not gate it

  Coinbase serves the same market data two ways: `/products/{id}/ticker` is
  account-scoped and needs a Bearer JWT, `/market/products/{id}/ticker` is public. This
  module picks the authenticated path when it is given credentials and the public one
  when it is not.

  That is the facade's rule made concrete — a caller passes credentials or does not, and
  reads the consequence from `capabilities/0`. It is also a fix for a real incident: the
  price-collection task did not pass credentials, hit the authenticated path anyway, and
  produced **315 Unauthorized warnings overnight** on 2026-04-30.

  ## Historical candles: public without a credential, authenticated with one

  `/market/products/{id}/candles` needs no auth, and is what a caller without a credential
  reads. Since 2026-09-01 a caller holding one reads `/products/{id}/candles` (see
  `get_historical_prices/4`). History, kept because it is why the public path exists: until
  2026-07-02 every credentialed backfill call `401`ed on the authenticated path. This
  section said that still held until it was checked against the code on 2026-10-10. The
  authenticated path has not been probed since, because doing so needs a credential this
  repository never holds.

  ## This module cannot fabricate

  There is no fallback path, no test-mode branch and no hardcoded price table. A request
  that fails returns an error. The adapter this was ported from had a
  `generate_fallback_candles/4` that invented OHLC from a table of base prices; its error
  path was fixed in May 2026 after fabricated candles were traced to phantom profits in
  backtests, but the generator survived behind a node-wide test flag. It is not here in
  any form — see `docs/reference/coinbase/reconciliation.md`.

  A caller wanting deterministic candles uses this package's fake, selected **per
  process**, which is a real implementation of the facade rather than a branch inside the
  live one.
  """

  alias DpExchange.Coinbase.{Auth, IdempotencyKey, SymbolFormat}
  alias DpExchange.Core.{Config, HttpClient, Instrument, Timeframe, Types}

  require Logger

  @base_url "https://api.coinbase.com"
  @api_path "/api/v3/brokerage"

  # Coinbase encodes granularity as a symbolic enum, not a seconds integer. Prior code
  # sent `granularity=86400` and the API rejected it silently.
  #
  # There is no `_other ->` clause and there must never be one. It carried
  # `-> "ONE_HOUR"`, so a caller asking for four-hour candles received one-hour bars that
  # the backfill then wrote tagged `timeframe: "4h"` — every value real, every label
  # wrong. That mattered on 2026-08-04, when the fee-clearing edge was at 4h.
  #
  # There is no safe substitute for a width the venue does not serve, and the venue
  # agrees: measured 2026-08-28, an unrecognised enum is refused outright with
  # `parsing field "granularity": "THREE_HOUR" is not a valid value` — not empty, which
  # is what this adapter's comment used to claim, and not a nearby width.
  @granularities %{
    "1m" => "ONE_MINUTE",
    "5m" => "FIVE_MINUTE",
    "15m" => "FIFTEEN_MINUTE",
    "30m" => "THIRTY_MINUTE",
    "1h" => "ONE_HOUR",
    "2h" => "TWO_HOUR",
    "4h" => "FOUR_HOUR",
    "6h" => "SIX_HOUR",
    "1d" => "ONE_DAY"
  }

  # Measured 2026-08-28: 350 minutes of ONE_MINUTE returns 349 candles; 351 returns
  # ZERO with `INVALID_ARGUMENT`. It is a refusal, not a truncation, so a caller that
  # widens its window to fetch more in one call gets nothing — and nothing reads as
  # "no data for this period".
  @max_candles 350

  # The spec's `int32` ceiling for a `limit` parameter.
  @max_int32 2_147_483_647
  @max_int64 9_223_372_036_854_775_807

  @doc "Every timeframe Coinbase serves, shortest first."
  @spec granularities() :: [String.t()]
  def granularities, do: @granularities |> Map.keys() |> Enum.sort_by(&timeframe_seconds/1)

  @doc "The most candles Coinbase will return for one request. A hard boundary, not a hint."
  @spec max_candles() :: pos_integer()
  def max_candles, do: @max_candles

  @doc """
  The current price for `symbol`.

  Returns `{:refused, reason}` when the venue does not carry the symbol — a permanent
  answer, distinct from a transient `{:error, _}`.

  Sends the ticker's `limit=1` — `limit` is `required: true` on this endpoint
  (docs/reference/coinbase/openapi/at-spec.yaml:523-528, :2636-2641), and this used to send
  none at all. `to_quote/2` reads only the newest of the returned trades, so `1` is the
  smallest value that still serves this call rather than an arbitrary one.
  """
  @spec get_price(String.t(), keyword()) ::
          {:ok, Types.Quote.t()} | {:error, term()} | {:refused, term()}
  def get_price(symbol, opts) do
    with :ok <- validate_symbol(symbol) do
      native = symbol |> SymbolFormat.to_exchange_symbol() |> segment()
      credentials = opts_credentials(opts)

      path =
        if credentials,
          do: "/products/#{native}/ticker",
          else: "/market/products/#{native}/ticker"

      case request(:get, path, credentials, opts, %{"limit" => 1}) do
        {:ok, %{body: body}} -> to_quote(body, symbol)
        {:error, reason} -> classify(reason, :symbol)
      end
    end
  end

  @doc """
  Historical candles for `symbol` at `timeframe`.

  A timeframe Coinbase does not serve is an **error**, never the nearest width.

  ## The range, the forming bar and `:limit` (family conventions MD1, MD2, MD4)

    * `range[:start]` is **inclusive** and `range[:end]` **exclusive**, both on `opened_at`.
      The venue's own treatment of the two bounds is unmeasured, so the reply is filtered
      client-side to make the rule exact for a bound the caller gave. An absent `:end` is
      now, and an absent `:start` is a default window of 300 bars (neither is filtered on).
    * The bar still forming (`opened_at + width > now`) is **not returned** unless
      `opts[:include_partial]` is `true`. With it, the last bar is returned as the venue
      sent it and may still change; `Core.Types.Candle` has no flag for that.
    * `opts[:limit]` (an integer 1..350, the spec's `limit`, whose default and maximum are
      both 350) is sent to the venue, one higher (up to 350) when the forming bar is withheld,
      and the newest `limit` closed bars are returned, so `limit: 1` is the latest closed bar
      rather than `[]`. At `limit: 350` the forming bar still takes a slot and 349 may come
      back. Anything else is
      `{:error, {:invalid_option, :limit, v}}`. An `:include_partial` that is not a boolean
      is `{:error, {:invalid_option, :include_partial, v}}`.
  """
  @spec get_historical_prices(String.t(), String.t(), keyword(), keyword()) ::
          {:ok, [Types.Candle.t()]} | {:error, term()} | {:refused, term()}
  def get_historical_prices(symbol, timeframe, range, opts) do
    with {:ok, enum} <- granularity_enum(timeframe),
         {:ok, params} <- candle_params(timeframe, range, enum, opts),
         :ok <- validate_symbol(symbol) do
      native = symbol |> SymbolFormat.to_exchange_symbol() |> segment()

      # The venue publishes the same candles twice: `/market/products/…` unauthenticated
      # and `/products/…` for a credential. Reading the public one while holding a
      # credential would silently forgo whatever the authenticated view adds.
      credentials = opts_credentials(opts)

      path =
        if credentials,
          do: "/products/#{native}/candles",
          else: "/market/products/#{native}/candles"

      case request(:get, path, credentials, opts, params) do
        {:ok, %{body: body}} -> decode_candles(body, symbol, timeframe, range, opts)
        {:error, reason} -> classify(reason, :symbol)
      end
    end
  end

  defp decode_candles(body, symbol, timeframe, range, opts) do
    with {:ok, bars} <- to_candles(body, symbol, timeframe) do
      {:ok, select_candles(bars, timeframe, range, opts)}
    end
  end

  @doc """
  Applies the family's range and forming-bar rules to decoded bars: a bar is kept when its
  `opened_at` is at or after `range[:start]` (when given), strictly before `range[:end]`
  (when given), and, unless `opts[:include_partial]` is `true`, when it has closed
  (`opened_at + width <= now`). `opts[:limit]` then keeps the newest that many.

  Shared by `get_historical_prices/4` and `DpExchange.Coinbase.Fake`, so the two cannot
  drift. `range` and `opts` must already have passed `validate_candle_request/3`.
  """
  @spec select_candles([Types.Candle.t()], String.t(), keyword(), keyword()) ::
          [Types.Candle.t()]
  def select_candles(bars, timeframe, range, opts) do
    width = timeframe_seconds(timeframe)
    now = DateTime.utc_now()
    partial? = Keyword.get(opts, :include_partial) == true
    start = Keyword.get(range, :start)
    finish = Keyword.get(range, :end)

    kept =
      Enum.filter(bars, fn %{opened_at: at} ->
        (partial? or DateTime.compare(DateTime.add(at, width, :second), now) != :gt) and
          (is_nil(start) or DateTime.compare(at, start) != :lt) and
          (is_nil(finish) or DateTime.compare(at, finish) == :lt)
      end)

    # `bars` are oldest first; a `:limit` keeps the newest that many.
    case Keyword.get(opts, :limit) do
      limit when is_integer(limit) -> Enum.take(kept, -limit)
      _none -> kept
    end
  end

  @doc """
  Every **SPOT** product Coinbase lists, as canonical symbols.

  Not every product: Advanced Trade also lists FUTURE, EQUITY, OPTION_GROUP and
  FUTURE_GROUP products, none of which `fetch_products/1` requests — see that function's
  comment for why SPOT is the honest scope for this package to claim rather than a wider
  list it cannot correctly trade.
  """
  @spec get_symbols(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def get_symbols(opts) do
    with {:ok, products} <- fetch_products(opts) do
      {:ok, Enum.map(products, &SymbolFormat.to_canonical_symbol(&1["product_id"]))}
    end
  end

  @doc """
  A bulk snapshot across every **SPOT** product Coinbase lists: price, 24h change, 24h
  volume, 24h high/low and status, one entry per canonical symbol.

  Reads the same bulk endpoint `get_symbols/1` does — the venue's per-product row already
  carries all of this, so there is no second request behind it. Same SPOT-only scope as
  `get_symbols/1`; see `fetch_products/1`'s comment.
  """
  @spec get_market_overview(keyword()) :: {:ok, map()} | {:error, term()}
  def get_market_overview(opts) do
    with {:ok, products} <- fetch_products(opts) do
      {:ok, Map.new(products, &market_overview_row/1)}
    end
  end

  @doc """
  Every **SPOT** product Coinbase lists, with the fields `get_symbols/1` discards: base,
  quote, instrument type and trading status.

  Reads the same bulk endpoint `get_symbols/1` does, and shares its SPOT-only scope — see
  `fetch_products/1`'s comment for why.
  """
  @spec list_instruments(keyword()) :: {:ok, [Instrument.t()]} | {:error, term()}
  def list_instruments(opts) do
    with {:ok, products} <- fetch_products(opts) do
      {:ok, Enum.map(products, &to_instrument/1)}
    end
  end

  @doc """
  The venue's own declared alias relationships between listed products, as a
  **bidirectional** map of canonical symbol to canonical symbol.

  ## Why this exists — measured live, 2026-09-05

  Subscribing the streaming `ticker` channel to `XLM-USDC` and `AVAX-USDC` against
  `wss://advanced-trade-ws.coinbase.com` delivers every frame tagged `XLM-USD` and
  `AVAX-USD` — the venue's own subscription acknowledgement even echoes the rewritten
  names back (`"ticker" => ["XLM-USD", "AVAX-USD"]`), not the ones actually sent. This is
  not an accident of one pair: this same catalogue call, read on the same date, shows 112
  of the first 114 USDC products carrying a non-empty `alias` naming their `-USD`
  counterpart —

      {"product_id":"XLM-USDC", ..., "alias":"XLM-USD"}
      {"product_id":"XLM-USD",  ..., "alias":"", "alias_to":["XLM-USDC"]}

  — so a caller subscribed under the alias form receives nothing under the name it asked
  for while a name it never asked for floods in. `DpExchange.Coinbase.Feed` is what uses
  this map to attribute a delivered frame back to whatever the caller actually
  subscribed; see its moduledoc for the mechanism and the measured consumer impact.

  ## Built from `alias` alone, not `alias_to`

  Every aliased pair appears in the same catalogue response from **both** sides — the
  aliased row states `alias`, its target states the reverse via `alias_to`. Reading only
  `alias` and inserting both directions here is complete: nothing `alias_to` would add is
  missing, and reading only one field is one fewer place for the two to disagree.

  ## Values are lists: aliasing is many-to-one

  `alias_to` is an **array** because one product can be the alias target of several. The
  map was single-valued, so each later row overwrote the earlier one's entry and the target
  could be attributed back to only one source; a caller subscribed under the other lost its
  frames (found 2026-10-10 by reading `alias_to`'s type against `Map.put/3`). Every value
  is now the sorted, de-duplicated list of every name that shares the market.

  ## `{:error, _}` is a real possibility, and callers must not guess through it

  This is a bulk catalogue read like `get_symbols/1`, subject to the same failures — see
  `Feed`'s moduledoc for what it does when this call fails: deliver under the venue's own
  id, same as before this map existed, plus a notice that attribution is degraded and
  why. Never a fabricated mapping.
  """
  @spec get_alias_map(keyword()) :: {:ok, %{String.t() => [String.t()]}} | {:error, term()}
  def get_alias_map(opts) do
    with {:ok, products} <- fetch_products(opts) do
      {:ok, products |> Enum.reduce(%{}, &add_alias_pair/2) |> sort_alias_values()}
    end
  end

  defp add_alias_pair(%{"product_id" => product_id, "alias" => alias_id}, acc)
       when is_binary(alias_id) and alias_id != "" do
    canonical = SymbolFormat.to_canonical_symbol(product_id)
    aliased = SymbolFormat.to_canonical_symbol(alias_id)

    acc
    |> Map.update(canonical, [aliased], &[aliased | &1])
    |> Map.update(aliased, [canonical], &[canonical | &1])
  end

  defp add_alias_pair(_product, acc), do: acc

  defp sort_alias_values(map),
    do: Map.new(map, fn {name, targets} -> {name, targets |> Enum.uniq() |> Enum.sort()} end)

  # Public and private again: the venue publishes the catalogue at both paths, and a
  # caller holding a credential should see the authenticated view. Shared by
  # get_symbols/1, get_market_overview/1 and list_instruments/1 — one venue response,
  # three views of it, rather than one call per view of the same row.
  #
  # **SPOT only, explicitly, not by omission.** `ListProducts`/`GetPublicProducts` answer
  # only SPOT when `product_type` is left out
  # (docs/reference/coinbase/openapi/at-spec.yaml:239-241, :2384-2386) — this package used
  # to rely on that omitted-default rather than say so, which is the same shape of claim
  # this family keeps finding wrong: `get_symbols/1`'s own moduledoc said "every product
  # Coinbase lists" while silently meaning "every SPOT one". `product_type: SPOT` is sent
  # explicitly here so the behaviour does not depend on a default the venue could change,
  # and the three callers' docs are corrected to say SPOT rather than claim more than this
  # reads. `get_all_products: true` would reach FUTURE/EQUITY/OPTION_GROUP/FUTURE_GROUP
  # too, but `place_order/3` only builds the order-configuration leaves this venue
  # documents for spot-shaped orders — equities alone need `equity_order_metadata`
  # (at-spec.yaml:545-556) this package never constructs — so returning those symbols here
  # would list instruments this package cannot correctly trade. SPOT, honestly claimed, is
  # the fail-closed answer over a wider list this package would then mishandle.
  #
  # **Paginated, not just the first page.** The response carries `pagination.next_cursor` /
  # `pagination.has_next` (at-spec.yaml:9460-9475, `PaginationMetadata` at :8824-8830) —
  # this used to read only the first page and never followed `cursor`
  # (at-spec.yaml:2450-2453), so a catalogue larger than one page silently lost every
  # product past it, from every one of `get_symbols/1`, `get_market_overview/1`,
  # `list_instruments/1` and `get_alias_map/1`. Walked here the same bounded way
  # `all_accounts/5` above walks `/accounts`.
  defp fetch_products(opts) do
    credentials = opts_credentials(opts)
    path = if credentials, do: "/products", else: "/market/products"

    with {:ok, products} <- all_products(credentials, path, opts, nil, [], 0),
         do: distinct_products(products)
  end

  # One product named twice. The same row repeated (a page boundary that overlaps) is one
  # fact and is kept once; two rows that DISAGREE about one product are not, and which to
  # believe is not ours to guess, so the catalogue is refused. `get_symbols/1` listed the
  # name twice, `get_market_overview/1` silently kept whichever came last, and
  # `list_instruments/1` returned two instruments for one symbol.
  defp distinct_products(products) do
    by_symbol = Enum.group_by(products, &SymbolFormat.to_canonical_symbol(&1["product_id"]))

    if Enum.all?(by_symbol, fn {_symbol, rows} -> length(Enum.uniq(rows)) == 1 end),
      do: {:ok, Enum.uniq(products)},
      else: {:error, :unexpected_response_shape}
  end

  @max_product_pages 50

  defp all_products(_credentials, _path, _opts, _cursor, _acc, page)
       when page >= @max_product_pages,
       do: {:error, :history_truncated}

  defp all_products(credentials, path, opts, cursor, acc, page) do
    params = put_unless_nil(%{"product_type" => "SPOT"}, "cursor", cursor)

    case request(:get, path, credentials, opts, params) do
      {:ok, %{body: %{"products" => products} = body}} when is_list(products) ->
        collected = [Enum.filter(products, &named_product?/1) | acc]
        pagination = body["pagination"]
        next_cursor = if is_map(pagination), do: pagination["next_cursor"]

        # `has_next: true` with no usable cursor is "there is more" with no way to ask for
        # it. Stopping returned the first page as the whole catalogue, every row real and the
        # rest silently missing — the shape `next_cursor/2` refuses for `/accounts`.
        cond do
          not is_map(pagination) or pagination["has_next"] != true ->
            {:ok, collected |> Enum.reverse() |> Enum.concat()}

          # The cursor just sent, offered again, is the same page again: a walk that can only
          # repeat itself until `@max_product_pages` ends it, fifty identical requests later.
          is_binary(next_cursor) and next_cursor == cursor ->
            {:error, :pagination_cursor_repeated}

          is_binary(next_cursor) and next_cursor != "" ->
            all_products(credentials, path, opts, next_cursor, collected, page + 1)

          true ->
            {:error, :pagination_cursor_missing}
        end

      {:ok, _unexpected} ->
        {:error, :unexpected_response_shape}

      {:error, reason} ->
        classify(reason, :symbol)
    end
  end

  # A catalogue row that names no product is skipped, never raised on. It used to reach
  # `SymbolFormat.to_canonical_symbol/1` as whatever was there — `nil`, a map, a list — and
  # raise out of all four catalogue calls, so one malformed row among hundreds took the whole
  # catalogue with it. A REST mutation fuzz (2026-09-27) found it. A row that names nothing
  # cannot be traded, subscribed or aliased, so leaving it out drops no instrument anyone
  # could reach, and `Robinhood`'s catalogue made the same call on 2026-09-26.
  #
  # A blank name (`""`, `"  "`) names nothing either: it came out of `get_symbols/1` as the
  # symbol `""`, and out of `list_instruments/1` as an `Instrument` with that symbol.
  defp named_product?(%{"product_id" => product_id}) when is_binary(product_id),
    do: String.trim(product_id) != ""

  defp named_product?(_unnamed), do: false

  defp market_overview_row(product) do
    symbol = SymbolFormat.to_canonical_symbol(product["product_id"])

    {symbol,
     %{
       price: positive_or_nil(product["price"]),
       price_change_24h_pct: decimal(product["price_percentage_change_24h"]),
       volume_24h: product["volume_24h"] |> decimal() |> non_negative(),
       high_24h: positive_or_nil(product["high_24h"]),
       low_24h: positive_or_nil(product["low_24h"]),
       status: text_or_nil(product["status"])
     }}
  end

  # A price at or below zero is no price any market traded at (MD6): unreadable, so `nil`
  # ("the venue did not say"), as the same field absent or garbled already is.
  defp positive_or_nil(value) do
    case decimal(value) do
      %Decimal{} = parsed -> if Decimal.positive?(parsed), do: parsed
      nil -> nil
    end
  end

  defp to_instrument(product) do
    Instrument.new(
      symbol: SymbolFormat.to_canonical_symbol(product["product_id"]),
      base: text_or_nil(product["base_currency_id"]),
      quote: text_or_nil(product["quote_currency_id"]),
      instrument: Instrument.instrument_from(product["product_type"], expiry_kind(product)),
      status: product_status(product)
    )
  end

  # `future_product_details.contract_expiry_type` (at-spec.yaml `ContractExpiryType`:
  # `UNKNOWN_CONTRACT_EXPIRY_TYPE | EXPIRING | PERPETUAL`), lowercased for Core. Nil when the
  # product carries no details or a non-string value: Core then answers `:unknown` for a
  # FUTURE rather than calling a dated contract perpetual.
  defp expiry_kind(%{"future_product_details" => %{"contract_expiry_type" => kind}})
       when is_binary(kind),
       do: String.downcase(kind)

  defp expiry_kind(_product), do: nil

  # **`status: "online"` is not the whole answer** (issue #5). The venue also flags a product
  # that is online but not trading: `cancel_only` ("orders of the product can only be
  # cancelled"), `trading_disabled` ("disabled for trading for all"), `is_disabled`
  # ("disabled for trading") and `view_only` (`at-spec.yaml`'s `Product` schema). On
  # 2026-10-08, WHUF-USD and WHUF-USDC were `online` with `cancel_only: true`. Read as
  # `:tradable`, a consumer collected them and they never ticked, the signature of a
  # subscription that silently failed. A product with any of these flags is `:unknown`,
  # which is how `dp_exchange_webull` reports its liquidate-only and non-tradable rows. It
  # returns to `:tradable` by itself once the venue clears the flag. `limit_only` and
  # `post_only` still trade, just with order-type restrictions, so they stay `:tradable`.
  @not_trading ~w(cancel_only trading_disabled is_disabled view_only)

  defp product_status(product) do
    if Enum.any?(@not_trading, &(product[&1] == true)),
      do: :unknown,
      else: Instrument.status_from(product["status"])
  end

  @doc """
  Every balance the credential can see, one per account.

  **The venue reports `available_balance` and `hold`; it does not report a total.** The
  total here is their sum, which is arithmetic on two numbers the venue stated rather than
  an estimate — a balance of 1 BTC available with 0.5 held *is* 1.5 BTC, and there is no
  judgement in saying so. Where either is absent the total is `nil` rather than the other
  one alone, because "available, total unknown" and "total equals available" are different
  claims and only one of them is safe to size against.

  ## The pagination is not optional

  This endpoint pages at 49 by default and 250 at most, and a caller reading one page has
  *some* of its balances with nothing to say which are missing. A truncated balance list is
  the worst shape this family has: every number in it is real. So this follows `cursor`
  until `has_next` is false, bounded by `@max_account_pages` (50) — a server that always
  says `has_next` would otherwise loop forever inside a facade call, and answers
  `{:error, :history_truncated}` instead; a page that offers back the cursor it was fetched
  with is `{:error, :pagination_cursor_repeated}`, and `has_next` with no cursor is
  `{:error, :pagination_cursor_missing}`.

  `:timestamp` is when the request was made. A balance has no venue event time; see
  `Core.Types.Balance`.
  """
  @spec get_balances(map(), keyword()) ::
          {:ok, [Types.Balance.t()]} | {:error, term()} | {:refused, term()}
  def get_balances(credentials, opts) do
    asked_at = DateTime.utc_now()

    with :ok <- validate_balance_options(opts),
         {:ok, accounts} <- all_accounts(credentials, opts, nil, [], 0) do
      to_balances(accounts, asked_at)
    end
  end

  @doc """
  The venue's own account records, unnormalised.

  Separate from `get_balances/2` because an account is more than a number: it carries a
  uuid, a platform (`CONSUMER`, `CFM_CONSUMER`, `INTX`), whether it is ready to trade, and
  which portfolio it belongs to. A caller routing an order needs the uuid; a caller sizing
  one needs the balance. Collapsing them would lose the first.

  With `opts[:uuid]` this reads the single account
  (`GET /accounts/{account_uuid}`); without, it pages the list as `get_balances/2` does.
  `opts[:limit]` is the venue's page size and must be an integer in `1..250`
  (`validate_account_options/1`).
  """
  @spec get_accounts(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_accounts(credentials, opts) do
    # `""` would build `/accounts/`, the listing, and a non-string would be interpolated
    # into a path. Neither names an account, so neither is sent (`validate_account_options/1`).
    with :ok <- validate_account_options(opts) do
      case Keyword.get(opts, :uuid) do
        nil ->
          # The rows are returned as the venue's own maps, so each must be one: a number or
          # a list among them reached a consumer indexing it by key.
          with {:ok, accounts} <- all_accounts(credentials, opts, nil, [], 0),
               do: map_rows(accounts)

        uuid ->
          case request(:get, "/accounts/#{segment(uuid)}", credentials, opts) do
            {:ok, %{body: %{"account" => account}}} when is_map(account) -> {:ok, [account]}
            {:ok, _unexpected} -> {:error, :unexpected_response_shape}
            {:error, reason} -> classify(reason)
          end
      end
    end
  end

  @max_account_limit 250

  @doc """
  The local checks `get_accounts/2` runs on its options before any request: `:uuid` (absent,
  or a non-empty string) and `:limit` (absent, or an integer in `1..250` — the venue's
  documented page size, "by default 49, max 250"). Errors: `{:invalid_id, :uuid, v}`,
  `{:invalid_limit, v}`. `:portfolio` is sent as `retail_portfolio_id` on the listing
  (`{:invalid_option, :portfolio, v}` when malformed); the single-account read has no such
  parameter, so `:uuid` together with `:portfolio` is `{:unsupported_option, :portfolio}`.
  """
  @spec validate_account_options(term()) :: :ok | {:error, term()}
  def validate_account_options(opts) do
    with :ok <- check_options(opts, [:uuid, :limit, :portfolio]),
         :ok <- validate_account_uuid(Keyword.get(opts, :uuid)),
         :ok <- balance_checks(opts) do
      if Keyword.get(opts, :uuid) != nil and Keyword.get(opts, :portfolio) != nil,
        do: {:error, {:unsupported_option, :portfolio}},
        else: :ok
    end
  end

  @doc """
  The local check `get_balances/2` runs on its options before any request: `:limit` is
  absent, or an integer in `1..250`, and `:portfolio` absent or a non-blank string (sent as
  the spec's `retail_portfolio_id`; see `validate_portfolio_option/1`). Errors:
  `{:invalid_limit, v}`, `{:invalid_option, :portfolio, v}`. A `limit` the venue's own
  page-size bound does not allow was sent for the venue to clamp or refuse, which is
  unmeasured; a non-number raised `Protocol.UndefinedError` in the caller's process.
  """
  @spec validate_balance_options(term()) :: :ok | {:error, term()}
  def validate_balance_options(opts) do
    with :ok <- check_options(opts, [:limit, :portfolio]), do: balance_checks(opts)
  end

  defp balance_checks(opts) do
    with :ok <- validate_balance_limit(Keyword.get(opts, :limit)) do
      validate_portfolio_option(opts)
    end
  end

  defp validate_balance_limit(nil), do: :ok

  defp validate_balance_limit(limit)
       when is_integer(limit) and limit >= 1 and limit <= @max_account_limit,
       do: :ok

  defp validate_balance_limit(other), do: {:error, {:invalid_limit, other}}

  defp validate_account_uuid(nil), do: :ok
  defp validate_account_uuid(uuid), do: validate_id(uuid, :uuid)

  # A caller-supplied id goes into a URL path. Interpolated raw, `"../portfolios"` or
  # `"x?y=z"` addresses a different resource than the one named, and the JWT is minted for
  # the path as built, so the venue would accept it as legitimate. Only unreserved
  # characters pass through; a venue uuid is made of them.
  #
  # `.` and `..` are unreserved yet are path-navigation segments, so they are escaped too.
  defp segment("."), do: "%2E"
  defp segment(".."), do: "%2E%2E"
  defp segment(id) when is_binary(id), do: URI.encode(id, &URI.char_unreserved?/1)

  @doc """
  Whether `id` can name one resource in a request path — a string that is not blank after
  trimming (`"  "` names nothing either).

  `""` would turn `/payment_methods/{id}` into the list endpoint and answer the wrong
  question, and a `nil`, number or map interpolated into a path names nothing at all (and the
  public functions that take an id used to raise `FunctionClauseError` in the caller's
  process for one). `name` labels the refusal: `{:error, {:invalid_id, name, id}}`.
  """
  @spec validate_id(term(), atom()) :: :ok | {:error, {:invalid_id, atom(), term()}}
  def validate_id(id, name) when is_binary(id) do
    if String.trim(id) == "", do: {:error, {:invalid_id, name, id}}, else: :ok
  end

  def validate_id(id, name), do: {:error, {:invalid_id, name, id}}

  # Pages are collected AS PAGES and concatenated once, not folded with `acc ++ page`.
  # `++` copies its left operand, so appending each page to a growing accumulator is
  # quadratic in the number of rows — the one thing a pagination walk is guaranteed to do a
  # lot of. Measured here: 50 pages of 49 rows (this endpoint's own default page size) went
  # from 0.20 ms to 0.01 ms, and 50 of 250 (its maximum) from 2.75 ms to 0.55 ms.
  #
  # `dp_exchange_robinhood`'s `walk/6` already did it this way and says why; the three
  # walkers here did not.
  @max_account_pages 50

  # The venue's `has_next`/`cursor` envelope, read once for every walker that uses it.
  #
  # `has_next: true` with no usable cursor is the venue saying "there is more" and giving no
  # way to ask for it. Stopping there returned the first page as though it were the whole
  # list: every row real, the rest silently missing — the truncated shape these walkers
  # exist to refuse. It is an error, not a short list.
  #
  # The second argument is the cursor this page was fetched with. A page that offers it back
  # is the same page again; following it could only repeat until the page bound ended the
  # walk, so it is refused at once as `:pagination_cursor_repeated`.
  defp next_cursor(%{"has_next" => true, "cursor" => cursor}, cursor) when is_binary(cursor),
    do: {:error, :pagination_cursor_repeated}

  defp next_cursor(%{"has_next" => true, "cursor" => cursor}, _sent)
       when is_binary(cursor) and cursor != "",
       do: {:next, cursor}

  defp next_cursor(%{"has_next" => true}, _sent), do: {:error, :pagination_cursor_missing}
  defp next_cursor(_body, _sent), do: :done

  defp all_accounts(_credentials, _opts, _cursor, _acc, page) when page >= @max_account_pages,
    do: {:error, :history_truncated}

  defp all_accounts(credentials, opts, cursor, acc, page) do
    params =
      %{}
      |> put_unless_nil("limit", Keyword.get(opts, :limit))
      |> put_unless_nil("retail_portfolio_id", Keyword.get(opts, :portfolio))
      |> put_unless_nil("cursor", cursor)

    case request(:get, "/accounts", credentials, opts, params) do
      {:ok, %{body: %{"accounts" => accounts} = body}} when is_list(accounts) ->
        collected = [accounts | acc]

        # `has_next` is the venue's word for it. An empty page with `has_next` still true
        # is the venue's business; the page counter is what stops this either way.
        case next_cursor(body, cursor) do
          {:next, next} -> all_accounts(credentials, opts, next, collected, page + 1)
          :done -> {:ok, collected |> Enum.reverse() |> Enum.concat()}
          {:error, _reason} = error -> error
        end

      {:ok, _unexpected} ->
        {:error, :unexpected_response_shape}

      {:error, reason} ->
        classify(reason)
    end
  end

  @doc """
  The funding sources this account can move fiat through — `GET /payment_methods`.

  Rows are Coinbase's own maps. A bank account, a card, a PayPal link and a fiat balance
  are different things carrying different fields, and one struct would drop whichever the
  caller needed.

  **A method being listed is not the same as being usable.** Each row carries `verified`,
  `allow_deposit` and `allow_withdraw`, and they disagree with each other routinely — a
  method verified for deposit is not thereby verified for withdrawal. A caller filtering on
  presence picks one the venue will refuse.

  Unlike `/accounts`, this endpoint is not paged: the venue returns the set.
  """
  @spec list_payment_methods(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_payment_methods(credentials, opts) do
    case request(:get, "/payment_methods", credentials, opts) do
      {:ok, %{body: %{"payment_methods" => methods}}} when is_list(methods) -> map_rows(methods)
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
    end
  end

  @doc """
  One funding source by id — `GET /payment_methods/{payment_method_id}`.

  **This is a read; `list_payment_methods/2` is a snapshot.** A method's verification state
  changes without the account doing anything: a bank closes, a card expires, Coinbase
  suspends a rail. Selecting the row out of an earlier listing answers with whatever was
  true when that listing was taken, and moving fiat against it is what that produces.

  A body without a `payment_method` key is `{:error, :unexpected_response_shape}` and never
  an empty map — "the venue answered something else" and "there is no such method" are
  different answers, and only the second is worth acting on.
  """
  @spec get_payment_method(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_payment_method(credentials, id, opts) do
    # An empty id would be `/payment_methods/`, the LIST endpoint, and an id with `/` or `?`
    # another path: so it is refused empty (or not a string) and escaped as a segment
    # otherwise.
    with :ok <- validate_id(id, :payment_method_id) do
      case request(:get, "/payment_methods/#{segment(id)}", credentials, opts) do
        {:ok, %{body: %{"payment_method" => method}}} when is_map(method) -> {:ok, method}
        {:ok, _unexpected} -> {:error, :unexpected_response_shape}
        {:error, reason} -> classify(reason)
      end
    end
  end

  @doc """
  Moves funds between two of this account's portfolios — `POST /portfolios/move_funds`.

  **Nothing leaves Coinbase.** No chain, no address, no network fee. This is
  `transfer_internal/4`, not `withdraw/5`, and conflating them is wrong in both directions:
  a caller reaching for a withdrawal to rebalance between its own portfolios pays a network
  fee it did not need to, and one reaching for this expecting an external transfer sends
  nothing anywhere.

  **Both portfolio uuids are required and neither is defaulted.** `opts[:from]` and
  `opts[:to]` name them. A move with one missing is not a move, and picking a default —
  the default portfolio, the first one listed — would shift funds between portfolios the
  caller never named. Missing either is `{:error, :missing_portfolio}` before a request is
  made.

  The amount is sent as Coinbase's `funds` object: a string value and a currency, which is
  the shape the venue reads. `Decimal.to_string(:normal)` because scientific notation is
  not a number this venue accepts. The amount is a finite, positive `Decimal`; a float is
  `{:error, {:invalid_amount, v}}`. The same uuid for `:from` and `:to` is
  `{:error, {:invalid_transfer, :same_account}}`.

  **An unconfirmed move is `{:error, {:write_unconfirmed, nil, reason}}`.** The request is
  sent once and carries no idempotency key, so a transport failure or `5xx` after the send,
  or a `2xx` whose body is not an object, may have moved the funds: reconcile through
  `get_portfolio_breakdown/3` before moving again. `nil` is the key slot — the venue gives
  this call none. Validation, credentials and our own rate limiter stay plain errors.
  """
  @spec transfer_internal(map(), String.t(), Decimal.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def transfer_internal(credentials, asset, amount, opts) do
    with {:ok, from, to} <- validate_transfer(asset, amount, opts) do
      body = %{
        "funds" => %{"value" => Decimal.to_string(amount, :normal), "currency" => asset},
        "source_portfolio_uuid" => from,
        "target_portfolio_uuid" => to
      }

      case post_once("/portfolios/move_funds", body, credentials, opts) do
        {:ok, %{body: %{} = result}} -> {:ok, result}
        {:ok, _unexpected} -> write_unconfirmed(nil, :unexpected_response_shape)
        {:error, reason} -> write_failure(reason, nil)
      end
    end
  end

  # --- key permissions and server time ------------------------------------

  @doc """
  What this API key is allowed to do — `GET /key_permissions`.

  **Three booleans, and `can_transfer` is the one that moves money.** `can_view`,
  `can_trade` and `can_transfer` are separate permissions and a key routinely holds one or
  two; asking here is cheaper than discovering a missing one from a refused withdrawal.

  Also carries `portfolio_uuid` — **the portfolio the key is attached to** — and its type.
  A key is scoped to a portfolio, so "the account's balance" through this key is that
  portfolio's, and this is where a caller finds out which.
  """
  @spec get_key_permissions(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_key_permissions(credentials, opts) do
    case request(:get, "/key_permissions", credentials, opts) do
      {:ok, %{body: %{"can_view" => _view} = permissions}} -> {:ok, permissions}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
    end
  end

  @doc """
  The venue's own clock — `GET /brokerage/time`.

  **Public**, and the reason it is worth reading: this venue signs requests with a JWT whose
  window is two minutes, so a host clock more than that out of step produces authentication
  failures that look like a credential problem. Comparing this to the local clock is how a
  reader tells the two apart.

  Returns the venue's own map with `iso` and `epochSeconds`/`epochMillis`. It is **not**
  parsed into a `DateTime` and diffed here: the difference a caller cares about is against
  its own clock at the moment it asked, and computing it inside the package would hide
  the round trip in the number.
  """
  @spec get_server_time(keyword()) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_server_time(opts) do
    case request(:get, "/time", nil, opts) do
      {:ok, %{body: %{} = time}} -> {:ok, time}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
    end
  end

  @doc """
  Whether the venue is reachable and the credential, if given, is accepted.

  **Two different questions, and this asks whichever it was given the means to.** Without
  credentials it reads the public clock — reachability alone. With them it reads
  `/key_permissions`, which fails if the key is wrong and tells the caller what the key can
  do if it is right.

  A credential that reaches the venue and is rejected comes back `{:refused, _}`, not
  `{:ok, _}`: an unreachable venue and an unaccepted key are different problems.
  """
  @spec test_connection(map() | nil, keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def test_connection(nil, opts) do
    with {:ok, time} <- get_server_time(opts), do: {:ok, %{"reachable" => true, "time" => time}}
  end

  def test_connection(credentials, opts) when map_size(credentials) == 0,
    do: test_connection(nil, opts)

  def test_connection(credentials, opts) do
    with {:ok, permissions} <- get_key_permissions(credentials, opts) do
      {:ok, Map.put(permissions, "reachable", true)}
    end
  end

  # --- fees and volume ----------------------------------------------------

  @doc """
  The fee schedule that applies to this credential — `GET /transaction_summary`.

  Returns the venue's own map. `fee_tier` carries the maker and taker rates and the volume
  band they apply in; `fee_tier_without_promotion` carries the same **before** any promotion,
  and the two differ when one is running. Both travel: a caller computing cost from the
  promotional tier and reconciling against the standard one would find a gap it cannot
  explain, and the promotion can end between two calls.

  **The rates are per product type, and the filter is not defaulted.** `opts[:product_type]`
  takes the venue's enum — `SPOT`, `FUTURE`, `EQUITY` and the rest — and without it the venue
  answers across all of them, which is its own default and not one this package picked.
  `:product_type`, `:contract_expiry_type` and `:product_venue` must be one of the spec's
  enum strings, else `{:error, {:invalid_option, key, value}}` and nothing is sent
  (`validate_summary_filters/1`); `get_trade_volume/2` takes the same three.

  `goods_and_services_tax` is carried where the venue sends it: a rate quoted `INCLUSIVE` and
  the same rate quoted `EXCLUSIVE` are different amounts of money.
  """
  @spec get_fees(map(), keyword()) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_fees(credentials, opts), do: transaction_summary(credentials, opts)

  @doc """
  What **this account** has traded — `GET /transaction_summary`.

  **This package claimed until 2026-09-01 that Advanced Trade does not aggregate it.** That
  was wrong: the same endpoint that carries the fee schedule carries `volume_breakdown` per
  volume type, `advanced_trade_only_volume`, and `coinbase_pro_volume` beside it. The claim
  was made from the *market* volume endpoint's absence, which is a different question —
  `get_market_overview/1` asks what everyone traded.

  Returned as rows, one per `volume_breakdown` entry, with the venue's own `volume_type`
  intact. **The three totals are not summed together**: Advanced Trade volume is documented
  as non-inclusive of Pro, so adding them is right and adding either to the breakdown is
  double counting. They ride alongside as `advanced_trade_only_volume` and
  `coinbase_pro_volume` on each row rather than being folded in.

  An empty breakdown is an account that has traded nothing in the venue's window — not an
  error, and not a venue that does not report.
  """
  @spec get_trade_volume(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_trade_volume(credentials, opts) do
    with {:ok, summary} <- transaction_summary(credentials, opts) do
      totals = %{
        "advanced_trade_only_volume" => summary["advanced_trade_only_volume"],
        "coinbase_pro_volume" => summary["coinbase_pro_volume"],
        "total_fees" => summary["total_fees"]
      }

      # A breakdown row that is not an object is refused, not merged into: `Map.merge/2`
      # raised on it (REST fuzz, 2026-09-27). Dropping it would leave a volume band out of
      # what reads as the account's whole breakdown.
      #
      # The breakdown itself must be a list, or absent. It went through `List.wrap/1`, so an
      # object in its place became a one-row breakdown with the account totals merged in: a
      # band the venue never listed, reported as the account's whole volume picture.
      case Map.get(summary, "volume_breakdown") do
        nil ->
          {:ok, []}

        rows when is_list(rows) ->
          if Enum.all?(rows, &is_map/1),
            do: {:ok, Enum.map(rows, &Map.merge(&1, totals))},
            else: {:error, :unexpected_response_shape}

        _unreadable ->
          {:error, :unexpected_response_shape}
      end
    end
  end

  defp transaction_summary(credentials, opts) do
    with :ok <- validate_summary_filters(opts) do
      params =
        %{}
        |> put_unless_nil("product_type", Keyword.get(opts, :product_type))
        |> put_unless_nil("contract_expiry_type", Keyword.get(opts, :contract_expiry_type))
        |> put_unless_nil("product_venue", Keyword.get(opts, :product_venue))

      case request(:get, "/transaction_summary", credentials, opts, params) do
        {:ok, %{body: %{"fee_tier" => _tier} = summary}} -> {:ok, summary}
        {:ok, _unexpected} -> {:error, :unexpected_response_shape}
        {:error, reason} -> classify(reason)
      end
    end
  end

  # --- portfolios ---------------------------------------------------------

  @doc """
  The portfolios this credential can address — `GET /portfolios`.

  **A portfolio is an address, not a value.** Balances, orders and positions are asked *of*
  one, and "the account's BTC balance" is not a well-formed question on a venue that has
  them.

  `opts[:portfolio_type]` filters by the venue's own enum where a caller gives one; nothing
  is sent otherwise, because a filter this package chose would hide portfolios the caller
  did not ask to hide. A value outside the enum (`UNDEFINED DEFAULT CONSUMER INTX`) is
  `{:error, {:invalid_option, :portfolio_type, value}}` (`validate_portfolio_filter/1`).

  **`deleted` rides on the row and is not filtered out here.** A deleted portfolio is still
  returned by the venue and still holds history; dropping it would make an id that appears in
  an old order look like an id that never existed.
  """
  @spec list_portfolios(map(), keyword()) ::
          {:ok, [Types.Portfolio.t()]} | {:error, term()} | {:refused, term()}
  def list_portfolios(credentials, opts) do
    with :ok <- validate_portfolio_filter(opts) do
      params = put_unless_nil(%{}, "portfolio_type", Keyword.get(opts, :portfolio_type))

      case request(:get, "/portfolios", credentials, opts, params) do
        {:ok, %{body: %{"portfolios" => portfolios}}} when is_list(portfolios) ->
          to_portfolios(portfolios)

        {:ok, _unexpected} ->
          {:error, :unexpected_response_shape}

        {:error, reason} ->
          classify(reason)
      end
    end
  end

  # One unidentifiable portfolio refuses the whole page rather than leaving a gap in it —
  # the same rule `dp_exchange_gemini`'s `to_fills/2` states for a trade history: a list with
  # an entry silently missing reconciles to a smaller number and looks complete.
  defp to_portfolios(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case to_portfolio(row) do
        {:ok, portfolio} -> {:cont, {:ok, [portfolio | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, portfolios} -> {:ok, Enum.reverse(portfolios)}
      error -> error
    end
  end

  # `:id` is in `Types.Portfolio`'s `@enforce_keys`, so its `new/1` refuses a `nil` there —
  # and nothing here calls `new/1`, the struct being built literally as everywhere in this
  # family, so that check never ran. A portfolio with no id names nothing: every later call
  # that takes a `portfolio_uuid` has no value to pass, and a caller holding one cannot tell
  # it apart from a portfolio that simply has not been fetched yet.
  defp to_portfolio(row) when not is_map(row), do: {:error, :unexpected_response_shape}

  defp to_portfolio(row) do
    with {:ok, id} <- required_id(row["uuid"], :id),
         :ok <- portfolio_fields(row) do
      {:ok,
       %Types.Portfolio{
         id: id,
         name: row["name"],
         type: row["type"],
         deleted: row["deleted"],
         provider: :coinbase
       }}
    end
  end

  # `deleted` is a boolean or absent. `"false"` and `"0"` are truthy to a consumer testing
  # `portfolio.deleted`, so a string there made a live portfolio read as a deleted one (or the
  # reverse), and a number or a map in `name` / `type` is not what those fields are.
  defp portfolio_fields(row) do
    valid? =
      row["deleted"] in [nil, true, false] and
        (is_nil(row["name"]) or is_binary(row["name"])) and
        (is_nil(row["type"]) or is_binary(row["type"]))

    if valid?, do: :ok, else: {:error, :unexpected_response_shape}
  end

  # A portfolio the venue says it created but whose uuid cannot be read is a write that may
  # have happened (W1): a plain error invites a second create, which leaves a duplicate.
  defp created_portfolio(row) do
    case to_portfolio(row) do
      {:ok, _portfolio} = created -> created
      {:error, reason} -> write_unconfirmed(nil, reason)
    end
  end

  @doc """
  One portfolio's full breakdown — `GET /portfolios/{portfolio_uuid}`.

  **Not `list_portfolios/2` narrowed to one.** The listing names portfolios; this returns the
  balances, positions and margin inside one, which is a different and much larger answer. It
  comes back as the venue's own map because none of the contract's types is shaped for a
  whole portfolio at once.

  `opts[:currency]` asks the venue to value the breakdown in one currency.
  """
  @spec get_portfolio_breakdown(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_portfolio_breakdown(credentials, portfolio_uuid, opts) do
    # `""` would read `/portfolios/`, the LIST, and answer it as a breakdown. A `:currency`
    # that is not a string raised `Protocol.UndefinedError` building the query.
    with :ok <- validate_portfolio_breakdown(portfolio_uuid, opts) do
      params = put_unless_nil(%{}, "currency", Keyword.get(opts, :currency))

      case request(:get, "/portfolios/#{segment(portfolio_uuid)}", credentials, opts, params) do
        {:ok, %{body: %{"breakdown" => breakdown}}} when is_map(breakdown) -> {:ok, breakdown}
        # `GetPortfolioBreakdownResponse` always carries `breakdown`. Any other object used to
        # be handed back as the breakdown (`{}` read as a portfolio holding nothing); it is an
        # unreadable answer, not a portfolio.
        {:ok, _unexpected} -> {:error, :unexpected_response_shape}
        {:error, reason} -> classify(reason)
      end
    end
  end

  @doc """
  The local checks `get_portfolio_breakdown/3` runs before any request: the portfolio uuid is
  a non-empty string (`{:invalid_id, :portfolio_uuid, v}`), then `opts[:currency]` is absent
  or a non-empty string (`{:invalid_option, :currency, v}`). Exposed so
  `DpExchange.Coinbase.Fake` refuses exactly as the real path does.
  """
  @spec validate_portfolio_breakdown(term(), term()) :: :ok | {:error, term()}
  def validate_portfolio_breakdown(portfolio_uuid, opts) do
    with :ok <- validate_id(portfolio_uuid, :portfolio_uuid),
         :ok <- check_options(opts, [:currency]),
         do: validate_breakdown_currency(Keyword.get(opts, :currency))
  end

  defp validate_breakdown_currency(nil), do: :ok
  defp validate_breakdown_currency(currency) when is_binary(currency) and currency != "", do: :ok
  defp validate_breakdown_currency(other), do: {:error, {:invalid_option, :currency, other}}

  @doc """
  Creates a portfolio — `POST /portfolios`.

  `opts[:name]` is required and is not defaulted: an unnamed portfolio is one a caller cannot
  tell from another later, and the venue has no notion of a nameless one.
  """
  @spec create_portfolio(map(), keyword()) ::
          {:ok, Types.Portfolio.t()} | {:error, term()} | {:refused, term()}
  def create_portfolio(credentials, opts) do
    with {:ok, name} <- required_name(opts) do
      case post_once("/portfolios", %{"name" => name}, credentials, opts) do
        {:ok, %{body: %{"portfolio" => portfolio}}} when is_map(portfolio) ->
          created_portfolio(portfolio)

        {:ok, _unexpected} ->
          write_unconfirmed(nil, :unexpected_response_shape)

        {:error, reason} ->
          write_failure(reason, nil)
      end
    end
  end

  @doc """
  Renames a portfolio — `PUT /portfolios/{portfolio_uuid}`.

  The only thing this edits is the name. It does not move funds, close positions or change
  what the portfolio can do.
  """
  @spec rename_portfolio(map(), String.t(), String.t(), keyword()) ::
          {:ok, Types.Portfolio.t()} | {:error, term()} | {:refused, term()}
  def rename_portfolio(credentials, portfolio_uuid, name, opts) do
    with :ok <- validate_portfolio_rename(portfolio_uuid, name) do
      path = "/portfolios/#{segment(portfolio_uuid)}"

      # A PUT of the same name is idempotent, so the default retries stay; the signer is
      # counted so a limiter refusal of a retry after a sent attempt is not read as pre-send.
      calls = :atomics.new(1, signed: false)

      case json_request(:put, path, %{"name" => name}, credentials, opts, &counting(&1, calls)) do
        {:ok, %{body: %{"portfolio" => portfolio}}} when is_map(portfolio) ->
          created_portfolio(portfolio)

        {:ok, _unexpected} ->
          write_unconfirmed(nil, :unexpected_response_shape)

        {:error, reason} ->
          write_failure(reason, nil, {calls, opts})
      end
    end
  end

  @doc """
  Deletes a portfolio — `DELETE /portfolios/{portfolio_uuid}`.

  **This is irreversible from this package's side**, and the venue refuses it while the
  portfolio holds funds or open orders — which is the venue's guard, not this one's. A caller
  emptying a portfolio first should use `transfer_internal/4`, and should read
  `list_portfolios/2` afterwards rather than assume: the venue keeps deleted portfolios in
  the listing with `deleted: true`, because old orders still name them.
  """
  @spec delete_portfolio(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def delete_portfolio(credentials, portfolio_uuid, opts) do
    # `""` would be `DELETE /portfolios/`, a request naming no portfolio at all.
    with :ok <- validate_id(portfolio_uuid, :portfolio_uuid) do
      path = "/portfolios/#{segment(portfolio_uuid)}"

      case request(:delete, path, credentials, once(opts)) do
        {:ok, %{body: %{} = result}} -> {:ok, result}
        {:ok, _unexpected} -> write_unconfirmed(portfolio_uuid, :unexpected_response_shape)
        {:error, reason} -> write_failure(reason, portfolio_uuid)
      end
    end
  end

  # --- convert ------------------------------------------------------------

  @doc """
  Quotes a conversion — `POST /convert/quote`. **Nothing moves.**

  Returns `status: :quoted`. The rate is held for a window and `commit_conversion/3` is the
  separate call that accepts it; a caller that never commits has done nothing but ask.

  **Coinbase names accounts by currency, not by uuid**: `from_account` is `"USD"`, not an
  account id. `from` and `to` are passed straight through as the venue's own account
  identifiers.

  `opts[:trade_incentive_metadata]` carries the venue's fee-waiver object where a caller has
  one; nothing is invented for it.

  **`expires_at` is `nil` where the venue does not state one, and that is not "no expiry".**
  A caller committing a lapsed quote can get a fill at the *current* rate rather than an
  error, which is the dangerous case: the operation looks like it succeeded and every number
  in it is real.
  """
  @spec quote_conversion(map(), String.t(), String.t(), Decimal.t(), keyword()) ::
          {:ok, Types.Conversion.t()} | {:error, term()} | {:refused, term()}
  def quote_conversion(credentials, from, to, amount, opts) do
    with :ok <- validate_conversion_quote(from, to, amount) do
      body =
        %{
          "from_account" => from,
          "to_account" => to,
          "amount" => Decimal.to_string(amount, :normal)
        }
        |> put_raw_unless_nil(
          "trade_incentive_metadata",
          Keyword.get(opts, :trade_incentive_metadata)
        )

      with {:ok, trade} <- convert_trade(post_json("/convert/quote", body, credentials, opts)) do
        to_conversion(trade, from, to)
      end
    end
  end

  # An amount that moves or prices money is a finite, positive `Decimal`. A float or string
  # raised in `Decimal.to_string/2` inside the caller's process, and zero, a negative, NaN or
  # infinity was sent to the venue as given.
  defp positive_amount(%Decimal{} = amount) do
    if usable_positive?(amount), do: :ok, else: {:error, {:invalid_amount, amount}}
  end

  defp positive_amount(other), do: {:error, {:invalid_amount, other}}

  @doc """
  Commits a quoted conversion — `POST /convert/trade/{trade_id}`. **This moves funds.**

  **The venue re-asks for both accounts**, and this package does not fill them in from the
  quote: `opts[:from]` and `opts[:to]` are required and refused when missing. Committing
  against accounts the caller did not name is how a conversion happens between the wrong two
  balances.
  """
  @spec commit_conversion(map(), String.t(), keyword()) ::
          {:ok, Types.Conversion.t()} | {:error, term()} | {:refused, term()}
  def commit_conversion(credentials, trade_id, opts) do
    with :ok <- validate_id(trade_id, :trade_id),
         {:ok, from, to} <- convert_accounts(opts) do
      body = %{"from_account" => from, "to_account" => to}
      path = "/convert/trade/#{segment(trade_id)}"

      # `trade_id` is the correlation key sent. Past a possible send, a body that cannot
      # establish what became of the commit (no `trade`, no id, a status this package does
      # not know) is `{:write_unconfirmed, trade_id, reason}`: a plain error would read as
      # "nothing happened" and the caller would commit again. `Types.Conversion` enforces a
      # non-nil `:id` and `:status`, so there is no struct to return with those unreadable.
      case post_once(path, body, credentials, opts) do
        {:ok, %{body: %{"trade" => trade}}} when is_map(trade) ->
          committed_conversion(trade, from, to, trade_id)

        {:ok, _unexpected} ->
          write_unconfirmed(trade_id, :unexpected_response_shape)

        {:error, reason} ->
          write_failure(reason, trade_id)
      end
    end
  end

  defp committed_conversion(trade, from, to, trade_id) do
    case to_conversion(trade, from, to) do
      {:ok, _conversion} = committed -> committed
      {:error, reason} -> write_unconfirmed(trade_id, reason)
    end
  end

  @doc """
  A conversion's current state — `GET /convert/trade/{trade_id}`.

  **Both accounts are required query parameters here**, which is unusual for a read and is
  the venue's own rule. They are refused when missing rather than guessed, because a read
  addressed with the wrong pair is not this trade.
  """
  @spec get_conversion(map(), String.t(), keyword()) ::
          {:ok, Types.Conversion.t()} | {:error, term()} | {:refused, term()}
  def get_conversion(credentials, trade_id, opts) do
    with :ok <- validate_id(trade_id, :trade_id),
         {:ok, from, to} <- convert_accounts(opts) do
      params = %{"from_account" => from, "to_account" => to}
      path = "/convert/trade/#{segment(trade_id)}"

      with {:ok, trade} <- convert_trade(request(:get, path, credentials, opts, params)) do
        to_conversion(trade, from, to)
      end
    end
  end

  defp convert_trade({:ok, %{body: %{"trade" => trade}}}) when is_map(trade), do: {:ok, trade}
  defp convert_trade({:ok, _unexpected}), do: {:error, :unexpected_response_shape}
  defp convert_trade({:error, reason}), do: classify(reason)

  # `from_asset` and `to_asset` come from what the caller asked for, not from the response:
  # the venue's amounts carry a currency each, but which is the source and which the
  # destination is the caller's question and the response does not label them.
  # `:id` and `:status` are both in `Types.Conversion`'s `@enforce_keys`, so its `new/1`
  # refuses a `nil` in either — and nothing here calls `new/1`, the struct being built
  # literally as everywhere in this family, so that check never ran.
  #
  # `conversion_status/1` answering `nil` for a word this package does not know is the right
  # instinct and the wrong destination. Its own comment says why it must not guess —
  # "reporting a quote as settled is the failure this field exists to [prevent]" — and the
  # contract offers the third option that comment did not take: refuse. A conversion whose
  # status cannot be read is not safely actionable by anyone, and a status Coinbase has newly
  # added is exactly the thing that should be loud rather than `nil`. `required_side/1` above
  # already answers an unknown side the same way.
  defp to_conversion(trade, from, to) do
    with {:ok, id} <- required_id(trade["id"], :id),
         {:ok, status} <- required_conversion_status(trade["status"]),
         {:ok, fee} <- total_fee(trade["total_fee"]) do
      {:ok, build_conversion(trade, {from, to}, {id, status}, fee)}
    end
  end

  defp required_conversion_status(value) do
    case conversion_status(value) do
      nil -> {:error, {:unknown_conversion_status, value}}
      status -> {:ok, status}
    end
  end

  defp build_conversion(trade, {from, to}, {id, status}, fee) do
    %Types.Conversion{
      id: id,
      status: status,
      from_asset: from,
      to_asset: to,
      from_amount: amount_value(trade["user_entered_amount"]),
      to_amount: amount_value(trade["total"]),
      rate: nil,
      # `fees` is an array of `Fee` (docs/reference/coinbase/openapi/at-spec.yaml:9968), so
      # reading it directly here handed `decimal/1` a list and produced `nil` silently rather
      # than a total. `total_fee` is the venue's own rollup — a single `Fee` whose
      # `amount.value` is the total across every fee line (at-spec.yaml:9973, :10830-10840) —
      # and is what this field is documented to report.
      fee: fee,
      # Advanced Trade states no expiry on a convert quote. `nil` here is "not stated", and
      # a caller must not read it as open-ended — see `Types.Conversion`.
      expires_at: nil,
      venue_time: nil,
      provider: :coinbase
    }
  end

  # The venue's own enum. Anything this package does not know maps to `nil` rather than to
  # the nearest status: reporting a quote as settled is the failure this field exists to
  # prevent, and reporting a failure as a quote is the same mistake backwards.
  defp conversion_status("TRADE_STATUS_CREATED"), do: :quoted
  defp conversion_status("TRADE_STATUS_STARTED"), do: :committed
  defp conversion_status("TRADE_STATUS_COMPLETED"), do: :settled
  defp conversion_status("TRADE_STATUS_CANCELED"), do: :cancelled
  defp conversion_status("TRADE_STATUS_EXPIRED"), do: :expired
  defp conversion_status("TRADE_STATUS_FAILED"), do: :failed
  defp conversion_status(_other), do: nil

  # --- US derivatives (CFM) -----------------------------------------------

  @doc """
  Open futures positions — `GET /cfm/positions`.

  These are **CFM** positions: futures margined in a separate account held with Coinbase
  Financial Markets, not the spot account held with Coinbase Inc. `get_balances/2` reports
  the second and says nothing about the first.

  ## `:realised_pnl` is `nil`, and that is not an omission

  The venue publishes `daily_realized_pnl` — what this position realised **today** — and no
  lifetime figure. `Types.Position`'s `:realised_pnl` means realised P&L on the position, and
  putting a daily number there would answer a different question with the same field name:
  a caller summing it across reads would count one day repeatedly, and a caller comparing it
  to `avg_entry_price` would be comparing a day to a lifetime.

  The daily figure is real and is not discarded — `list_futures_positions/2` returns the
  venue's own rows, where it keeps its own name.

  `:liquidation_price` is `nil` too: this endpoint publishes none.
  `get_futures_balance_summary/2` carries `liquidation_threshold` for the account.
  """
  @spec get_positions(map(), keyword()) ::
          {:ok, [Types.Position.t()]} | {:error, term()} | {:refused, term()}
  def get_positions(credentials, opts) do
    with {:ok, rows} <- futures_position_rows(credentials, opts) do
      to_positions(rows)
    end
  end

  @doc """
  The venue's own futures position rows — `GET /cfm/positions`.

  Unnormalised, and the reason to reach for it over `get_positions/2` is
  `daily_realized_pnl` and `expiration_time`, neither of which `Types.Position` has a place
  for. A future expires; a perpetual does not, and the contract's type is shaped for the
  second.
  """
  @spec list_futures_positions(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_futures_positions(credentials, opts) do
    # The rows are handed back as the venue's own maps, so each must be one (`get_positions/2`
    # reads them unchecked and refuses a row that is not an object itself, in `to_position/1`).
    with {:ok, rows} <- futures_position_rows(credentials, opts), do: map_rows(rows)
  end

  defp futures_position_rows(credentials, opts) do
    # The CFM endpoints take no portfolio parameter: a portfolio scope is refused, not ignored.
    with :ok <- reject_portfolio_option(opts) do
      case request(:get, "/cfm/positions", credentials, opts) do
        {:ok, %{body: %{"positions" => positions}}} when is_list(positions) -> {:ok, positions}
        {:ok, _unexpected} -> {:error, :unexpected_response_shape}
        {:error, reason} -> classify(reason)
      end
    end
  end

  @doc """
  One futures position by product — `GET /cfm/positions/{product_id}`.

  The product id is the contract, expiry included — `BIT-28JUL23-CDE`, not `BIT`. A future
  is a different instrument each expiry, and a caller holding two months holds two positions.
  """
  @spec get_futures_position(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_futures_position(credentials, product_id, opts) do
    with :ok <- validate_futures_position(product_id, opts) do
      get_futures_position_at(credentials, product_id, opts)
    end
  end

  @doc """
  The local checks `get_futures_position/3` runs before any request: the product id is a
  non-empty string (`{:invalid_id, :product_id, v}`), then no `opts[:portfolio]` is given
  (`{:unsupported_option, :portfolio}`). Exposed so `DpExchange.Coinbase.Fake` refuses
  exactly as the real path does.
  """
  @spec validate_futures_position(term(), term()) :: :ok | {:error, term()}
  def validate_futures_position(product_id, opts) do
    with :ok <- validate_id(product_id, :product_id), do: reject_portfolio_option(opts)
  end

  defp get_futures_position_at(credentials, product_id, opts) do
    case request(:get, "/cfm/positions/#{segment(product_id)}", credentials, opts) do
      {:ok, %{body: %{"position" => position}}} when is_map(position) -> {:ok, position}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason, :symbol)
    end
  end

  # "UNKNOWN" is the venue's own value and is refused rather than mapped to a side (see
  # `position_side/1`). A position filed the wrong way round is the most expensive mistake
  # available in this mapping. Refuses a position row this package cannot read, rather than
  # reporting one that says nothing about what is held.
  #
  # `Core.Types.Position` enforces `:symbol`, `:side` and `:quantity`, and its `new/1` refuses
  # a `nil` in any of them. Nothing here called `new/1` — the struct is built literally, as
  # everywhere in this family — so that check never ran and all three came through unguarded:
  # `row["product_id"]` by key, the side mapping answering `nil` for a side it does not
  # recognise, and `amount_value/1` answering `nil` for an absent or unreadable figure.
  #
  # **All three are guarded (family convention W7).** This used to leave `:side` and
  # `:quantity` alone, reasoning that a partial position is more informative than none. But
  # the struct's contract is not partial: `:side` is `:long` or `:short` and `:quantity` is
  # positive (`Core.Types.Position`), and a literal carrying `side: nil` or `quantity: nil`
  # breaks every consumer that pattern-matches on it — while a consumer that does not match
  # reads "no side" as "flat". One unreadable row refuses the whole reply instead, as an
  # unreadable symbol always did.
  #
  #   * `side` — the venue's own `UNKNOWN` (or anything else but `LONG` / `SHORT`) is
  #     `{:unknown_position_side, value}`, never a guess: a position filed the wrong way round
  #     is the most expensive mistake in this mapping.
  #   * `quantity` — absent, unreadable or negative `number_of_contracts` is
  #     `{:invalid_position_quantity, value}`. A venue sending a signed size would be a new
  #     sign convention and is refused until measured, not normalised by guess. Exactly zero
  #     is a flat or closed position and the row is skipped.
  #   * `symbol` — a position naming no instrument cannot be sized, closed or reconciled.
  defp to_position(%{} = row) do
    with {:ok, symbol} <- required_position_field(row["product_id"], :symbol),
         {:ok, side} <- position_side(row["side"]),
         {:ok, quantity} <- position_quantity(row["number_of_contracts"]) do
      flat_or_position(row, symbol, side, quantity)
    end
  end

  # A row that is not an object at all used to raise out of `row["product_id"]`. It is the
  # same unreadable row as one with no product, and refuses the reply the same way.
  defp to_position(_not_a_row), do: {:error, :unexpected_response_shape}

  # Exactly zero contracts is a flat or closed position: skipped, as the family skips flat
  # rows. Unlike an unreadable row it makes no claim about what is held, so omitting it
  # cannot read as "you hold none" wrongly. A negative or unreadable count still refuses.
  defp flat_or_position(_row, _symbol, _side, :flat), do: {:ok, :flat}

  defp flat_or_position(row, symbol, side, quantity),
    do: {:ok, position_struct(row, symbol, side, quantity)}

  # One unreadable row refuses the whole reply rather than leaving a gap in it. A position
  # list with an entry silently missing reads as "you hold none of that instrument", which is
  # a different and more dangerous claim than "this response could not be read".
  defp to_positions(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
      case to_position(row) do
        {:ok, :flat} -> {:cont, {:ok, acc}}
        {:ok, position} -> {:cont, {:ok, [position | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, positions} -> {:ok, Enum.reverse(positions)}
      error -> error
    end
  end

  # A product id is a non-blank string. A number, a map or `""` was carried through as the
  # position's symbol, which names no instrument a consumer can size or close.
  defp required_position_field(value, field) when is_binary(value) do
    if String.trim(value) == "",
      do: {:error, {:missing_required_field, field}},
      else: {:ok, value}
  end

  defp required_position_field(_unreadable, field),
    do: {:error, {:missing_required_field, field}}

  defp position_struct(row, symbol, side, quantity) do
    %Types.Position{
      symbol: symbol,
      side: side,
      quantity: quantity,
      # The contract types this as an atom. `:future` is the vocabulary `Capabilities`
      # already uses for the instrument kind, so it is the one used here.
      instrument_type: :future,
      average_cost: amount_value(row["avg_entry_price"]),
      mark_price: amount_value(row["current_price"]),
      notional_value: nil,
      # See the moduledoc above: the venue publishes a *daily* realised figure and no
      # lifetime one, and this field means the second.
      realised_pnl: nil,
      unrealised_pnl: amount_value(row["unrealized_pnl"]),
      liquidation_price: nil,
      leverage: nil,
      venue_time: nil,
      provider: :coinbase
    }
  end

  defp position_side("LONG"), do: {:ok, :long}
  defp position_side("SHORT"), do: {:ok, :short}
  defp position_side(other), do: {:error, {:unknown_position_side, other}}

  defp position_quantity(raw) do
    case amount_value(raw) do
      %Decimal{} = quantity ->
        cond do
          flat?(quantity) -> {:ok, :flat}
          usable_positive?(quantity) -> {:ok, quantity}
          true -> {:error, {:invalid_position_quantity, raw}}
        end

      nil ->
        {:error, {:invalid_position_quantity, raw}}
    end
  end

  # Exactly zero contracts: a flat or closed position, not an unreadable one.
  defp flat?(%Decimal{} = quantity) do
    not Decimal.nan?(quantity) and not Decimal.inf?(quantity) and
      Decimal.compare(quantity, Decimal.new(0)) == :eq
  end

  # `get_in(trade, ["total_fee", "amount"])` raised `FunctionClauseError` in `Access.get/3` out
  # of `quote_conversion/5` and `get_conversion/3` for a `total_fee` that is a string or a
  # number: one malformed field, and the caller's process died. Absent or `null` is "not
  # stated", `nil`. One the venue SENT and this cannot read is not "no fee": refused, as an
  # unreadable fill commission is.
  defp total_fee(nil), do: {:ok, nil}

  defp total_fee(%{"amount" => amount}) do
    case amount_value(amount) do
      %Decimal{} = fee -> {:ok, fee}
      nil -> {:error, :unexpected_response_shape}
    end
  end

  defp total_fee(_unreadable), do: {:error, :unexpected_response_shape}

  defp amount_value(nil), do: nil
  defp amount_value(%{"value" => value}), do: decimal(value)
  defp amount_value(value), do: decimal(value)

  @doc """
  The futures account's balances and margin — `GET /cfm/balance_summary`.

  **Two accounts, and the summary names both.** `cbi_usd_balance` is the spot account held
  with Coinbase Inc; `cfm_usd_balance` is the futures account held with Coinbase Financial
  Markets; `total_usd_balance` is the pair. Funds margin futures only from the second, and a
  caller sizing against the total is sizing against money that is not there.

  Every amount arrives as `%{"value" => _, "currency" => _, "cbrn" => _}` and is returned
  that way. Flattening the currency off is how a caller adds two currencies together.

  Carries `liquidation_threshold` and both `liquidation_buffer_*` fields, which is where a
  caller judging room reads — `get_positions/2` publishes no liquidation price.
  """
  @spec get_futures_balance_summary(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_futures_balance_summary(credentials, opts) do
    with :ok <- reject_portfolio_option(opts) do
      case request(:get, "/cfm/balance_summary", credentials, opts) do
        {:ok, %{body: %{"balance_summary" => summary}}} when is_map(summary) -> {:ok, summary}
        {:ok, _unexpected} -> {:error, :unexpected_response_shape}
        {:error, reason} -> classify(reason)
      end
    end
  end

  @doc """
  Pending and processing sweeps — `GET /cfm/sweeps`.

  A sweep moves funds **out of** the futures account and into the spot one. Rows carry
  `status` and `scheduled_time`: a listed sweep has not happened yet, and treating one as
  settled is treating money that is still margining a position as available.

  An empty list means no sweep is pending. It does not mean none has ever run — this
  endpoint reports the queue, not the history.
  """
  @spec list_futures_sweeps(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def list_futures_sweeps(credentials, opts) do
    with :ok <- reject_portfolio_option(opts) do
      case request(:get, "/cfm/sweeps", credentials, opts) do
        {:ok, %{body: %{"sweeps" => sweeps}}} when is_list(sweeps) -> map_rows(sweeps)
        {:ok, _unexpected} -> {:error, :unexpected_response_shape}
        {:error, reason} -> classify(reason)
      end
    end
  end

  @doc """
  Schedules a sweep from the futures account to the spot one —
  `POST /cfm/sweeps/schedule`.

  **This moves funds**, and it is a *schedule*: the venue queues it and
  `list_futures_sweeps/2` reports the queue. A successful response is not money in the spot
  account.

  `opts[:usd_amount]` names the amount. **Omitting it sweeps every available excess dollar**
  — that is the venue's documented default, not this package's, and it is stated here
  because a caller that thought a missing amount meant "nothing" would move the lot. A
  present amount must be a `Decimal`, an integer or a numeric string, finite and positive
  (`{:error, {:invalid_amount, v}}`); **a float is refused**, as on every order field: it
  has already lost digits before it reaches this call.

  A `200` carrying `success: false` is `{:refused, :sweep_not_scheduled}`, not an `:ok`.
  """
  @spec schedule_futures_sweep(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def schedule_futures_sweep(credentials, opts) do
    with {:ok, amount} <- validate_sweep_amount(opts) do
      body = put_unless_nil(%{}, "usd_amount", amount)

      case post_once("/cfm/sweeps/schedule", body, credentials, opts) do
        {:ok, %{body: %{} = result}} -> sweep_outcome(result, :sweep_not_scheduled)
        {:ok, _unexpected} -> write_unconfirmed(nil, :unexpected_response_shape)
        {:error, reason} -> write_failure(reason, nil)
      end
    end
  end

  # `ScheduleFCMSweepResponse` and `CancelFCMSweepResponse` each carry one field,
  # `success: boolean` (at-spec.yaml). A `200` saying `success: false` is the venue declining,
  # and it came back `{:ok, %{"success" => false}}` — a green light on a call that moves
  # funds. It is a refusal, as an order or an edit answering `success: false` is. A body
  # without the field is passed through as before: the spec carries no example of one, so
  # what a real success looks like beyond `success: true` is unmeasured, and calling an
  # unmeasured shape a failure would be as wrong as calling it a success.
  defp sweep_outcome(%{"success" => false}, refusal), do: {:refused, refusal}
  defp sweep_outcome(result, _refusal), do: {:ok, result}

  # Full notation, never scientific — and a string, because that is what the venue's schema
  # says `usd_amount` is. **Only an absent amount means "sweep everything".** A present one
  # is held to the rule every other money field here is: finite and positive. `""`, `"abc"`,
  # `0` and a negative went out as given, and what the venue does with them is unmeasured on
  # a call whose documented default for a missing amount is to move the lot.
  @doc """
  The local check `schedule_futures_sweep/2` runs on `opts[:usd_amount]` before any request:
  absent is `{:ok, nil}` (the venue sweeps everything), a present amount must be a finite,
  positive `Decimal`, integer or numeric string and answers `{:ok, wire_string}`; anything
  else, a float included, is `{:error, {:invalid_amount, v}}`. Exposed so
  `DpExchange.Coinbase.Fake` refuses exactly as the real path does.
  """
  @spec validate_sweep_amount(term()) :: {:ok, String.t() | nil} | {:error, term()}
  def validate_sweep_amount(opts) do
    # A misspelt `usd_amout:` was dropped, and an absent amount sweeps EVERY available dollar.
    with :ok <- check_options(opts, [:usd_amount]),
         do: sweep_amount(Keyword.get(opts, :usd_amount))
  end

  defp sweep_amount(nil), do: {:ok, nil}

  defp sweep_amount(amount) do
    case order_amount(amount) do
      %Decimal{} = parsed -> {:ok, wire_number(parsed)}
      nil -> {:error, {:invalid_amount, amount}}
    end
  end

  @doc """
  Cancels the pending sweep — `DELETE /cfm/sweeps`.

  **Singular.** The venue cancels *the* pending sweep and takes no id; a caller with a
  queue cannot choose which one this reaches. `list_futures_sweeps/2` before and after is
  the only way to see what happened. A `200` carrying `success: false` is
  `{:refused, :sweep_not_cancelled}`, not an `:ok`.
  """
  @spec cancel_futures_sweep(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def cancel_futures_sweep(credentials, opts) do
    with :ok <- reject_portfolio_option(opts) do
      case request(:delete, "/cfm/sweeps", credentials, once(opts)) do
        {:ok, %{body: %{} = result}} -> sweep_outcome(result, :sweep_not_cancelled)
        {:ok, _unexpected} -> write_unconfirmed(nil, :unexpected_response_shape)
        {:error, reason} -> write_failure(reason, nil)
      end
    end
  end

  @doc """
  The account's intraday margin setting — `GET /cfm/intraday/margin_setting`.

  Three values, and the venue's own names are kept: `INTRADAY_MARGIN_SETTING_UNSPECIFIED`,
  `_STANDARD` and `_INTRADAY`. **`UNSPECIFIED` is not `STANDARD`** — it is the venue
  declining to say, and mapping it to the safer-sounding one would assert a setting the
  account may not have.
  """
  @spec get_intraday_margin_setting(map(), keyword()) ::
          {:ok, String.t()} | {:error, term()} | {:refused, term()}
  def get_intraday_margin_setting(credentials, opts) do
    with :ok <- reject_portfolio_option(opts) do
      case request(:get, "/cfm/intraday/margin_setting", credentials, opts) do
        {:ok, %{body: %{"setting" => setting}}} when is_binary(setting) -> {:ok, setting}
        {:ok, _unexpected} -> {:error, :unexpected_response_shape}
        {:error, reason} -> classify(reason)
      end
    end
  end

  # The spec's whole enum (docs/reference/coinbase/openapi/at-spec.yaml:10261-10264). A
  # string outside it is refused locally: the venue's behaviour for one is unmeasured.
  @margin_settings ~w(INTRADAY_MARGIN_SETTING_UNSPECIFIED INTRADAY_MARGIN_SETTING_STANDARD
                      INTRADAY_MARGIN_SETTING_INTRADAY)

  @doc """
  Sets the account's intraday margin setting — `POST /cfm/intraday/margin_setting`.

  **This changes how much leverage the account gets**, on weekdays between 8am and 4pm ET
  excluding market holidays. It is a setting with money behind it: an account opted into
  intraday margin is margined differently for the rest of the session.

  `setting` is required and is passed through as the venue's own string. There is no
  default: the venue's `UNSPECIFIED` is a value in the enum, and choosing it for a caller
  who did not would be setting the account to something it did not ask for.
  """
  @spec set_intraday_margin_setting(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def set_intraday_margin_setting(credentials, setting, opts) do
    with :ok <- validate_margin_setting(setting),
         :ok <- reject_portfolio_option(opts) do
      # Setting the same value twice is harmless, so the default retries stay and the signer
      # is counted (see `rename_portfolio/4`).
      calls = :atomics.new(1, signed: false)
      body = %{"setting" => setting}
      path = "/cfm/intraday/margin_setting"

      case post_json(path, body, credentials, opts, &counting(&1, calls)) do
        {:ok, %{body: %{} = result}} -> {:ok, result}
        {:ok, _unexpected} -> write_unconfirmed(nil, :unexpected_response_shape)
        {:error, reason} -> write_failure(reason, nil, {calls, opts})
      end
    end
  end

  @doc """
  The local check `set_intraday_margin_setting/3` runs on `setting` before any request: one of
  the spec's three strings, else `{:error, {:invalid_margin_setting, v}}`. Exposed so
  `DpExchange.Coinbase.Fake` refuses exactly as the real path does.
  """
  @spec validate_margin_setting(term()) :: :ok | {:error, {:invalid_margin_setting, term()}}
  def validate_margin_setting(setting) when setting in @margin_settings, do: :ok
  def validate_margin_setting(setting), do: {:error, {:invalid_margin_setting, setting}}

  @doc """
  Which margin window the account is in now — `GET /cfm/intraday/current_margin_window`.

  Carries `end_time`, which is when the current window closes, and two kill-switch flags.
  **A kill switch being enabled means the venue has turned intraday margin off**, and an
  account that believes it is on intraday margin while the switch is enabled has more
  leverage in its plan than in its account.

  `opts[:margin_profile_type]` is the venue's own enum and is sent only when given. A value
  outside the spec's list (`MARGIN_PROFILE_TYPE_UNSPECIFIED`, `_RETAIL_REGULAR`,
  `_RETAIL_INTRADAY_MARGIN_1`, the `current_margin_window` parameter in at-spec.yaml) is
  `{:error, {:invalid_option, :margin_profile_type, value}}` and nothing is sent.
  """
  @margin_profile_types ~w(MARGIN_PROFILE_TYPE_UNSPECIFIED MARGIN_PROFILE_TYPE_RETAIL_REGULAR
                           MARGIN_PROFILE_TYPE_RETAIL_INTRADAY_MARGIN_1)
  @spec get_current_margin_window(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_current_margin_window(credentials, opts) do
    with :ok <- validate_margin_window_options(opts) do
      params = put_unless_nil(%{}, "margin_profile_type", Keyword.get(opts, :margin_profile_type))

      case request(:get, "/cfm/intraday/current_margin_window", credentials, opts, params) do
        {:ok, %{body: %{} = result}} -> {:ok, result}
        {:ok, _unexpected} -> {:error, :unexpected_response_shape}
        {:error, reason} -> classify(reason)
      end
    end
  end

  @doc """
  The local check `get_current_margin_window/2` runs on `opts[:margin_profile_type]`: absent,
  or one of the spec's strings. Error: `{:invalid_option, :margin_profile_type, v}`. Exposed so
  `DpExchange.Coinbase.Fake` refuses exactly as the real path does.
  """
  @spec validate_margin_window_options(term()) :: :ok | {:error, term()}
  def validate_margin_window_options(opts) do
    with :ok <- check_options(opts, [:margin_profile_type]),
         do: enum_option(opts, :margin_profile_type, @margin_profile_types)
  end

  # Refuses an account row this package cannot attribute, rather than emitting an unusable
  # `Balance` and reporting it as success.
  #
  # `Core.Types.Balance`'s `new/1` refuses a `nil` in `:currency`. Nothing here called
  # `new/1` — this built the struct literally, the way all five venues do — so the check
  # never ran, and `currency` came straight out of the venue's JSON by key. A renamed or
  # absent `"currency"` produced `%Types.Balance{currency: nil}`: an amount attributable to
  # no asset, returned inside `{:ok, balances}`, which a consumer cannot size, book or
  # reconcile against. It is the renamed-field scenario `Core.Types.Validate`'s moduledoc
  # exists for, arriving through the one path that bypassed the constructor written to
  # catch it.
  #
  # `balance` is a different matter and `total_balance/2`'s "both or nothing" below is
  # deliberately untouched. `Core.Types.Balance` now states outright that `:balance` may
  # honestly be `nil` while `:currency` may not, and cites this venue's derivation as the
  # reason: an unknown total is a real answer with a real `available_balance` beside it, an
  # unattributable row is not an answer at all.
  defp to_balance(account, _asked_at) when not is_map(account),
    do: {:error, :unexpected_response_shape}

  defp to_balance(account, asked_at) do
    available = amount(account["available_balance"])
    hold = amount(account["hold"])

    with {:ok, currency} <- required_currency(account["currency"]) do
      {:ok,
       %Types.Balance{
         currency: currency,
         balance: total_balance(available, hold),
         available_balance: available,
         hold: hold,
         timestamp: asked_at,
         provider: :coinbase
       }}
    end
  end

  # One unattributable row refuses the whole reply rather than leaving a gap in it. A balance
  # list with an entry silently missing reads as "you hold none of that asset", which is a
  # different and more dangerous statement than "this response could not be read".
  defp to_balances(accounts, asked_at) do
    accounts
    |> Enum.reduce_while({:ok, []}, fn account, {:ok, acc} ->
      case to_balance(account, asked_at) do
        {:ok, balance} -> {:cont, {:ok, [balance | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, balances} -> {:ok, Enum.reverse(balances)}
      error -> error
    end
    |> distinct_balances(accounts)
  end

  # The same account row twice is one balance counted twice, which a consumer summing a
  # currency across accounts doubles. Refused, never collapsed.
  defp distinct_balances({:ok, _balances} = result, accounts) do
    if length(accounts) == length(Enum.uniq(accounts)),
      do: result,
      else: {:error, :unexpected_response_shape}
  end

  defp distinct_balances(error, _accounts), do: error

  defp required_currency(code) when is_binary(code) and code != "", do: {:ok, code}
  defp required_currency(_absent), do: {:error, :unexpected_response_shape}

  # Both or nothing. "Available 1, total unknown" and "total equals available" are
  # different claims, and a consumer sizing against the second when the first is true
  # trades against money that is held.
  defp total_balance(nil, _hold), do: nil
  defp total_balance(_available, nil), do: nil
  defp total_balance(available, hold), do: Decimal.add(available, hold)

  # A spot balance or hold below zero is no amount this venue holds: not stated (`nil`), which
  # also leaves the total unstated, rather than carried as a negative and summed.
  defp amount(%{"value" => value}), do: value |> decimal() |> non_negative()
  defp amount(_absent), do: nil

  @doc """
  Past fills for the credential — `GET /orders/historical/fills`.

  Filters go to the venue rather than being applied here: `opts[:order_id]`,
  `opts[:symbol]`, `opts[:start]`, `opts[:end]`, `opts[:limit]`. A client-side filter over
  one page would silently drop matching fills that were on the next one.

  ## `trade_type` is not decoration

  Regular fills carry `FILL`; the venue also emits `REVERSAL`, `CORRECTION` and `SYNTHETIC`
  for adjusted ones. **A reversal is not a trade that happened** — summing a list that mixes
  them without looking produces a position and a cost basis that are both wrong, and both
  plausible.

  `Core.Types.Fill` has no field for it, so this **returns only `FILL` rows by default** and
  `opts[:trade_types]` widens it, taking the venue's own strings. Silently returning all
  four under a type that cannot distinguish them would be the substitution this family
  refuses; refusing to return adjusted fills at all would hide corrections the venue made.

  The response pages on `cursor`, and this follows it to `@max_fill_pages`. `opts[:limit]` is
  sent to the venue as given and the walk then follows the cursor, so it is the venue's page
  size here and **not** a cap on the result (the spec calls it "the number of fills to be
  returned"; whether the cursor is withheld once it is reached was not measured). `:start` /
  `:end` must be `DateTime`s and are checked first, see `validate_fill_filters/1`.

  A row with no `trade_type` is `{:error, {:missing_required_field, :trade_type}}`: it can
  be neither counted as a trade nor excluded as an adjustment, and dropping it unremarked
  leaves a hole in the history. A page with no fills that says `proof_token_required: true`
  (EU SCA) is `{:refused, :proof_token_required}`, not an empty history.

  ## A fill sized in quote currency is refused, not reported as a base quantity

  `Fill.size_in_quote` is `true` when the order was placed in quote currency
  (docs/reference/coinbase/openapi/at-spec.yaml:7309-7312), and the schema does not say
  `size` is then converted to base units. `Types.Fill.quantity` is a base-asset amount, so
  reporting a possibly-quote `size` there is a plausible number with the wrong meaning. A
  row with `size_in_quote: true` fails the whole history with
  `{:error, {:unsupported_fill_size_unit, :quote}}`, as any other row this package cannot
  read faithfully does; a gap or a mislabelled quantity in a fill history is worse than
  an error.
  """
  @spec get_trade_history(map(), keyword()) ::
          {:ok, [Types.Fill.t()]} | {:error, term()} | {:refused, term()}
  def get_trade_history(credentials, opts) do
    with :ok <- validate_fill_filters(opts),
         {:ok, rows} <- all_fills(credentials, opts, nil, [], 0),
         :ok <- typed_fills(rows),
         :ok <- distinct_fills(rows) do
      wanted = Config.opt(opts, :trade_types, ["FILL"])

      rows
      # A row that is not an object is kept so `to_fill/1` can refuse it. Filtering it out
      # here would drop it silently, and a fill history with a gap is a truncated one.
      |> Enum.filter(&(not is_map(&1) or &1["trade_type"] in wanted))
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        case to_fill(row) do
          {:ok, fill} -> {:cont, {:ok, [fill | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        # Oldest first, by the venue's own time — see `Core.Venue`'s callback doc.
        {:ok, fills} -> {:ok, fills |> Enum.reverse() |> Enum.sort_by(& &1.timestamp, DateTime)}
        error -> error
      end
    end
  end

  @max_fill_pages 50

  # `trade_type in wanted` raised `Protocol.UndefinedError` for a `wanted` that is not a
  # list (`trade_types: "FILL"`), after every page had been fetched.
  defp valid_trade_types(wanted) do
    if is_list(wanted) and Enum.all?(wanted, &is_binary/1),
      do: :ok,
      else: {:error, {:invalid_trade_types, wanted}}
  end

  # A row that does not say what kind of fill it is cannot be sorted into "a trade that
  # happened" or "an adjustment". Filtering on `trade_type in wanted` dropped it without a
  # word (`nil` is in no list), a gap in a fill history that reads as complete. Refused
  # instead. A row that is not an object is left for `to_fill/1` to refuse.
  defp typed_fills(rows) do
    if Enum.all?(rows, &(not is_map(&1) or is_binary(&1["trade_type"]))),
      do: :ok,
      else: {:error, {:missing_required_field, :trade_type}}
  end

  # The same fill row twice is one execution counted twice: a pagination walk that re-sends
  # a row across a page boundary doubles a position and a cost basis, both plausible. Only
  # byte-identical rows count: a trade and its reversal share a `trade_id`, and rows that
  # differ are left to be read as the separate fills they claim to be. Refused, never
  # silently collapsed: which copy is the fill is the venue's to say.
  defp distinct_fills(rows) do
    maps = Enum.filter(rows, &is_map/1)

    if length(maps) == length(Enum.uniq(maps)),
      do: :ok,
      else: {:error, :unexpected_response_shape}
  end

  defp all_fills(_credentials, _opts, _cursor, _acc, page) when page >= @max_fill_pages,
    do: {:error, :history_truncated}

  defp all_fills(credentials, opts, cursor, acc, page) do
    params =
      %{}
      |> put_unless_nil("order_ids", Keyword.get(opts, :order_id))
      |> put_unless_nil("product_ids", venue_symbol(Keyword.get(opts, :symbol)))
      |> put_unless_nil("start_sequence_timestamp", timestamp_param(Keyword.get(opts, :start)))
      |> put_unless_nil("end_sequence_timestamp", timestamp_param(Keyword.get(opts, :end)))
      |> put_unless_nil("retail_portfolio_id", Keyword.get(opts, :portfolio))
      |> put_unless_nil("limit", Keyword.get(opts, :limit))
      |> put_unless_nil("cursor", cursor)

    case request(:get, "/orders/historical/fills", credentials, opts, params) do
      {:ok, %{body: %{"fills" => fills} = body}} when is_list(fills) ->
        next_fill_page(credentials, opts, {cursor, page}, [fills | acc], fills, body)

      {:ok, _unexpected} ->
        {:error, :unexpected_response_shape}

      {:error, reason} ->
        classify(reason)
    end
  end

  # What one page of fills says about the next: stop, refuse, or walk on.
  defp next_fill_page(credentials, opts, {cursor, page}, collected, fills, body) do
    # `GetFillsResponse.proof_token_required` says the data is withheld pending an EU
    # SCA proof token (at-spec.yaml:7523-7540). A page with no fills AND that flag is
    # "cannot see", not "none" — returning `[]` would report an empty history.
    if fills == [] and body["proof_token_required"] == true do
      {:refused, :proof_token_required}
    else
      case fill_step(body["cursor"], cursor, fills) do
        {:next, next} -> all_fills(credentials, opts, next, collected, page + 1)
        :done -> {:ok, collected |> Enum.reverse() |> Enum.concat()}
        {:error, _reason} = error -> error
      end
    end
  end

  # An absent or empty cursor is the venue saying "no more". A page with no fills ends the
  # walk whatever it carries. The cursor just sent, offered again, is the same page again (see
  # `next_cursor/2`). A cursor that is present and not a string (a number, a map) is a page
  # this cannot follow: it used to read as "no more", which returned the first pages as the
  # whole history.
  defp fill_step(nil, _sent, _fills), do: :done
  defp fill_step("", _sent, _fills), do: :done
  defp fill_step(_next, _sent, []), do: :done

  defp fill_step(sent, sent, _fills) when is_binary(sent),
    do: {:error, :pagination_cursor_repeated}

  defp fill_step(next, _sent, _fills) when is_binary(next), do: {:next, next}
  defp fill_step(_unreadable, _sent, _fills), do: {:error, :unexpected_response_shape}

  defp timestamp_param(nil), do: nil
  defp timestamp_param(%DateTime{} = at), do: DateTime.to_iso8601(at)

  # An undated fill is refused rather than stamped with the local clock. A fill is an event
  # that happened at a moment; a client timestamp on one places it wrongly in a trade
  # history while looking entirely reasonable.
  # `quantity` and `price` are guarded, not carried forward as `nil`.
  #
  # A `Types.Fill` is an execution record — the value a consumer reconciles money against —
  # and `Fill` names both among the fields its `new/1` refuses a `nil` in. Nothing here
  # called `new/1` (the struct is built literally, as everywhere in this family), so that
  # check never ran, and both went through bare `decimal/1`, which answers `nil` for an
  # absent, empty, unparseable, NaN or Infinity value. A fill reporting that some unstated
  # amount traded at some unstated price is worse than no fill at all: it reconciles to
  # nothing and says nothing about why.
  #
  # `parse_time/1` already guarded the timestamp for exactly this reason. These two are the
  # same argument applied to the other two fields that carry the execution itself.
  defp to_fill(row) when not is_map(row), do: {:error, :unexpected_response_shape}

  # `size_in_quote: true` means `size` may be quote currency, and `Fill.quantity` is base.
  # Found 2026-10-10 by reading the `Fill` schema against this reader, which never looked at
  # the flag. Refused, never converted: converting needs a price the row may not state at
  # the moment the size was set.
  defp to_fill(%{"size_in_quote" => true}), do: {:error, {:unsupported_fill_size_unit, :quote}}

  defp to_fill(row) do
    # `size` and `price` are above zero, as a trade's are: a fill of nothing, or at a price of
    # nothing or less, parsed as numbers and reconciled as an execution. `trade_id` is a string
    # or absent: a map or a list in its place was carried through as the id.
    with {:ok, timestamp} <- parse_time(row["trade_time"]),
         {:ok, quantity} <- required_quantity(row["size"], :quantity),
         {:ok, price} <- required_price(row["price"], :price),
         {:ok, order_id} <- required_id(row["order_id"], :order_id),
         {:ok, symbol} <- required_symbol(row["product_id"]),
         {:ok, side} <- required_side(row["side"]),
         {:ok, trade_id} <- optional_trade_id(row["trade_id"]),
         {:ok, fee} <- optional_fee(row["commission"]) do
      {:ok,
       %Types.Fill{
         order_id: order_id,
         trade_id: trade_id,
         symbol: symbol,
         side: side,
         quantity: quantity,
         price: price,
         fee: fee,
         # The venue names no fee currency on a fill. `nil`, not the quote currency guessed
         # from the pair — a fee can be charged in a third asset and often is.
         fee_currency: nil,
         timestamp: timestamp,
         liquidity: liquidity_atom(row["liquidity_indicator"]),
         provider: :coinbase
       }}
    end
  end

  defp liquidity_atom("MAKER"), do: :maker
  defp liquidity_atom("TAKER"), do: :taker
  # Includes the venue's own `UNKNOWN_LIQUIDITY_INDICATOR`, which is the venue saying it
  # does not know. Neither :maker nor :taker is the honest answer to that.
  defp liquidity_atom(_other), do: nil

  @doc """
  What the venue will actually accept for `symbol` — `GET /products/{product_id}`.

  The venue names four increments and this carries all of them, because **they are not
  interchangeable**: `base_increment` bounds the *quantity* and `quote_increment` the
  *price*, and a caller rounding a price to the base increment produces an order the venue
  rejects on a field it did not name.

  `base_min_size` and `quote_min_size` are also both published, and are minima on different
  things — units of the base asset versus cash. A market order sized in cash is bounded by
  the second and a limit order in units by the first.

  ## The public and private paths again

  `/market/products/{id}` without a credential, `/products/{id}` with one. Same rule as the
  book and the candles: reading the public one while holding a credential silently forgoes
  whatever the authenticated view adds.

  `status` is the venue's own word — `online`, `delisted` and so on — carried unmapped. A
  package that reduced it to a boolean would lose the difference between a product that is
  paused and one that is gone.
  """
  @spec quantization(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def quantization(symbol, opts) do
    with {:ok, product} <- get_product(symbol, opts) do
      {:ok,
       %{
         # The price's increment is `Product.price_increment` — "Minimum amount price can be
         # increased or decreased at once"
         # (docs/reference/coinbase/openapi/at-spec.yaml:9345-9348). NOT `base_increment`,
         # which bounds the quantity, and — this package's own prior mistake — NOT
         # `quote_increment` either: that one is "Minimum amount quote value can be
         # increased or decreased at once" (at-spec.yaml:9193-9197), the granularity of a
         # quote-sized order's notional, not the price's tick size. The two increments
         # happen to share a value on many products, which is exactly why sending
         # `quote_increment` here read as correct in testing against real venue data while
         # rounding to the wrong field's rule on any product where they diverge.
         price_increment: decimal(product["price_increment"]),
         quantity_increment: decimal(product["base_increment"]),
         min_quantity: decimal(product["base_min_size"]),
         # A separate minimum on a different thing: cash, not units.
         min_quote_size: decimal(product["quote_min_size"]),
         max_quantity: decimal(product["base_max_size"]),
         max_quote_size: decimal(product["quote_max_size"]),
         # The venue's own word, unmapped: a boolean would lose the difference between a
         # product that is paused and one that is gone.
         status: product["status"]
       }}
    end
  end

  @doc """
  One product's full record, as the venue publishes it.

  Separate from `quantization/2` because a product carries more than its increments — the
  status, the display names, the 24-hour statistics — and a caller choosing a market wants
  those where a caller rounding an order does not.
  """
  @spec get_product(String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_product(symbol, opts) do
    with :ok <- validate_symbol(symbol) do
      native = symbol |> SymbolFormat.to_exchange_symbol() |> segment()
      credentials = opts_credentials(opts)

      path =
        if credentials, do: "/products/#{native}", else: "/market/products/#{native}"

      case request(:get, path, credentials, opts) do
        {:ok, %{body: %{"product_id" => _id} = product}} -> {:ok, product}
        {:ok, _unexpected} -> {:error, :unexpected_response_shape}
        {:error, reason} -> classify(reason, :symbol)
      end
    end
  end

  # --- validators shared with the fake ---------------------------------------
  #
  # `DpExchange.Coinbase.Fake` must refuse exactly what the real path refuses, in the same
  # order and with the same error shapes. Re-stating these rules there let the two drift
  # (a fake that accepted an order with no price, or a candle window the venue would
  # refuse), so the fake calls these instead. Each is the very check the real function runs
  # before it builds a request.

  @doc """
  The local check every symbol-taking read runs before it builds a path: a non-empty string,
  else `{:error, {:invalid_symbol, value}}`.

  `SymbolFormat.to_exchange_symbol/1` has no clause for a non-binary, so `nil` or `:btc`
  raised `FunctionClauseError` in the caller's process, and `""` built `/products//ticker`.
  Also what `place_order/3` and `close_position/3` apply to their symbol.
  """
  @spec validate_symbol(term()) :: :ok | {:error, {:invalid_symbol, term()}}
  def validate_symbol(symbol), do: order_symbol(symbol)

  @doc """
  Whether `credentials` can sign a request — the same test the real private paths apply
  before any request is built.

  `nil`, `%{}`, and any map without a binary `:api_key` and `:api_secret` are
  `{:error, {:missing_credentials, :coinbase}}`, as `Auth.jwt/2` answers them. This does not
  decode the secret: a key that is present but malformed fails later, at signing. A blank
  or whitespace-only `api_key` or `api_secret` is `{:missing_credentials, :coinbase}` too, and
  one padded with whitespace is `{:error, {:invalid_credentials, :coinbase}}` (see
  `DpExchange.Coinbase.Auth.check_credentials/1`); the value is never echoed.
  """
  @spec validate_credentials(term()) ::
          :ok | {:error, {:missing_credentials | :invalid_credentials, :coinbase}}
  def validate_credentials(credentials) do
    credentials |> normalise_credentials() |> Auth.check_credentials()
  end

  @doc """
  The credential check for a call that has a public form, such as `get_price/2`.

  No credential (`nil` or `%{}`) is `:ok`: the call takes the public path. Anything else
  is signed with, so it is checked exactly as `validate_credentials/1` checks it, and a
  malformed map is refused rather than silently read as anonymous.
  """
  @spec validate_optional_credentials(term()) ::
          :ok | {:error, {:missing_credentials | :invalid_credentials, :coinbase}}
  def validate_optional_credentials(credentials) do
    case normalise_credentials(credentials) do
      nil -> :ok
      present -> Auth.check_credentials(present)
    end
  end

  @doc """
  The local checks `get_orders/2` runs on its options before any request: `:status` (one of
  `OrderExecutionStatus`), `:symbol` (a non-empty string or a non-empty list of them) and
  `:limit` (a positive integer), then `:portfolio` (`validate_portfolio_option/1`). Errors:
  `{:invalid_status, v}`, `{:invalid_symbol, v}`, `{:invalid_limit, v}`,
  `{:invalid_option, :portfolio, v}`, `{:invalid_option, :limit, v}` (above the spec's
  `int32`) and `{:unknown_option, key}` for a key this read does not honour
  (`check_options/2`).
  """
  @spec validate_order_filters(keyword()) :: :ok | {:error, term()}
  def validate_order_filters(opts) do
    with :ok <- check_options(opts, [:status, :symbol, :limit, :portfolio]),
         :ok <- valid_statuses(Keyword.get(opts, :status)),
         :ok <- valid_order_symbols(Keyword.get(opts, :symbol)),
         :ok <- valid_page_size(Keyword.get(opts, :limit), @max_int32) do
      validate_portfolio_option(opts)
    end
  end

  @doc """
  The local check on `opts[:portfolio]` for the reads that send it as `retail_portfolio_id`
  (`get_balances/2`, `get_accounts/2`, `get_orders/2`, `get_trade_history/2`): absent, or a
  non-blank string. Error: `{:invalid_option, :portfolio, v}`.

  The spec marks the parameter **deprecated and "only applicable for legacy keys"** — a CDP
  key defaults to its own permissioned portfolio. What the venue does with it for a CDP key
  is unmeasured, which is why it is sent as given and never silently replaced by the key's.
  """
  @spec validate_portfolio_option(keyword()) ::
          :ok | {:error, {:invalid_option, :portfolio, term()}}
  def validate_portfolio_option(opts) do
    case Keyword.get(opts, :portfolio) do
      nil -> :ok
      portfolio when is_binary(portfolio) -> validate_portfolio_text(portfolio)
      other -> {:error, {:invalid_option, :portfolio, other}}
    end
  end

  defp validate_portfolio_text(portfolio) do
    if String.trim(portfolio) == "",
      do: {:error, {:invalid_option, :portfolio, portfolio}},
      else: :ok
  end

  # Futures (CFM) reads address the account the key belongs to and take no portfolio
  # parameter (at-spec.yaml `/cfm/positions`), so a portfolio scope cannot be honoured.
  @doc """
  Refuses `opts[:portfolio]` on a read that cannot honour it:
  `{:error, {:unsupported_option, :portfolio}}`. The futures (CFM) endpoints take no
  portfolio parameter; ignoring the option would answer for a different scope than asked.
  Any other key is `{:error, {:unknown_option, key}}` and non-keyword options
  `{:error, {:invalid_options, v}}` (`check_options/2`).
  """
  @spec reject_portfolio_option(term()) :: :ok | {:error, term()}
  def reject_portfolio_option(opts) do
    with :ok <- check_options(opts, [:portfolio]) do
      case Keyword.get(opts, :portfolio) do
        nil -> :ok
        _scope -> {:error, {:unsupported_option, :portfolio}}
      end
    end
  end

  # The keys `request/5` forwards to `Core.HttpClient` and the credential `opts_credentials/1`
  # reads. They are accepted on every read; any other key a read does not name is not.
  @transport_options [
    :timeout,
    :retry_attempts,
    :retry_delay,
    :plug,
    :weight,
    :rate_limit_blocking,
    :limiter,
    :credentials
  ]

  @doc """
  Refuses an option key a read does not honour: `{:error, {:unknown_option, key}}`.

  A misspelled `limt: 5` or `symbl: "BTC-USD"` used to be dropped without a word, and the
  call answered for a different question than the one asked (an unfiltered, unbounded
  history under a filter's name). `allowed` is the read's own keys; the transport keys
  (`:plug`, `:retry_attempts`, `:timeout`, `:credentials` and so on) are always accepted.
  Options that are not a keyword list at all are `{:error, {:invalid_options, v}}`.
  """
  @spec check_options(term(), [atom()]) ::
          :ok | {:error, {:unknown_option, term()} | {:invalid_options, term()}}
  def check_options(opts, allowed), do: check_keys(opts, allowed ++ @transport_options)

  defp check_keys(opts, allowed) when is_list(opts) do
    if Keyword.keyword?(opts) do
      case Enum.find(Keyword.keys(opts), &(&1 not in allowed)) do
        nil -> :ok
        key -> {:error, {:unknown_option, key}}
      end
    else
      {:error, {:invalid_options, opts}}
    end
  end

  defp check_keys(opts, _allowed), do: {:error, {:invalid_options, opts}}

  @doc """
  The local checks `get_trade_history/2` runs on its options before any request:
  `:trade_types` (a list of strings), `:symbol` and `:limit` as `validate_order_filters/1`,
  `:order_id` (a non-empty string or a non-empty list of them), and `:start` / `:end`
  (absent, or a `DateTime`; when both are given `:start` must be before `:end`). Errors:
  `{:invalid_trade_types, v}`, `{:invalid_symbol, v}`, `{:invalid_limit, v}`,
  `{:invalid_order_id, v}`, `{:invalid_time, :start | :end, v}`,
  `{:invalid_range, [start: s, end: e]}` (the window the caller passed),
  `{:invalid_option, :portfolio, v}`, `{:invalid_option, :limit, v}` (above the spec's
  `int64`) and `{:unknown_option, key}` for a key this read does not honour
  (`check_options/2`). A string or map in `:start` / `:end` went to the
  venue as given (or raised in the query encoder), and what it makes of an inverted window is
  unmeasured.
  """
  @fill_options [:trade_types, :symbol, :order_id, :start, :end, :limit, :portfolio]

  @spec validate_fill_filters(keyword()) :: :ok | {:error, term()}
  def validate_fill_filters(opts) do
    with :ok <- check_options(opts, @fill_options),
         :ok <- valid_trade_types(Config.opt(opts, :trade_types, ["FILL"])),
         :ok <- valid_order_symbols(Keyword.get(opts, :symbol)),
         :ok <- valid_fill_order_ids(Keyword.get(opts, :order_id)),
         :ok <- valid_fill_window(Keyword.get(opts, :start), Keyword.get(opts, :end)),
         :ok <- valid_page_size(Keyword.get(opts, :limit), @max_int64) do
      validate_portfolio_option(opts)
    end
  end

  defp valid_fill_order_ids(nil), do: :ok

  defp valid_fill_order_ids(ids) do
    list = List.wrap(ids)

    if list != [] and Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, {:invalid_order_id, ids}}
  end

  defp valid_fill_window(start, finish) do
    with :ok <- valid_fill_time(start, :start),
         :ok <- valid_fill_time(finish, :end) do
      ordered_window(start, finish)
    end
  end

  defp ordered_window(%DateTime{} = start, %DateTime{} = finish) do
    if DateTime.compare(start, finish) == :lt,
      do: :ok,
      else: {:error, {:invalid_range, [start: start, end: finish]}}
  end

  defp ordered_window(_start, _finish), do: :ok

  defp valid_fill_time(nil, _bound), do: :ok
  defp valid_fill_time(%DateTime{}, _bound), do: :ok
  defp valid_fill_time(other, bound), do: {:error, {:invalid_time, bound, other}}

  @doc """
  The local checks `replace_order/4` and `preview_replace/4` run on `changes`: only `:price`
  and `:quantity`, and both, each a finite positive number (`{:invalid_price, v}` /
  `{:invalid_quantity, v}`; a float is refused).
  """
  @spec validate_order_edit(term()) :: :ok | {:error, term()}
  def validate_order_edit(changes) do
    with :ok <- editable_changes(changes),
         {:ok, _amounts} <- normalise_amounts([:price, :quantity], changes) do
      :ok
    end
  end

  @doc """
  `validate_order_edit/1` preceded by the order id check `replace_order/4` and
  `preview_replace/4` run first (`validate_order_id/1`, `{:error, {:invalid_order_id, v}}`),
  `nil` having sent `"order_id": null`.
  """
  @spec validate_order_edit(term(), term()) :: :ok | {:error, term()}
  def validate_order_edit(order_id, changes) do
    with :ok <- edit_order_id(order_id), do: validate_order_edit(changes)
  end

  @doc """
  The local checks `close_position/3` runs before any request: `symbol` is a non-empty
  string (`{:invalid_symbol, v}`), `opts[:client_order_id]` is absent or a non-empty string
  (`{:invalid_client_order_id, v}`) and `opts[:size]` is absent or a finite positive number
  (`{:invalid_quantity, v}`; a float is refused).
  """
  @spec validate_close_request(term(), keyword()) :: :ok | {:error, term()}
  def validate_close_request(symbol, opts) do
    with {:ok, _client_order_id, _size} <- close_request(symbol, opts), do: :ok
  end

  defp close_request(symbol, opts) do
    with :ok <- order_symbol(symbol),
         {:ok, client_order_id} <- client_order_id(Keyword.get(opts, :client_order_id)),
         {:ok, sized} <- normalise_amounts([:size], Map.new(Keyword.take(opts, [:size]))) do
      {:ok, client_order_id, Map.get(sized, :size)}
    end
  end

  @doc """
  The local checks `get_historical_prices/4` runs before any request: a timeframe Coinbase
  serves (`{:unsupported_timeframe, tf}`), a `:limit` of 1..#{@max_candles} and a boolean
  `:include_partial` (`{:invalid_option, key, value}`), and a `range` that is a keyword list
  of `DateTime` bounds forming a non-empty window (`{:invalid_range, range}`, the `range`
  exactly as passed) of at most
  `max_candles/0` candles (`{:range_too_wide, requested: n, max: m}`).
  """
  @spec validate_candle_request(String.t(), keyword(), keyword()) :: :ok | {:error, term()}
  def validate_candle_request(timeframe, range, opts) do
    with {:ok, enum} <- granularity_enum(timeframe),
         {:ok, _params} <- candle_params(timeframe, range, enum, opts) do
      :ok
    end
  end

  @doc """
  The two account names the conversion commit and read require in `opts[:from]` and
  `opts[:to]`, or `{:error, :from_and_to_required}`.
  """
  @spec convert_accounts(keyword()) ::
          {:ok, String.t(), String.t()} | {:error, :from_and_to_required}
  def convert_accounts(opts) do
    case {Keyword.get(opts, :from), Keyword.get(opts, :to)} do
      {from, to} when is_binary(from) and is_binary(to) and from != "" and to != "" ->
        {:ok, from, to}

      _missing ->
        {:error, :from_and_to_required}
    end
  end

  @doc """
  The local checks `quote_conversion/5` runs before any request: the amount is a finite,
  positive `Decimal` (`{:invalid_amount, v}`), then `from` and `to` are non-empty strings
  (`{:invalid_id, :from | :to, v}`) — a `nil` was sent as JSON `null` for the venue to read.
  """
  @spec validate_conversion_quote(term(), term(), term()) :: :ok | {:error, term()}
  def validate_conversion_quote(from, to, amount) do
    with :ok <- positive_amount(amount),
         :ok <- validate_id(from, :from) do
      validate_id(to, :to)
    end
  end

  @doc """
  The local checks `transfer_internal/4` runs before any request: the amount is a finite,
  positive `Decimal` (`{:invalid_amount, v}`), the asset a non-empty string
  (`{:invalid_asset, v}`), then both portfolio uuids are given (`{:error, :missing_portfolio}`)
  and differ (`{:error, {:invalid_transfer, :same_account}}`).
  """
  @spec validate_transfer(term(), term(), keyword()) ::
          {:ok, String.t(), String.t()} | {:error, term()}
  def validate_transfer(asset, amount, opts) do
    with :ok <- positive_amount(amount),
         :ok <- valid_currency(asset) do
      transfer_portfolios(opts)
    end
  end

  defp valid_currency(asset) when is_binary(asset) and asset != "", do: :ok
  defp valid_currency(asset), do: {:error, {:invalid_asset, asset}}

  @doc """
  The two portfolio uuids `transfer_internal/4` requires in `opts[:from]` and `opts[:to]`,
  or `{:error, :missing_portfolio}`. The same uuid on both sides moves nothing and is
  refused as `{:error, {:invalid_transfer, :same_account}}` (family convention W4).
  """
  @spec transfer_portfolios(term()) :: {:ok, String.t(), String.t()} | {:error, term()}
  def transfer_portfolios(opts) do
    with :ok <- check_options(opts, [:from, :to]) do
      case {Keyword.get(opts, :from), Keyword.get(opts, :to)} do
        {same, same} when is_binary(same) and same != "" ->
          {:error, {:invalid_transfer, :same_account}}

        {from, to} when is_binary(from) and is_binary(to) and from != "" and to != "" ->
          {:ok, from, to}

        _missing ->
          {:error, :missing_portfolio}
      end
    end
  end

  @doc """
  The portfolio name `create_portfolio/2` requires in `opts[:name]`, or
  `{:error, :name_required}`. An empty name is not a name: the venue has no notion of a
  nameless portfolio and what it does with `""` is unmeasured.
  """
  @spec required_name(term()) :: {:ok, String.t()} | {:error, term()}
  def required_name(opts) do
    with :ok <- check_options(opts, [:name]), do: portfolio_name(Keyword.get(opts, :name))
  end

  @doc """
  The local checks `rename_portfolio/4` runs before any request: the portfolio uuid is a
  non-empty string (`{:invalid_id, :portfolio_uuid, v}`), then the new name is
  (`{:error, :name_required}`).
  """
  @spec validate_portfolio_rename(term(), term()) :: :ok | {:error, term()}
  def validate_portfolio_rename(portfolio_uuid, name) do
    with :ok <- validate_id(portfolio_uuid, :portfolio_uuid),
         {:ok, _name} <- portfolio_name(name) do
      :ok
    end
  end

  defp portfolio_name(name) when is_binary(name) and name != "", do: {:ok, name}
  defp portfolio_name(_missing), do: {:error, :name_required}

  # The spec's enums for the filters below: `product_type` (at-spec.yaml:2098-2107),
  # `contract_expiry_type` (:2113-2119), `product_venue` (:2124-2131), `portfolio_type`
  # (:1311-1318). The `UNKNOWN_*` / `UNDEFINED` members are the venue's "unspecified" and are
  # accepted as the spec lists them.
  @product_types ~w(UNKNOWN_PRODUCT_TYPE SPOT FUTURE EQUITY OPTION_GROUP FUTURE_GROUP)
  @contract_expiry_types ~w(UNKNOWN_CONTRACT_EXPIRY_TYPE EXPIRING PERPETUAL)
  @product_venues ~w(UNKNOWN_VENUE_TYPE CBE FCM INTX)
  @portfolio_types ~w(UNDEFINED DEFAULT CONSUMER INTX)

  @doc """
  The local checks `get_fees/2` and `get_trade_volume/2` run on their options before any
  request: `:product_type`, `:contract_expiry_type` and `:product_venue`, each absent or one
  of the strings the spec's enum for that parameter lists
  (docs/reference/coinbase/openapi/at-spec.yaml:2093-2131). Error:
  `{:invalid_option, key, value}`.
  """
  @spec validate_summary_filters(term()) :: :ok | {:error, term()}
  def validate_summary_filters(opts) do
    with :ok <- check_options(opts, [:product_type, :contract_expiry_type, :product_venue]),
         :ok <- enum_option(opts, :product_type, @product_types),
         :ok <- enum_option(opts, :contract_expiry_type, @contract_expiry_types) do
      enum_option(opts, :product_venue, @product_venues)
    end
  end

  @doc """
  The local check `list_portfolios/2` runs on `opts[:portfolio_type]`: absent, or one of the
  spec's enum (`UNDEFINED DEFAULT CONSUMER INTX`, at-spec.yaml:1311-1318). Error:
  `{:invalid_option, :portfolio_type, value}`.
  """
  @spec validate_portfolio_filter(term()) :: :ok | {:error, term()}
  def validate_portfolio_filter(opts) do
    with :ok <- check_options(opts, [:portfolio_type]),
         do: enum_option(opts, :portfolio_type, @portfolio_types)
  end

  # An enum parameter is sent exactly as the venue spells it, so only that spelling passes.
  # A word outside the list is refused because the venue's handling of an unknown enum value
  # is unmeasured, and a map raised `Protocol.UndefinedError` in `URI.encode_query/1`.
  defp enum_option(opts, key, allowed) do
    case Keyword.get(opts, key) do
      nil ->
        :ok

      value ->
        if is_binary(value) and value in allowed,
          do: :ok,
          else: {:error, {:invalid_option, key, value}}
    end
  end

  # --- internal ----------------------------------------------------------

  defp granularity_enum(timeframe) do
    case Map.fetch(@granularities, timeframe) do
      {:ok, enum} -> {:ok, enum}
      :error -> {:error, {:unsupported_timeframe, timeframe}}
    end
  end

  # Refuses a window wider than the venue will answer, rather than sending it and
  # receiving `INVALID_ARGUMENT` — the caller gets a reason it can act on instead of an
  # empty result it will read as "no data".
  defp candle_params(timeframe, range, enum, opts) do
    width = timeframe_seconds(timeframe)

    with :ok <- check_options(opts, [:limit, :include_partial]),
         :ok <- check_range_keys(range),
         {:ok, limit} <- candle_limit(opts),
         :ok <- include_partial_option(opts),
         {:ok, start, finish} <- candle_window(range, width),
         {:ok, params} <- candle_span(start, finish, width, enum, range) do
      {:ok, put_unless_nil(params, :limit, wire_candle_limit(limit, opts))}
    end
  end

  # The newest bar is the one still forming, and `select_candles/4` withholds it, so a caller's
  # `limit: 1` sent as `limit=1` would be answered with that one forming bar and come back as
  # `[]`, which reads as "no data". One extra is asked for (the venue maximum is a ceiling, so
  # `limit: 350` may come back as 349 closed bars) and `select_candles/4` trims to the newest
  # `limit` after the forming bar is dropped. Which end the venue truncates is unmeasured here.
  defp wire_candle_limit(nil, _opts), do: nil

  defp wire_candle_limit(limit, opts) do
    if Keyword.get(opts, :include_partial) == true, do: limit, else: min(limit + 1, @max_candles)
  end

  # The candles endpoint has a `limit` ("350 by default, max 350", at-spec.yaml:476-482), so
  # the option is sent, never ignored. Zero, a negative, a float, a string and anything above
  # the venue's maximum are refused rather than clamped.
  defp candle_limit(opts) do
    case Keyword.get(opts, :limit) do
      nil -> {:ok, nil}
      limit when is_integer(limit) and limit >= 1 and limit <= @max_candles -> {:ok, limit}
      other -> {:error, {:invalid_option, :limit, other}}
    end
  end

  # A misspelt bound (`strat:`) left the window at its 300-bar default while looking like a
  # bounded read. A range that is not a keyword list is `candle_window/2`'s `:invalid_range`.
  defp check_range_keys(range) when is_list(range) do
    if Keyword.keyword?(range),
      do: check_keys(range, [:start, :end]),
      else: :ok
  end

  defp check_range_keys(_range), do: :ok

  defp include_partial_option(opts) do
    case Keyword.get(opts, :include_partial) do
      value when value in [nil, true, false] -> :ok
      other -> {:error, {:invalid_option, :include_partial, other}}
    end
  end

  # A `range` that is not a keyword list, or a bound that is not a `DateTime`, used to raise
  # `FunctionClauseError` out of `DateTime.diff/3` in the caller's process. The window is the
  # caller's to get right, so it is refused by name. A `nil` bound is an absent one.
  defp candle_window(range, width) do
    if is_list(range) and Keyword.keyword?(range) do
      finish = Keyword.get(range, :end) || DateTime.utc_now()
      start = Keyword.get(range, :start) || default_start(finish, width)

      if is_struct(start, DateTime) and is_struct(finish, DateTime),
        do: {:ok, start, finish},
        else: {:error, {:invalid_range, range}}
    else
      {:error, {:invalid_range, range}}
    end
  end

  defp default_start(%DateTime{} = finish, width),
    do: DateTime.add(finish, -width * 300, :second)

  # Only reached with a bad `:end`; the caller's refusal then names it.
  defp default_start(_not_a_datetime, _width), do: nil

  defp candle_span(start, finish, width, enum, range) do
    span = DateTime.diff(finish, start, :second)
    requested = div(span, width)

    cond do
      # An empty or inverted window is not a request for "no candles": the venue's answer to
      # `start >= end` is unmeasured, and an empty list would read as "no data".
      span <= 0 ->
        {:error, {:invalid_range, range}}

      requested > @max_candles ->
        {:error, {:range_too_wide, requested: requested, max: @max_candles}}

      true ->
        {:ok,
         %{
           start: to_string(DateTime.to_unix(start)),
           end: to_string(DateTime.to_unix(finish)),
           granularity: enum
         }}
    end
  end

  defp timeframe_seconds(timeframe) do
    {:ok, seconds} = Timeframe.seconds(timeframe)
    seconds
  end

  # A signing failure stops the request here rather than sending it unsigned — `Auth`
  # returns `{:ok, headers} | {:error, reason}` for exactly that. An unsigned
  # `Authorization` looks like a credential problem at the venue rather than at us.
  #
  # The `nil` branch is a different case and is not a failure: Coinbase serves market
  # data anonymously, so a call made deliberately without credentials takes the public
  # path with no headers at all.
  #
  # **Anonymous is for the public paths only.** `credentials: nil` used to mean "send no
  # headers" for every path, so `get_balances/2`, `get_orders/2`, `get_trade_history/2` and
  # every other private read, handed an explicit `nil`, went out as an anonymous request for
  # the venue to reject as an opaque 401 — while the `%{}` default for the same call
  # refused locally. Found 2026-10-10 by reading `request_headers/4`. Only a `/market/…`
  # path or `/time` (the spec's public `get-server-time`, which `test_connection(nil)`
  # reads) may go out unsigned; any other path without credentials that can sign answers
  # `{:error, {:missing_credentials, :coinbase}}` before a request is built. `%{}` is
  # normalised to `nil` first so the two spellings of "none" agree.
  defp request(method, path, credentials, opts, params \\ %{}) do
    case request_headers(method, @api_path <> path, path, normalise_credentials(credentials)) do
      {:error, _reason} = refusal -> refusal
      headers -> send_request(method, path, headers, opts, params)
    end
  end

  defp request_headers(_method, _full_path, "/market/" <> _rest, nil), do: []
  defp request_headers(_method, _full_path, "/time", nil), do: []

  defp request_headers(_method, _full_path, _path, nil),
    do: {:error, {:missing_credentials, :coinbase}}

  defp request_headers(method, full_path, _path, credentials),
    do: signer(method, full_path, credentials)

  # `Supervisor.authenticated?/1` already counts `%{}` as no credential; path selection here
  # did not, so a public market-data call carrying `%{}` took the signed path and failed
  # signing. Found 2026-10-10 by reading both. One definition of "none" for both.
  defp opts_credentials(opts), do: opts |> Keyword.get(:credentials) |> normalise_credentials()

  defp normalise_credentials(credentials) when credentials == %{}, do: nil
  defp normalise_credentials(credentials), do: credentials

  # Signed per attempt, not once per call. `Core.HttpClient` retries a timeout or a 5xx up to
  # three times, each bounded at 30 seconds, with backoff between — about 127 seconds in all,
  # past the JWT's 120-second `exp`. A last retry carrying the first attempt's token was
  # refused as an authentication failure, naming credentials that were fine. `Core.HttpClient`
  # calls this function again for each attempt, so each carries a token minted for it.
  #
  # A retried order stays safe: `client_order_id` is the venue's documented idempotency key.
  defp signer(method, path, credentials),
    do: fn -> Auth.rest_headers(method, path, nil, credentials) end

  defp send_request(method, path, headers, opts, params) do
    url = @base_url <> @api_path <> path

    # `:rate_limit_blocking` reaches `Core.HttpClient` from here now — a family-wide gap
    # (DpCryptoManagement's issue #23's investigation, alongside Robinhood's issue #16):
    # `Core.HttpClient.check_rate_limits/1` reads it to choose `acquire/3` over fail-fast
    # `check/3`, but no caller of this module could ever set it. Not defaulted — this
    # venue's own resubscribe path (`DpExchange.Coinbase.Feed`) re-issues subscriptions
    # as WebSocket frames, not HTTP, so there is no rate-limited replay here that would
    # justify choosing a default for a caller.
    request_opts =
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
      # A 4xx comes back intact rather than flattened into a message string, so
      # `classify/1` can match the status exactly instead of searching the body for it.
      |> Keyword.put(:raw_status, true)
      # This venue's own limiter, configured from its own declared ceiling.
      |> Keyword.put_new(:limiter, Config.opt(opts, :limiter, DpExchange.Coinbase.RateLimiter))

    method
    |> HttpClient.request(url <> query(params), headers, nil, request_opts)
    |> split_status()
  end

  # `raw_status: true` hands a 4xx back as `{:ok, response}`, which is the right shape for
  # deciding what it means and the wrong shape for a caller matching `{:ok, _}` as success.
  # Splitting it here keeps every call site's `{:ok, %{body: _}}` clause meaning "the venue
  # answered", and routes everything else through `classify/1` with the status intact.
  defp split_status({:ok, %{status: status} = response}) when status in 200..299,
    do: {:ok, response}

  defp split_status({:ok, %{status: status, body: body}}),
    do: {:error, {:http_status, status, body}}

  defp split_status(other), do: other

  defp query(params) when params == %{}, do: ""

  # A list value is the spec's `explode: true` array — `order_status`, `product_ids` — sent
  # as one repeated key per element. `URI.encode_query/1` raises `ArgumentError` on a list,
  # so `get_orders(status: [:open, :pending])` crashed in the caller's process.
  defp query(params) do
    "?" <>
      (params
       |> Enum.flat_map(fn
         {key, values} when is_list(values) -> Enum.map(values, &{key, &1})
         pair -> [pair]
       end)
       |> URI.encode_query())
  end

  # A 404 from this venue means the product is not listed — a permanent answer, and the
  # distinction a caller needs: a refusal is not retried, an error is.
  #
  # ## This used to string-match the status out of a flattened message, and that was wrong
  #
  # `Core.HttpClient` flattens a 4xx into `"Client error (404): <body>"` unless a caller
  # asks it not to, and this module used to recover the status with
  # `String.contains?(message, "404")`. Core's own moduledoc names that exact expression
  # as the reason `raw_status: true` was added, and it fails in both directions:
  #
  #   * **False positive.** Any 4xx whose *body* happens to contain "404" — an order id, a
  #     price, an embedded vendor code — became `{:refused, :not_listed}`: permanent, never
  #     retried, for something that may well have been transient.
  #   * **False negative.** A 400, 401 or 403 contains no "404" anywhere, so a bad request
  #     or a rejected key fell through to `{:error, message}` and read as *possibly
  #     transient* to every caller — a rotated credential retried instead of refused.
  #
  # The other four venue packages in this family all pass `raw_status: true` and match the
  # status exactly. This one now does too, and the statuses are named rather than inferred.
  #
  # **`:not_listed` is for symbols only.** A 404 on an order, an account, a portfolio or a
  # conversion is `{:refused, :not_found}` (`classify(reason)` with no kind); the symbol
  # reads say `classify(reason, :symbol)`. One answer per kind of thing that can be missing.
  #
  # **A transport failure keeps Core's `{:exchange_error, :coinbase, message}` tag.** This
  # used to strip it to the bare message string, so the same failure read differently here
  # than on every sibling venue, and a caller could not tell a venue answer from a local one.
  defp classify(reason, kind \\ :resource)

  defp classify({:http_status, 404, _body}, :symbol), do: {:refused, :not_listed}
  defp classify({:http_status, 404, _body}, :resource), do: {:refused, :not_found}

  # Permanent for the request as sent. A caller whose key was rotated signs again with the
  # new one, which is a different request rather than a retry of this one.
  defp classify({:http_status, status, body}, _kind) when status in [400, 401, 403],
    do: {:refused, refusal(status, body)}

  defp classify({:http_status, status, body}, _kind),
    do:
      {:error,
       {:exchange_error, :coinbase,
        "HTTP #{status}: #{inspect(body, limit: 50, printable_limit: 2_048)}"}}

  defp classify(reason, _kind), do: {:error, reason}

  # The venue's own words where it gave any, so a caller can see why it refused rather
  # than only that it did.
  #
  # Bounded to `@max_refusal_text` characters, as the unexpected-status text above is: a 4xx
  # whose JSON `message` is a whole error page was copied unchanged into the return value
  # (and from there into whatever a caller logs).
  @max_refusal_text 2_048

  defp refusal(status, body) do
    case body do
      %{"message" => message} when is_binary(message) -> venue_error(status, message)
      %{"error_details" => detail} when is_binary(detail) -> venue_error(status, detail)
      %{"error" => error} when is_binary(error) -> venue_error(status, error)
      _other -> {:venue_error, status}
    end
  end

  defp venue_error(status, text),
    do: {:venue_error, status, String.slice(text, 0, @max_refusal_text)}

  # ONE shape, not two. The adapter this was ported from branched on whether credentials
  # were supplied, formatting `:public_ticker` as a flat `{"price": …}` object and
  # `:auth_ticker` as `{"trades": [...]}`.
  #
  # Measured 2026-08-28: **both endpoints return the trades shape.** Either the public
  # response changed or the assumption was never right; the branch is gone either way,
  # because two formatters for one shape is a second place to be wrong about the venue.
  defp to_quote(%{"trades" => [trade | _rest]} = _body, symbol) when is_map(trade) do
    with {:ok, at} <- parse_time(trade["time"]),
         {:ok, price} <- required_price(trade["price"], :price) do
      # The latest trade's own size: one print (dp-exchange-core issue #42). The streamed
      # `Quote` carries a rolling 24-hour total instead, and `volume_window` tells them apart.
      volume = trade["size"] |> decimal() |> non_negative()

      {:ok,
       %Types.Quote{
         symbol: symbol,
         price: price,
         volume: volume,
         volume_window: volume && :print,
         venue_time: at,
         observed_at: DateTime.utc_now(),
         provider: :coinbase
       }}
    end
  end

  defp to_quote(_body, _symbol), do: {:error, :unexpected_response_shape}

  @doc """
  Recent public trades for `symbol` — the tape.

  **`get_price/2` already reads this payload and keeps only the newest print.** The ticker
  returns a `trades` array; a `Quote` has room for one price, so the rest were discarded at
  the boundary. This returns them.

  Not `get_trade_history/2`, which is the credential's own fills. The tape is everyone's
  executions and has no order of yours behind it.

  **`opts[:limit]` is required.** `limit` is `required: true` on this endpoint
  (docs/reference/coinbase/openapi/at-spec.yaml:523-528, :2636-2641) and the venue documents
  no default for it — unlike `get_price/2`, which always wants exactly the newest print,
  this call's whole purpose is "how many", so there is no single honest number to invent on
  a caller's behalf. Omitting it used to mean sending no `limit` at all, relying on whatever
  the venue does with an undocumented absence; this refuses locally instead. `Core.Venue`
  documents no default itself, so a caller must say how many prints it wants.

  **`opts[:since]` and `opts[:end]`** (a `DateTime` each) are sent to the venue as the ticker's
  `start` and `end` (at-spec.yaml:530-541, UNIX seconds; family convention MD4). `:end` is
  **exclusive** (MD2): the reply is also filtered client-side to trades stamped strictly before
  it, so the rule holds whatever the venue does with `end`. A `:since` read that returns
  `limit` rows may have a hole between `since` and the first row, and is
  `{:error, :history_truncated}`. Which rows the venue keeps when more than `limit` match is
  unmeasured.

  A trade whose price is zero or negative refuses the reply (MD6).

  **Coinbase publishes no bust flag on the ticker**, so `broken` is `false` on every print —
  a venue with nothing busted reports nothing busted, which is the same answer, and
  `opts[:include_broken]` therefore changes nothing here.
  """
  @spec get_trades(String.t(), keyword()) ::
          {:ok, [Types.Trade.t()]} | {:error, term()} | {:refused, term()}
  def get_trades(symbol, opts) do
    with {:ok, limit, since, finish} <- trades_options(opts) do
      do_get_trades(symbol, {limit, since, finish}, opts)
    end
  end

  @doc """
  The local checks `get_trades/2` runs on its options before any request, returning
  `{:ok, limit, since, end}`: `:limit` is required (`{:error, :missing_limit}`), a positive
  integer within the spec's `int32` (`{:invalid_limit, v}`, `{:invalid_option, :limit, v}`
  above it), and `:since` / `:end` are each absent or a `DateTime`
  (`{:invalid_option, key, v}`). `:since` is sent as the ticker's `start` and `:end` as its
  `end` (family convention MD4).
  """
  @spec trades_options(keyword()) ::
          {:ok, pos_integer(), DateTime.t() | nil, DateTime.t() | nil} | {:error, term()}
  def trades_options(opts) do
    with :ok <- check_options(opts, [:limit, :since, :end, :include_broken]),
         {:ok, limit} <- trades_limit(Keyword.get(opts, :limit)),
         {:ok, since} <- trades_bound(opts, :since),
         {:ok, finish} <- trades_bound(opts, :end) do
      {:ok, limit, since, finish}
    end
  end

  defp trades_limit(nil), do: {:error, :missing_limit}

  defp trades_limit(limit) when is_integer(limit) and limit > @max_int32,
    do: {:error, {:invalid_option, :limit, limit}}

  defp trades_limit(limit) when is_integer(limit) and limit > 0, do: {:ok, limit}
  defp trades_limit(other), do: {:error, {:invalid_limit, other}}

  defp put_unix(params, _key, nil), do: params
  defp put_unix(params, key, %DateTime{} = at), do: Map.put(params, key, DateTime.to_unix(at))

  defp trades_bound(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:ok, nil}
      %DateTime{} = at -> {:ok, at}
      other -> {:error, {:invalid_option, key, other}}
    end
  end

  defp do_get_trades(symbol, bounds, opts) do
    with :ok <- validate_symbol(symbol), do: fetch_trades(symbol, bounds, opts)
  end

  defp fetch_trades(symbol, {limit, since, finish}, opts) do
    native = symbol |> SymbolFormat.to_exchange_symbol() |> segment()
    credentials = opts_credentials(opts)

    path =
      if credentials,
        do: "/products/#{native}/ticker",
        else: "/market/products/#{native}/ticker"

    params =
      %{"limit" => limit}
      |> put_unix("start", since)
      |> put_unix("end", finish)

    case request(:get, path, credentials, opts, params) do
      {:ok, %{body: %{"trades" => trades}}} when is_list(trades) ->
        # A `:since` read that returns exactly `limit` rows may have a hole between `since`
        # and the first row: the venue's order and its choice of rows when more match than
        # `limit` are unmeasured, so such a reply is refused rather than returned short.
        if since != nil and length(trades) >= limit,
          do: {:error, :history_truncated},
          else: decode_trades(trades, symbol, finish)

      {:ok, _unexpected} ->
        {:error, :unexpected_response_shape}

      {:error, reason} ->
        classify(reason, :symbol)
    end
  end

  @doc """
  Keeps the trades stamped strictly before `finish` (`nil` keeps all): the family's exclusive
  `:end` (MD2), applied client-side so it holds whatever the venue does with its `end`
  parameter. Shared by `get_trades/2` and `DpExchange.Coinbase.Fake`.
  """
  @spec trades_before([Types.Trade.t()], DateTime.t() | nil) :: [Types.Trade.t()]
  def trades_before(trades, nil), do: trades

  def trades_before(trades, %DateTime{} = finish),
    do: Enum.filter(trades, &(DateTime.compare(&1.timestamp, finish) == :lt))

  defp decode_trades(trades, symbol, finish) do
    trades
    |> Enum.reduce_while({:ok, []}, fn trade, {:ok, acc} ->
      case to_trade(trade, symbol) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      # Oldest first, by the venue's own time — see `Core.Venue`'s callback doc.
      {:ok, decoded} ->
        ordered = Enum.reverse(decoded)

        # One print named twice is not two prints: a consumer summing the tape counts it
        # twice, and one deduplicating on `id` keeps an arbitrary copy. Refused, not merged.
        if unique_by?(ordered, & &1.id) do
          sorted = Enum.sort_by(ordered, & &1.timestamp, DateTime)
          {:ok, trades_before(sorted, finish)}
        else
          {:error, :unexpected_response_shape}
        end

      error ->
        error
    end
  end

  # Whether no two entries of `items` share a key.
  defp unique_by?(items, key_fun) do
    keys = Enum.map(items, key_fun)
    length(keys) == length(Enum.uniq(keys))
  end

  # `trade_id` is guarded like the price and the size, because `Core.Types.Trade` enforces it
  # the same way. This decoder already refused an undated or unpriced print and let an
  # unidentified one through — `id: trade["trade_id"]` with nothing between — so a row whose
  # id the venue omitted became a tape entry a consumer cannot deduplicate against, reconcile
  # to a fill, or ask the venue about again.
  #
  # The id stays a raw value rather than being run through `to_string/1`: `to_string(nil)` is
  # `""`, which passes every `nil` check a consumer might write while identifying nothing.
  # `dp_exchange_gemini` carried exactly that substitution in its own `to_trade/2`, which is
  # what prompted checking this one.
  defp to_trade(trade, _symbol) when not is_map(trade), do: {:error, :unexpected_response_shape}

  defp to_trade(trade, symbol) do
    with {:ok, at} <- parse_time(trade["time"]),
         {:ok, id} <- required_trade_id(trade["trade_id"]),
         {:ok, price} <- required_price(trade["price"], :price),
         {:ok, quantity} <- required_quantity(trade["size"], :quantity) do
      {:ok,
       %Types.Trade{
         id: id,
         symbol: symbol,
         # `HistoricalMarketTrade.side` — what this endpoint actually returns, per
         # `GetMarketTradesResponse` (docs/reference/coinbase/openapi/at-spec.yaml:486-527,
         # :7581-7587) — is documented as "The maker side of the trade."
         # (at-spec.yaml:7752), not the taker's. This used to read it straight through as
         # the taker's side, which inverted the aggressor on every print: a resting BUY the
         # venue reports was in fact lifted by a SELL, and vice versa. `Core.Types.Trade`
         # states its own `:side` as "who removed liquidity" — the taker
         # (deps/dp_exchange_core/lib/dp_exchange/core/types/trade.ex) — so the venue's maker
         # side is flipped here to answer the contract's question. `nil` stays `nil` rather
         # than being flipped to a guess.
         side: trade["side"] |> side_atom() |> maker_side_to_taker(),
         price: price,
         quantity: quantity,
         timestamp: at,
         # No bust flag on this endpoint.
         broken: false,
         provider: :coinbase
       }}
    end
  end

  @doc """
  Best bid and ask for `symbol`, **with the sizes**.

  ## This used to read the ticker, and the ticker has no sizes

  `get_top_of_book/2` called `/products/{id}/ticker`, which publishes `best_bid` and
  `best_ask` and nothing about how much is there — so `bid_size` and `ask_size` were `nil`
  on every response. That is an honest `nil`, and it was also avoidable: the venue publishes
  `/best_bid_ask`, whose pricebook carries the size at each level.

  **A price without a size is half a top of book.** A caller sizing against the best bid
  needs to know whether there is 0.01 BTC there or 40, and `nil` gives it no way to ask.

  `/best_bid_ask` takes `product_ids` and returns one pricebook per product; this asks for
  one and reads the first level of each side.

  ## Unlike every sibling reader in this module, this one has no public form

  Every other market-data function here branches between an authenticated path and a
  `/market/...` public one. This does not, because there is no public
  `/market/best_bid_ask` to branch to — verified live 2026-09-05:

      GET /api/v3/brokerage/best_bid_ask?product_ids=BTC-USD         -> 401
      GET /api/v3/brokerage/market/best_bid_ask?product_ids=BTC-USD  -> 404

  Without credentials this returns `{:error, {:missing_credentials, :coinbase}}` before
  sending anything — never `{:refused, _}`: the credential never left this process, so the
  venue never received a request to decline. `DpExchange.Core.Venue`'s own moduledoc
  reserves `:refused` for the venue's own permanent word about a request it actually got;
  sending the request anyway would come back as an opaque 401 that reads like a venue
  outage rather than what it is — a call that needed a credential it was not given.

  ## An empty `pricebooks` array is silence, not a statement — DpCryptoManagement issue #25

  This used to read a 200 with an empty `pricebooks` array as the venue naming this
  product not listed. Probed live 2026-09-06 against the closely related, unauthenticated
  `/market/product_book` (same "pricebook" data, one product per call instead of a batch):
  a product this venue has never listed answers `404 {"error":"NOT_FOUND","error_details":
  "valid product_id is required"}`, and a product it delisted but still recognises
  (`/market/products/{id}` still answers 200) answers a DIFFERENT `404
  {"error":"NOT_FOUND","error_details":"no pricebook found"}` — never a 200 with an empty
  array, for either case, across every product checked. This venue's own convention for "no
  book" is a distinguishable non-2xx statement, not a quietly empty array inside a 200.

  `/best_bid_ask` takes a *list* of `product_ids` and returns one pricebook per product it
  can answer for — a batch endpoint answering "nothing for this one" by omitting it from the
  array, rather than failing the whole request, is an entirely ordinary batch-API shape, and
  it collapses at least the two states above (never listed; listed but delisted) into one
  indistinguishable silence. Nothing here has ever measured that silence against a genuinely
  live, momentarily bookless product either — the two live-verifiable classes both show
  either a real book or the errors above. Reading that silence as `not_listed` is the same
  substitution `dp_exchange_robinhood`'s issue #25 made of an empty `results` page: an
  unverified negative, standing in for a venue statement that this endpoint has no
  evidence of ever sending.
  """
  @spec get_top_of_book(String.t(), keyword()) ::
          {:ok, Types.TopOfBook.t()} | {:error, term()} | {:refused, term()}
  def get_top_of_book(symbol, opts) do
    with :ok <- validate_symbol(symbol) do
      native = SymbolFormat.to_exchange_symbol(symbol)
      credentials = opts_credentials(opts)

      if is_nil(credentials) do
        {:error, {:missing_credentials, :coinbase}}
      else
        observed_at = DateTime.utc_now()

        case request(:get, "/best_bid_ask", credentials, opts, %{"product_ids" => native}) do
          {:ok, %{body: %{"pricebooks" => [_first | _rest] = pricebooks}}} ->
            select_pricebook(native, pricebooks, observed_at)

          # NOT a refusal — see this function's doc, "An empty `pricebooks` array is silence,
          # not a statement". This batch endpoint answers "nothing for this one" by omitting the
          # product from the array rather than failing the request, which is silence a retry
          # can resolve, not the venue naming the product unlisted. A genuine venue statement
          # (this venue's own convention, measured on the sibling `/product_book` endpoint,
          # is a distinguishable 404) still reaches `{:refused, :not_listed}` below through
          # `classify/1`.
          {:ok, %{body: %{"pricebooks" => []}}} ->
            {:error, :empty_result}

          {:ok, _unexpected} ->
            {:error, :unexpected_response_shape}

          {:error, reason} ->
            classify(reason, :symbol)
        end
      end
    end
  end

  # The pricebook NAMING the product asked for, never the first one. A batch reply may carry
  # other products or reorder them, and another product's best bid and ask under this
  # symbol is a plausible price for the wrong instrument.
  defp select_pricebook(native, pricebooks, observed_at) do
    cond do
      not Enum.all?(pricebooks, &is_map/1) ->
        {:error, :unexpected_response_shape}

      pricebook = Enum.find(pricebooks, &(&1["product_id"] == native)) ->
        build_top_of_book(native, pricebook, observed_at)

      true ->
        {:error, {:product_not_in_response, native}}
    end
  end

  defp build_top_of_book(native, pricebook, observed_at) do
    with {:ok, {bid, bid_size}} <- best_level(pricebook["bids"]),
         {:ok, {ask, ask_size}} <- best_level(pricebook["asks"]) do
      {:ok,
       %Types.TopOfBook{
         symbol: SymbolFormat.to_canonical_symbol(native),
         bid: bid,
         ask: ask,
         bid_size: bid_size,
         ask_size: ask_size,
         venue_time: pricebook_time(pricebook),
         observed_at: observed_at,
         provider: :coinbase
       }}
    end
  end

  # An empty side is a real state — one side of a book can be empty — and `nil` says so.
  # Zero would claim someone is quoting nothing at a price of nothing.
  #
  # A level that is PRESENT and unreadable (`""`, a word, NaN, a missing size, a non-map) is
  # not an empty side: it used to become `nil` here, so a side the venue did quote read as one
  # nobody quotes. It is refused, as `get_order_book/2` already refuses the same level.
  defp best_level(side) when side in [nil, []], do: {:ok, {nil, nil}}

  defp best_level([%{"price" => price, "size" => size} | _rest]) do
    case {decimal(price), decimal(size)} do
      {%Decimal{} = parsed_price, %Decimal{} = parsed_size} ->
        priced_level(parsed_price, parsed_size)

      _unreadable ->
        {:error, :unexpected_response_shape}
    end
  end

  defp best_level(_unreadable), do: {:error, :unexpected_response_shape}

  # A best price at or below zero, or a negative size, is a level no market has: refused as
  # `get_order_book/2` refuses the same level, not carried as the best bid or ask.
  defp priced_level(price, size) do
    if Decimal.positive?(price) and not Decimal.negative?(size),
      do: {:ok, {price, size}},
      else: {:error, :unexpected_response_shape}
  end

  defp pricebook_time(%{"time" => time}) do
    case parse_time(time) do
      {:ok, at} -> at
      _no_time -> nil
    end
  end

  defp pricebook_time(_absent), do: nil

  @doc """
  The order book for `symbol` — `GET /product_book`.

  `opts[:depth]` bounds the levels per side (family convention MD5) and is sent as the
  venue's `limit`; the old `opts[:limit]` spelling is `{:error, {:unsupported_option,
  :limit}}`. `opts[:aggregation_price_increment]` groups them, which is the venue's own word
  for it.

  A level that cannot be read, has a price of zero or less, or a negative size refuses the
  whole book; a level with size zero is no liquidity and is dropped.

  **Both sides come back sorted best-price-first** — bids descending, asks ascending — which
  `Core.Types.OrderBook` makes part of the contract rather than a convenience.

  This used to return the venue's row order, defended as keeping "a crossed or out-of-order
  book" visible. Sorting does not hide a crossed book: crossed means the best bid is at or
  above the best ask, which is a fact about the prices rather than about the order the rows
  arrived in, and after sorting both bests sit at the head where it is easier to see, not
  harder. What row order hid was the ordering a caller is entitled to rely on.

  `venue_time` is the pricebook's own `time` (`observed_at` is when this package read it).
  **A book the venue did not stamp is refused**:
  a depth snapshot with the local clock on it cannot be told apart from a current one, and
  a stale book read as current is the most expensive kind of wrong number here.
  """
  @spec get_order_book(String.t(), keyword()) ::
          {:ok, Types.OrderBook.t()} | {:error, term()} | {:refused, term()}
  def get_order_book(symbol, opts) do
    with :ok <- validate_symbol(symbol),
         {:ok, limit, increment} <- book_options(opts) do
      native = SymbolFormat.to_exchange_symbol(symbol)
      credentials = opts_credentials(opts)

      params =
        %{"product_id" => native}
        |> put_unless_nil("limit", limit)
        |> put_unless_nil("aggregation_price_increment", increment)

      # The venue publishes the same book twice: `/market/product_book` unauthenticated and
      # `/product_book` for a credential. Reading the public one while holding a credential
      # would silently forgo whatever the authenticated view adds.
      path = if credentials, do: "/product_book", else: "/market/product_book"

      case request(:get, path, credentials, opts, params) do
        {:ok, %{body: %{"pricebook" => pricebook}}} when is_map(pricebook) ->
          build_order_book(native, pricebook)

        {:ok, _unexpected} ->
          {:error, :unexpected_response_shape}

        {:error, reason} ->
          classify(reason, :symbol)
      end
    end
  end

  @doc """
  The local checks `get_order_book/2` runs on its options before any request: `:limit` is
  refused (`{:unsupported_option, :limit}`, it is `:depth` now), `:depth` (a positive
  integer, the spec's `int32`) and `:aggregation_price_increment` (a finite positive
  number). Errors: `{:invalid_option, :depth, v}`,
  `{:invalid_aggregation_price_increment, v}`.

  Either used to be stringified with `to_string/1` and sent as given, so a map raised
  `Protocol.UndefinedError` in the caller's process and `"abc"` or `-1` went out for the
  venue to answer.
  """
  @spec validate_book_options(keyword()) :: :ok | {:error, term()}
  def validate_book_options(opts) do
    with {:ok, _limit, _increment} <- book_options(opts), do: :ok
  end

  # `:depth` is the family's name for levels per side (MD5) and is sent as the venue's
  # `limit`. The old `:limit` spelling is refused by name, never read as `:depth`.
  #
  # `:limit` passes `check_options/2` only to be refused by name, with the more useful answer.
  defp book_options(opts) do
    with :ok <- check_options(opts, [:depth, :aggregation_price_increment, :limit]),
         :ok <- book_limit_refused(opts),
         depth = Keyword.get(opts, :depth),
         :ok <- book_depth(depth),
         {:ok, increment} <- book_increment(Keyword.get(opts, :aggregation_price_increment)) do
      {:ok, depth, increment}
    end
  end

  defp book_limit_refused(opts) do
    if Keyword.has_key?(opts, :limit),
      do: {:error, {:unsupported_option, :limit}},
      else: :ok
  end

  defp book_depth(nil), do: :ok
  defp book_depth(depth) when is_integer(depth) and depth >= 1 and depth <= @max_int32, do: :ok
  defp book_depth(depth), do: {:error, {:invalid_option, :depth, depth}}

  defp book_increment(nil), do: {:ok, nil}

  defp book_increment(value) do
    case order_amount(value) do
      %Decimal{} = increment -> {:ok, increment}
      nil -> {:error, {:invalid_aggregation_price_increment, value}}
    end
  end

  # **Both sides must be lists.** `levels/1` answered `[]` for a side that was missing or not
  # a list, so such a reply became a book in which nobody bids or nobody offers, with a real
  # timestamp on it. An illiquid product's empty side arrives as `[]`, which is still read
  # as empty; a side this package cannot read is refused.
  defp build_order_book(native, pricebook) do
    with {:ok, timestamp} <- parse_time(pricebook["time"]),
         true <- is_list(pricebook["bids"]) and is_list(pricebook["asks"]),
         {:ok, bids} <- levels(pricebook["bids"]),
         {:ok, asks} <- levels(pricebook["asks"]) do
      {:ok,
       %Types.OrderBook{
         symbol: SymbolFormat.to_canonical_symbol(native),
         bids: sorted(bids, :desc),
         asks: sorted(asks, :asc),
         venue_time: timestamp,
         observed_at: DateTime.utc_now(),
         # The venue publishes no sequence number on this endpoint. `nil` means it did not
         # say, so a caller cannot use this book to detect a gap in a stream.
         sequence: nil,
         provider: :coinbase
       }}
    else
      false -> {:error, :unexpected_response_shape}
      error -> error
    end
  end

  # **Every row readable, or no book.** The comprehension's pattern silently skipped a row
  # missing `price` or `size`, a hole in the book with every other level real. And a
  # `"price": ""` (this venue sends `""` for absent values) became `{nil, size}`, which then
  # raised inside `sorted/2`'s `Decimal.compare/2` in the caller's process.
  defp levels(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn
      %{"price" => price, "size" => size}, {:ok, acc} ->
        case {decimal(price), decimal(size)} do
          {%Decimal{} = p, %Decimal{} = s} -> book_level(p, s, acc)
          _unreadable -> {:halt, {:error, :unexpected_response_shape}}
        end

      _not_a_level, _acc ->
        {:halt, {:error, :unexpected_response_shape}}
    end)
    |> case do
      {:ok, levels} -> distinct_levels(Enum.reverse(levels))
      error -> error
    end
  end

  # Two rows at one price are not one level: summing them, taking the first or taking the
  # last each states a size the venue did not, and `1.0` and `1.00` are the same price.
  # Refused, as an unreadable level is.
  defp distinct_levels(levels) do
    if unique_by?(levels, fn {price, _size} -> Decimal.normalize(price) end),
      do: {:ok, levels},
      else: {:error, :unexpected_response_shape}
  end

  # MD5/MD6: a price of zero or less, or a negative size, is not a level any market has and
  # refuses the whole book; a size of zero is no liquidity, so the level is dropped.
  defp book_level(price, size, acc) do
    cond do
      not Decimal.positive?(price) or Decimal.negative?(size) ->
        {:halt, {:error, :unexpected_response_shape}}

      Decimal.eq?(size, 0) ->
        {:cont, {:ok, acc}}

      true ->
        {:cont, {:ok, [{price, size} | acc]}}
    end
  end

  # Best price first, because `Core.Types.OrderBook` makes that part of the contract rather
  # than a convenience: "a caller reading `hd(bids)` as the best bid is reading it correctly,
  # and a venue package that returns venue-order without re-sorting has broken the contract
  # even though every value in it is true."
  #
  # This function did not exist, and `get_order_book/2` returned the venue's row order. Its
  # own doc defended that — re-sorting "would hide a venue that sent a crossed or out-of-order
  # book, which is exactly the thing worth seeing" — and the defence conflates two different
  # things. **Sorting cannot hide a crossed book.** Crossed means the best bid is at or above
  # the best ask, and that is a fact about the prices, not about the order the rows arrived
  # in; after sorting it is still there, and easier to see, because both bests are now at the
  # head. What passing row order through hid was the ordering the contract promises.
  #
  # It was also this package disagreeing with itself: `Socket`'s `snapshot` frame has always
  # sorted (see `Socket.sorted/2`), the fake generates both sides best-first, and
  # `usage-rules.md` tells consumers the snapshot arrives "sorted best-price-first, as the
  # contract always promised". Only this one path did not. `dp_exchange_schwab` had the same
  # defect, with the same ascending-bid fixture pinning it, and fixed it on 2026-09-13.
  defp sorted(levels, :desc),
    do: Enum.sort_by(levels, fn {price, _qty} -> price end, {:desc, Decimal})

  defp sorted(levels, :asc),
    do: Enum.sort_by(levels, fn {price, _qty} -> price end, {:asc, Decimal})

  # **This built `Quote`s with `price: close` until 2026-09-01.** The venue sends open,
  # high, low and close; three of them were discarded here, at the boundary, where no
  # caller could see it happen. Every value that came out was real, and a caller reading
  # `price` had no way to learn it was holding one corner of a bar.
  #
  # It is the same defect 2.10 of the coverage plan found in Schwab, and the reasoning
  # behind it was the same: "a bar's price, for a series, is where it ended".
  defp to_candles(%{"candles" => candles}, symbol, timeframe) when is_list(candles) do
    candles
    |> Enum.reduce_while({:ok, []}, fn candle, {:ok, acc} ->
      case to_candle(candle, symbol, timeframe) do
        {:ok, bar} -> {:cont, {:ok, [bar | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, bars} -> series(Enum.reverse(bars))
      error -> error
    end
  end

  defp to_candles(_body, _symbol, _timeframe), do: {:error, :unexpected_response_shape}

  # Two bars opened at the same instant are a series that contradicts itself: which one is
  # the bar is not something to guess, and returning both gives a consumer two closes for
  # one bucket. Refused. Otherwise oldest first, whatever order the venue sent them in.
  defp series(bars) do
    if unique_by?(bars, & &1.opened_at),
      do: {:ok, Enum.sort_by(bars, & &1.opened_at, DateTime)},
      else: {:error, :unexpected_response_shape}
  end

  defp to_candle(candle, _symbol, _timeframe) when not is_map(candle),
    do: {:error, :unexpected_response_shape}

  defp to_candle(candle, symbol, timeframe) do
    with {:ok, opened_at} <- candle_start(candle["start"]),
         {:ok, open} <- required_price(candle["open"], :open),
         {:ok, high} <- required_price(candle["high"], :high),
         {:ok, low} <- required_price(candle["low"], :low),
         {:ok, close} <- required_price(candle["close"], :close),
         :ok <- consistent_bar(open, high, low, close) do
      {:ok,
       %Types.Candle{
         symbol: symbol,
         timeframe: timeframe,
         # The venue's own bucket start, used as-is. Not re-derived, not rounded.
         opened_at: opened_at,
         open: open,
         high: high,
         low: low,
         close: close,
         volume: candle["volume"] |> decimal() |> non_negative(),
         provider: :coinbase
       }}
    end
  end

  # A bar whose high is below its low, or whose open or close lies outside that range, cannot
  # have traded: every number in it parses and is positive, and the bar is still impossible.
  # Refused rather than carried, as a quote read from it would be a plausible wrong one.
  defp consistent_bar(open, high, low, close) do
    inside? = fn price -> Decimal.lte?(low, price) and Decimal.lte?(price, high) end

    if Decimal.lte?(low, high) and inside?.(open) and inside?.(close),
      do: :ok,
      else: {:error, :unexpected_response_shape}
  end

  # An undated bar cannot be placed in a series, and the local clock would place it wrongly
  # while looking right. Refuse instead.
  defp candle_start(start) when is_binary(start) do
    case Integer.parse(start) do
      {seconds, ""} -> candle_start(seconds)
      _not_an_epoch -> {:error, :missing_venue_timestamp}
    end
  end

  defp candle_start(start) when is_integer(start), do: from_unix_seconds(start)
  defp candle_start(_absent), do: {:error, :missing_venue_timestamp}

  # `DateTime.from_unix/2`, not `from_unix!/2`, and non-positive is refused.
  #
  # Two ways a number that parses cleanly is still not a bar time, and the bang version
  # handled neither. **Out of range RAISES**: this field is seconds, so a venue moving to
  # milliseconds — ordinary drift, and this venue publishes both units elsewhere — sends
  # `1787936147000`, which is `invalid Unix time`, thrown out of `get_historical_prices/4`
  # rather than returned by it. **Zero and negative do NOT raise**: they quietly become 1970
  # and earlier, which is the shape this family already named — a bar that opens in 1970
  # sorts to the front of the series with every price in it real.
  #
  # Both answer `{:error, :missing_venue_timestamp}`, which is what this function already
  # says for an undated bar and is the honest answer for one that cannot be dated.
  defp from_unix_seconds(seconds) when seconds > 0 do
    case DateTime.from_unix(seconds) do
      {:ok, at} -> {:ok, at}
      {:error, _out_of_range} -> {:error, :missing_venue_timestamp}
    end
  end

  defp from_unix_seconds(_non_positive), do: {:error, :missing_venue_timestamp}

  # `nil` rather than zero for an absent number. Zero is a price, and a venue that did
  # not report volume has not reported zero volume.
  # An order with nothing filled has no average price. The venue states `"0"` for it, and a
  # consumer computing a notional from `average_price` read a fill at zero.
  defp average_price(average, filled) do
    if filled == nil or Decimal.eq?(filled, 0), do: nil, else: average
  end

  defp decimal(nil), do: nil
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)

  # A JSON float (`1.0e300`) is held to the same exponent bound as a string: it parsed as
  # `Decimal` with exponent 300 and compared, added and rounded as one.
  defp decimal(value) when is_float(value) do
    parsed = Decimal.from_float(value)
    if absurd_exponent?(parsed), do: nil, else: parsed
  end

  # `Decimal.new/1` raises on a string that is not a number. Coinbase sends `""` for a
  # bid or ask it has no value for, which is the same case: absent, not zero — and
  # `Decimal.parse/1`, requiring the whole string be consumed (`{d, ""}`), covers both
  # `""` and any other unparsable string in one clause rather than special-casing empty.
  # `Decimal.parse/1` requiring the whole string be consumed is NOT a sufficient guard on
  # its own, which is the half this copy was missing. "NaN", "Inf" and "-Inf" all parse
  # fully and case-insensitively — `"-nan"` and `"inf"` too — so each arrived here as a
  # perfectly well-formed `Decimal` and flowed onward as a real price.
  #
  # That is worse than the raise this parse replaced, and it fails a long way from the
  # cause. Measured: `Decimal.add(nan, 1)` is NaN, so it poisons a consumer's arithmetic
  # silently; `Decimal.compare(nan, _)` RAISES `invalid_operation: operation on NaN`, in
  # the consumer's own process, with a message naming Decimal rather than the venue that
  # sent it. An Infinity is quieter still — it compares greater than everything and never
  # raises at all.
  #
  # `dp_exchange_webull` found this and guarded both of its own copies; the other four
  # venues guarded none of their nine. Fixed where it was found, not where it applied —
  # which is why this comment is in each of them now rather than one of them.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} ->
        if Decimal.nan?(parsed) or Decimal.inf?(parsed) or absurd_exponent?(parsed),
          do: nil,
          else: parsed

      _unparsable ->
        nil
    end
  end

  defp decimal(_other), do: nil

  # A size, a limit price or a volume below zero is no quantity any market reports. It parses
  # as a perfectly good number, so `decimal/1` alone let it through as one; it is `nil` here,
  # which is what this module already answers for a value it cannot read. Zero is kept: a
  # `"0"` filled size is a real answer ("nothing filled").
  defp non_negative(%Decimal{} = value),
    do: if(Decimal.negative?(value), do: nil, else: value)

  defp non_negative(nil), do: nil

  # A venue string that is not a string (a number, a map) is not carried into a field the
  # contract types as `String.t() | nil`.
  defp text_or_nil(value) when is_binary(value), do: value
  defp text_or_nil(_other), do: nil

  # A reason the venue quotes back is bounded, as `refusal/2`'s text is: it was copied whole
  # into `{:order_rejected, _}`, `{:cancel_rejected, _}` and `{:edit_rejected, _}`.
  defp bounded_text(text) when is_binary(text), do: String.slice(text, 0, @max_refusal_text)
  defp bounded_text(other), do: other

  # A row list the venue sends raw is a list of objects or it is not readable: an entry that is
  # not a map is not carried through to a consumer that will index it.
  defp map_rows(rows) do
    if Enum.all?(rows, &is_map/1), do: {:ok, rows}, else: {:error, :unexpected_response_shape}
  end

  # A quantity (a trade's or a fill's size) is above zero: a print of nothing, or of a
  # negative amount, is not an execution. Same reading as `required_price/2`.
  defp required_quantity(value, field) do
    with {:ok, parsed} <- required_decimal(value, field) do
      if Decimal.positive?(parsed),
        do: {:ok, parsed},
        else: {:error, {:non_positive_quantity, field, value}}
    end
  end

  # `"1e999999999"` is finite and parses fully, but comparing or adding it builds a
  # `10 ** 999_999_999` integer (~415 MB) in the caller's process. No amount this venue
  # quotes needs more than 64 places either side of the point; wider is refused as unreadable.
  # Not measured against the live venue.
  defp absurd_exponent?(%Decimal{exp: exp}), do: exp > 64 or exp < -64

  # A garbage or missing value in a field this contract requires must not become a `nil`
  # carried into `@enforce_keys` — a struct's field list does not check that a value is
  # non-nil, only that the key was given. Refuse the record instead of leaking a `nil`
  # price into a `Quote`/`Trade`/`Candle`, which is the same substitution a raise would
  # have been, wearing a quieter shape.
  #
  # A trade id is a non-empty STRING, as the stream's is (`Socket`'s own `required_trade_id/1`
  # refuses a number): a map, a list or a float used to be carried as the id, and a number
  # was a different value on this path than on the stream's for the same print.
  defp required_trade_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp required_trade_id(nil), do: {:error, {:missing_required_field, :id}}
  defp required_trade_id(""), do: {:error, {:missing_required_field, :id}}
  defp required_trade_id(_unreadable), do: {:error, :unexpected_response_shape}

  # A commission the venue did not state (absent, `null` or `""`) is `nil`: "did not say". One
  # it stated and this cannot read (`"abc"`, `"NaN"`, `"Infinity"`, a map) used to become the
  # same `nil` through bare `decimal/1`, which reads as a fee-free fill. Refused instead.
  defp optional_fee(value) when value in [nil, ""], do: {:ok, nil}

  defp optional_fee(value) do
    case decimal(value) do
      nil -> {:error, {:invalid_decimal, :fee, value}}
      fee -> {:ok, fee}
    end
  end

  # A fill's `trade_id` may be absent (`nil`), and when present is a string.
  defp optional_trade_id(nil), do: {:ok, nil}
  defp optional_trade_id(id) when is_binary(id), do: {:ok, id}
  defp optional_trade_id(_unreadable), do: {:error, :unexpected_response_shape}

  # `Fill` names SEVEN fields its `new/1` refuses a `nil` in — `:order_id`, `:symbol`,
  # `:side`, `:quantity`, `:price`, `:timestamp`, `:provider` — and `to_fill/1` guarded
  # three of them.
  #
  # The comment above `to_fill/1` already made the argument, and made it for exactly two
  # fields: a fill "reporting that some unstated amount traded at some unstated price is
  # worse than no fill at all". The same is true of one reporting that an unstated amount of
  # an unstated instrument traded on an unstated side, against an unstated order. Nothing
  # here calls `new/1` — the struct is built literally, as everywhere in this family — so the
  # contract's own check never runs and each of these has to be written out.
  #
  # `dp_exchange_gemini`'s `to_fill/2` guards all five of the ones a row can be missing. This
  # is the sibling that was half-swept.
  defp required_id(nil, field), do: {:error, {:missing_required_field, field}}
  defp required_id("", field), do: {:error, {:missing_required_field, field}}
  defp required_id(value, _field) when is_binary(value), do: {:ok, value}
  defp required_id(value, _field) when is_integer(value), do: {:ok, Integer.to_string(value)}

  # A map or a list is not an id, and `to_string/1` raised on it out of
  # `get_trade_history/2`. A float is not one either: `1.0e18` is not the order it names.
  defp required_id(_value, _field), do: {:error, :unexpected_response_shape}

  # An unmappable product id is refused rather than carried as `nil`. A fill whose symbol is
  # `nil` reconciles against nothing, and `canonical_or_nil/1` was answering `nil` for an
  # absent one straight into a field the contract marks required.
  defp required_symbol(nil), do: {:error, {:missing_required_field, :symbol}}

  defp required_symbol(native) do
    case canonical_or_nil(native) do
      nil -> {:error, {:missing_required_field, :symbol}}
      symbol -> {:ok, symbol}
    end
  end

  # `side_atom/1` answers `nil` for anything the venue did not name `BUY` or `SELL`, which is
  # the honest answer for a field that may legitimately be absent. On a `Fill` it is not
  # legitimate: a fill that does not say which way it went cannot be reconciled at all.
  defp required_side(value) do
    case side_atom(value) do
      nil -> {:error, {:unknown_side, value}}
      side -> {:ok, side}
    end
  end

  defp required_decimal(nil, field), do: {:error, {:missing_required_field, field}}

  defp required_decimal(value, field) do
    case decimal(value) do
      nil -> {:error, {:invalid_decimal, field, value}}
      parsed -> {:ok, parsed}
    end
  end

  # A TRADED price (a quote's, a trade's, a candle's open/high/low/close) is above zero
  # (family convention MD6). Zero and negatives parse cleanly as decimals and used to flow
  # through as a price no market printed; the item is refused instead. A bid or ask of zero
  # means "no resting order" and is not read here.
  defp required_price(value, field) do
    with {:ok, parsed} <- required_decimal(value, field) do
      if Decimal.positive?(parsed),
        do: {:ok, parsed},
        else: {:error, {:non_positive_price, field, value}}
    end
  end

  # FAILS CLOSED. A missing or unparseable venue timestamp is an error, never `now`.
  #
  # Substituting the local clock is the failure this whole family is built to refuse:
  # the value is plausible, only the meaning is wrong, so nothing downstream can tell a
  # fresh quote from a stale one. `Core.Types.Quote` says it outright — a quote whose
  # freshness we cannot state is a quote we must not return — and it enforces the field
  # precisely so this cannot be papered over.
  #
  # Note `Balance` is the deliberate exception, and for a reason that does not apply
  # here: a balance has no venue event time at all, so "when we asked" is its only
  # honest freshness. A quote has one, and if it is absent something is wrong.
  defp parse_time(nil), do: {:error, :missing_venue_timestamp}

  defp parse_time(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, reason} -> {:error, {:unparseable_venue_timestamp, reason}}
    end
  end

  defp parse_time(other), do: {:error, {:unparseable_venue_timestamp, other}}

  @doc """
  Places an order.

  ## Coinbase names the order type and the time-in-force together, and not every pair exists

  `order_configuration` is a map with exactly one key, and that key names **both** at once:
  `limit_limit_gtc`, `market_market_ioc`, `stop_limit_stop_limit_gtd`. The facade carries
  `:order_type` and `:time_in_force` separately, so this is a cross-product — and the
  product is **sparse**. There is no `limit_limit_ioc`, no `market_market_gtc`, no
  `stop_limit_stop_limit_ioc`.

  **A pair the venue does not name is an error, not the nearest key.** Sending
  `{:limit, :ioc}` as `limit_limit_fok` would place an order that fills-or-kills where the
  caller asked for immediate-or-cancel, and every field in the request would look right.
  That is the §0 substitution with money behind it.

  ## `client_order_id` is required by the venue and generated here when absent

  Coinbase requires it, and it is the venue's idempotency key: re-sending the same id
  returns the original order rather than placing a second. A caller that supplies one gets
  that protection; a caller that does not gets a UUID and no protection across retries,
  which is worth knowing rather than being quietly given. A supplied `client_order_id` must
  be a non-empty string: `""` is not an id, and sending it would give the venue one shared
  key for every such order.

  ## An answer that does not prove the order: `{:order_unconfirmed, client_order_id, reason}`

  Any outcome where the request MAY have reached the venue and success is not proven is
  `{:error, {:order_unconfirmed, client_order_id, reason}}` (`reason` bounded), never a bare
  `{:error, _}` and never `{:refused, _}`: a transport error or timeout after sending (the
  retries exhausted included), a 5xx, a `2xx` whose body is not a map or carries no `success`,
  a `success: true` without a readable `order_id` (reason `{:missing_required_field,
  :order_id}`), and `DUPLICATE_CLIENT_ORDER_ID` (the id was already used, so an earlier attempt, possibly
  this call's own internal retry, may have been placed). `client_order_id` is the id actually
  sent, **including one generated here**, so the caller can look the order up with
  `get_orders/2` before trying again. Errors decided before anything is sent (validation,
  credentials, our own rate limiter refusing, a signing failure) are plain `{:error, reason}`.
  Any 4xx to the FIRST attempt except 429 (DV6; 404 is `{:refused, :not_found}`, the rest
  `{:refused, {:venue_error, status, message}}`) is the venue answering without placing:
  `{:refused, _}`. A 429 to the first attempt is throttling and a plain `{:error, _}`. The
  same status answered to an internal retry (after a 5xx or a timeout left an earlier attempt
  possibly placed) is `{:order_unconfirmed, ...}`. Our own rate
  limiter refusing is plain only when no attempt had been sent: the signer is counted per
  attempt, so a refusal of an internal retry after an earlier attempt left the process (say
  a 5xx) is `{:order_unconfirmed, ...}`.

  ## Required fields, and fields the type does not use

  `:order_type` and `:time_in_force` are required (`{:error, {:missing_field, key}}`); there
  is no default. An unknown type is `{:error, {:unsupported_order_type, type}}`. A field the
  chosen leaf cannot carry is `{:error, {:unexpected_field, key}}`, never dropped: `:price`
  or `:stop_price` on a market order, `:stop_price` on a limit order, `:quote_size` on a
  stop-limit order, `:post_only: true`, `:end_time` and `:stop_direction` where the leaf has
  no such field. `post_only: false` is the venue's default, so on a leaf without the field it
  means "absent" and is accepted and not sent. A GTD order needs `:end_time`
  (`{:error, {:missing_field, :end_time}}`).

  A market or limit order is sized by exactly one of `:quantity` (`base_size`) or
  `:quote_size`; both is `{:error, {:unexpected_field, :quote_size}}`, neither is
  `{:error, {:missing_field, :quantity}}` (market and limit alike).
  A quote-sized order's `Order.quantity` is `nil`. A stop-limit order needs `:quantity`.

  Checks run in this order, each before anything is sent: request is a map
  (`{:invalid_order_request, request}`), unknown keys (`{:unsupported_order_field, key}`),
  symbol, side, type, time-in-force and the pair (a GTD order's `end_time`, present and
  readable, is checked here, DV10), sizing (`quantity` / `quote_size`), fields the leaf does
  not carry, price fields, the leaf's required fields (`price`, `stop_price`), `post_only`
  values, `client_order_id`, the margin and routing fields, credentials.

  ## Amounts

  `:quantity`, `:quote_size`, `:price` and `:stop_price` are accepted as a `Decimal`, an
  integer or a numeric string and refused unless they are finite and positive:
  `{:error, {:invalid_quantity | :invalid_quote_size | :invalid_price | :invalid_stop_price,
  value}}`. **A float is refused**: it has already lost digits. Amounts are always sent in
  plain (never scientific) notation. `:side` must be `:buy` or `:sell` (a string spelling is
  accepted, case-insensitively); anything else is `{:error, {:invalid_side, value}}`. A
  symbol that is not text or is blank is `{:error, {:invalid_symbol, value}}`.

  ## Perpetuals: `:leverage` and `:margin_type`

  `NewOrderRequest` carries `leverage` (a string, "default is 1.0") and `margin_type`
  (`CROSS` or `ISOLATED`, "default is CROSS") for INTX perpetuals
  (docs/reference/coinbase/openapi/at-spec.yaml:8101-8140). They are sent only when the
  request names them; they used to be dropped without a word, so an order asked at 5x was
  placed at the venue's 1x. `:leverage` is a finite positive number
  (`{:error, {:invalid_leverage, value}}`) and `:margin_type` is `:cross`, `:isolated` or
  the venue's string (`{:error, {:invalid_margin_type, value}}`). Not measured against the
  live venue.
  """
  @spec place_order(map(), term(), keyword()) ::
          {:ok, Types.Order.t()} | {:error, term()} | {:refused, term()}
  def place_order(credentials, request, opts) do
    with {:ok, plan} <- order_plan(request, :place),
         :ok <- validate_credentials(credentials) do
      body =
        Map.merge(plan.margin, %{
          "client_order_id" => plan.client_order_id,
          "product_id" => SymbolFormat.to_exchange_symbol(plan.symbol),
          "side" => plan.side |> to_string() |> String.upcase(),
          "order_configuration" => plan.configuration
        })

      calls = :atomics.new(1, signed: false)

      case post_json("/orders", body, credentials, opts, &counting(&1, calls)) do
        {:ok, %{body: response}} -> to_placed_order(response, plan)
        {:error, reason} -> write_error(reason, plan.client_order_id, {calls, opts})
      end
    end
  end

  # The venue requires the id and dedupes on it. Absent, one is generated; present, it must
  # be a usable string. `"" || generate()` kept the empty string, a whitespace-only one is no
  # id either, and a non-string reached `Jason` as whatever it was.
  defp client_order_id(nil), do: {:ok, generate_client_order_id()}

  defp client_order_id(id) when is_binary(id) do
    if String.trim(id) == "", do: {:error, {:invalid_client_order_id, id}}, else: {:ok, id}
  end

  defp client_order_id(other), do: {:error, {:invalid_client_order_id, other}}

  # `leverage` and `margin_type` of `NewOrderRequest` / `OrderPreviewRequest`, sent only when
  # the request names them (the venue's defaults are 1.0 and CROSS). `nil` is "not named".
  # Anything the venue's schema does not describe is refused rather than sent.
  #
  # **Every key of the request is either read or refused by name.** The keys below are the
  # contract's (`Core.AdapterContract`'s default request sends symbol, side, order_type,
  # time_in_force, quantity and price) and the ones `NewOrderRequest` defines that this
  # package validates and sends. The rest of the schema (`attached_order_configuration`,
  # `prediction_metadata`, `equity_order_metadata`, `cost_basis_method`) is not built here,
  # and a key such as `reduce_only` is not in the schema at all: each was dropped silently
  # and the order placed without it. `preview_id` exists on `NewOrderRequest` only.
  @request_keys [
    :symbol,
    :side,
    :order_type,
    :time_in_force,
    :quantity,
    :quote_size,
    :price,
    :stop_price,
    :stop_direction,
    :post_only,
    :end_time,
    :client_order_id,
    :leverage,
    :margin_type,
    :retail_portfolio_id,
    :sor_preference
  ]

  @sor_preferences ["SOR_PREFERENCE_UNSPECIFIED", "SOR_ENABLED", "SOR_DISABLED"]

  defp margin_fields(request) do
    with {:ok, leverage} <- leverage_field(Map.get(request, :leverage)),
         {:ok, margin_type} <- margin_type_field(Map.get(request, :margin_type)),
         {:ok, portfolio} <- string_field(request, :retail_portfolio_id),
         {:ok, preview_id} <- string_field(request, :preview_id),
         {:ok, sor} <- sor_field(Map.get(request, :sor_preference)) do
      body =
        %{}
        |> put_unless_nil("leverage", leverage)
        |> put_unless_nil("margin_type", margin_type)
        |> put_unless_nil("retail_portfolio_id", portfolio)
        |> put_unless_nil("preview_id", preview_id)
        |> put_unless_nil("sor_preference", sor)

      {:ok, body}
    end
  end

  defp known_request_keys(request, allowed) do
    case Enum.find(Map.keys(request), &(&1 not in allowed)) do
      nil -> :ok
      key -> {:error, {:unsupported_order_field, key}}
    end
  end

  defp string_field(request, key) do
    case Map.get(request, key) do
      nil -> {:ok, nil}
      value when is_binary(value) and value != "" -> {:ok, value}
      value -> {:error, {:invalid_order_field, key, value}}
    end
  end

  defp sor_field(nil), do: {:ok, nil}
  defp sor_field(value) when value in @sor_preferences, do: {:ok, value}
  defp sor_field(value), do: {:error, {:invalid_order_field, :sor_preference, value}}

  defp leverage_field(nil), do: {:ok, nil}

  defp leverage_field(value) do
    case order_amount(value) do
      %Decimal{} = leverage -> {:ok, wire_number(leverage)}
      nil -> {:error, {:invalid_leverage, value}}
    end
  end

  defp margin_type_field(nil), do: {:ok, nil}
  defp margin_type_field(:cross), do: {:ok, "CROSS"}
  defp margin_type_field(:isolated), do: {:ok, "ISOLATED"}
  defp margin_type_field(value) when value in ["CROSS", "ISOLATED"], do: {:ok, value}
  defp margin_type_field(value), do: {:error, {:invalid_margin_type, value}}

  # The sparse cross-product, written out. A pair absent from this table is absent from the
  # venue, and `order_tif_field/2` refuses rather than reaching for a neighbour.
  @configurations %{
    {:market, :ioc} => "market_market_ioc",
    {:market, :fok} => "market_market_fok",
    {:limit, :gtc} => "limit_limit_gtc",
    {:limit, :gtd} => "limit_limit_gtd",
    {:limit, :fok} => "limit_limit_fok",
    {:stop_limit, :gtc} => "stop_limit_stop_limit_gtc",
    {:stop_limit, :gtd} => "stop_limit_stop_limit_gtd"
  }

  @doc """
  The validated, normalised form of an order request: every check `place_order/3` and
  `preview_order/3` run before sending, in their order, and what they would send.

  `mode` is `:place` or `:preview` (which does not accept `:preview_id`). On success the map
  carries `:symbol`, `:side` (an atom), `:order_type`, `:time_in_force`, `:quantity`,
  `:price` and `:stop_price` (Decimals or `nil`), `:client_order_id` (the caller's, or a
  generated one) with `:client_order_id_supplied?`, and the wire `:configuration` and
  `:margin`. `DpExchange.Coinbase.Fake` builds its orders from this so it answers what the
  real path would send.
  """
  @spec order_plan(term(), :place | :preview) :: {:ok, map()} | {:error, term()}
  def order_plan(request, _mode) when not is_map(request),
    do: {:error, {:invalid_order_request, request}}

  def order_plan(request, mode) do
    allowed = if mode == :place, do: [:preview_id | @request_keys], else: @request_keys

    with :ok <- known_request_keys(request, allowed),
         {:ok, symbol} <- order_symbol_field(request),
         {:ok, side} <- order_side_field(request),
         {:ok, type} <- order_type_field(request),
         {:ok, tif} <- order_tif_field(request, type),
         :ok <- gtd_end_time(tif, request),
         {:ok, normalised} <- leaf_amounts(type, tif, request),
         {:ok, client_order_id} <- client_order_id(Map.get(request, :client_order_id)),
         {:ok, margin} <- margin_fields(request),
         {:ok, leaf} <- configuration_leaf(type, normalised) do
      {:ok,
       %{
         symbol: symbol,
         side: side,
         order_type: type,
         time_in_force: tif,
         quantity: Map.get(normalised, :quantity),
         price: Map.get(normalised, :price),
         stop_price: Map.get(normalised, :stop_price),
         client_order_id: client_order_id,
         client_order_id_supplied?: Map.get(request, :client_order_id) != nil,
         configuration: %{Map.fetch!(@configurations, {type, tif}) => leaf},
         margin: margin
       }}
    end
  end

  # `:order_type` is required, never defaulted: a missing type used to become a limit order,
  # and a request with no price and no type is not a market order either.
  @order_types [:market, :limit, :stop_limit]

  defp order_type_field(request) do
    case Map.get(request, :order_type) do
      nil -> {:error, {:missing_field, :order_type}}
      type when type in @order_types -> {:ok, type}
      other -> {:error, {:unsupported_order_type, other}}
    end
  end

  # Every leaf this venue names carries a duration in its key, so `:time_in_force` is
  # required for every type; a pair the venue does not name is refused, not neighboured.
  defp order_tif_field(request, type) do
    case Map.get(request, :time_in_force) do
      nil ->
        {:error, {:missing_field, :time_in_force}}

      tif ->
        if Map.has_key?(@configurations, {type, tif}),
          do: {:ok, tif},
          else: {:error, {:unsupported_order_combination, type, tif}}
    end
  end

  # A good-till-date order's expiry is part of its time in force (family convention step 6,
  # DV10), so it is checked HERE, before sizing and before any price field: absent is
  # `{:missing_field, :end_time}`, and one that is not a `DateTime` or a non-blank string is
  # `{:invalid_end_time, value}`. A leaf without `end_time` is refused later as
  # `{:unexpected_field, :end_time}` if the caller named one.
  defp gtd_end_time(:gtd, request) do
    case Map.get(request, :end_time) do
      nil -> {:error, {:missing_field, :end_time}}
      end_time -> valid_end_time(end_time)
    end
  end

  defp gtd_end_time(_tif, _request), do: :ok

  # What each leaf's own schema carries beyond the base size. A field outside its leaf's list
  # that the caller named is `{:unexpected_field, key}`: it used to be dropped without a word
  # (`price` on a market order, `stop_price` on a limit), so the order placed was not the one
  # asked for. `post_only`/`end_time`/`stop_direction` were refused per leaf with a 3-tuple.
  @leaf_fields %{
    {:market, :ioc} => [:quote_size],
    {:market, :fok} => [:quote_size],
    {:limit, :gtc} => [:price, :quote_size, :post_only],
    {:limit, :gtd} => [:price, :quote_size, :post_only, :end_time],
    {:limit, :fok} => [:price, :quote_size],
    {:stop_limit, :gtc} => [:price, :stop_price, :stop_direction],
    {:stop_limit, :gtd} => [:price, :stop_price, :stop_direction, :end_time]
  }
  @optional_fields [:price, :stop_price, :quote_size, :post_only, :end_time, :stop_direction]

  # Sizing, then the fields the leaf does not carry, then price fields, then the rest of the
  # leaf's own fields. Returns the request with its amounts as `Decimal`s.
  defp leaf_amounts(type, tif, request) do
    allowed = Map.fetch!(@leaf_fields, {type, tif})

    with {:ok, sized} <- order_sizing(type, request),
         sized = drop_inert_post_only(sized, allowed),
         :ok <- unexpected_fields(sized, allowed),
         {:ok, priced} <- normalise_amounts([:price, :stop_price], sized),
         :ok <- required_leaf_field(priced, allowed, :price),
         :ok <- required_leaf_field(priced, allowed, :stop_price),
         {:ok, _post_only} <- post_only(priced) do
      {:ok, priced}
    end
  end

  # `post_only: false` is the venue's default, so on a leaf with no such field it means
  # "absent" and sends nothing; `true` (or anything else) there stays `{:unexpected_field, _}`.
  defp drop_inert_post_only(request, allowed) do
    if :post_only not in allowed and Map.get(request, :post_only) == false,
      do: Map.delete(request, :post_only),
      else: request
  end

  # A market or limit order sizes in base (`quantity`) or quote (`quote_size`), exactly one
  # (all five leaves of those two types carry both fields in the spec); a stop-limit leaf
  # carries `base_size` only and needs a base `quantity`.
  defp order_sizing(type, request) when type in [:market, :limit] do
    with {:ok, request} <- normalise_amounts([:quantity, :quote_size], request) do
      case {Map.get(request, :quantity), Map.get(request, :quote_size)} do
        {nil, nil} -> {:error, {:missing_field, :quantity}}
        {_quantity, nil} -> {:ok, request}
        {nil, _quote_size} -> {:ok, request}
        {_quantity, _quote_size} -> {:error, {:unexpected_field, :quote_size}}
      end
    end
  end

  defp order_sizing(_type, request) do
    with {:ok, _quantity} <- required_field(request, :quantity, {:missing_field, :quantity}) do
      normalise_amounts([:quantity], request)
    end
  end

  defp unexpected_fields(request, allowed) do
    case Enum.find(@optional_fields, &(&1 not in allowed and Map.get(request, &1) != nil)) do
      nil -> :ok
      field -> {:error, {:unexpected_field, field}}
    end
  end

  defp required_leaf_field(request, allowed, field) do
    if field in allowed and Map.get(request, field) == nil,
      do: {:error, {:missing_field, field}},
      else: :ok
  end

  defp valid_end_time(%DateTime{}), do: :ok

  defp valid_end_time(value) when is_binary(value) do
    if String.trim(value) == "", do: {:error, {:invalid_end_time, value}}, else: :ok
  end

  defp valid_end_time(value), do: {:error, {:invalid_end_time, value}}

  # Every money field is parsed to a finite, positive `Decimal` before anything is built.
  # `wire_number/1` used to `to_string/1` whatever it was given: a float `1.0e-8` went out as
  # `"1.0e-8"` (an exponent the venue does not read), `"abc"` and `""` went out as-is, and
  # `0` or a negative size was sent for the venue to reject on a field it might not name.
  # A float is refused outright now: it has lost digits before it gets here.
  defp normalise_amounts([], map), do: {:ok, map}

  defp normalise_amounts([field | rest], map) do
    with {:ok, map} <- normalise_amount(map, field) do
      normalise_amounts(rest, map)
    end
  end

  defp normalise_amount(map, field) do
    case Map.get(map, field) do
      nil ->
        {:ok, map}

      value ->
        case order_amount(value) do
          %Decimal{} = amount -> {:ok, Map.put(map, field, amount)}
          nil -> {:error, amount_error(field, value)}
        end
    end
  end

  defp amount_error(:quantity, value), do: {:invalid_quantity, value}
  defp amount_error(:size, value), do: {:invalid_quantity, value}
  defp amount_error(:quote_size, value), do: {:invalid_quote_size, value}
  defp amount_error(:price, value), do: {:invalid_price, value}
  defp amount_error(:stop_price, value), do: {:invalid_stop_price, value}

  defp order_amount(value) when is_float(value), do: nil

  defp order_amount(value) do
    case decimal(value) do
      %Decimal{} = amount ->
        if usable_positive?(amount), do: amount

      nil ->
        nil
    end
  end

  # Finite, positive and not absurdly scaled. `decimal/1` bounds a parsed string's exponent
  # but passes a `%Decimal{}` or float through as given, and `wire_number/1` renders in plain
  # notation: `%Decimal{coef: 1, exp: 999_999_999}` is a billion-character string built in
  # the caller's process, and `1.0e300` is a 301-digit "price". Not measured against the
  # live venue; see `absurd_exponent?/1`.
  defp usable_positive?(%Decimal{} = amount) do
    not Decimal.nan?(amount) and not Decimal.inf?(amount) and not absurd_exponent?(amount) and
      Decimal.positive?(amount)
  end

  # The wire leaf, built from the amounts `leaf_amounts/3` already normalised and checked.
  #
  # Coinbase's per-leaf schemas do not all carry the same optional fields. `post_only` exists
  # on `LimitLimitGtc` and `LimitLimitGtd` but not `LimitLimitFok` or either stop-limit leaf;
  # `end_time` exists on `LimitLimitGtd` and `StopLimitStopLimitGtd` only; `stop_direction`
  # exists on both stop-limit leaves and nowhere else
  # (docs/reference/coinbase/openapi/at-spec.yaml:7765-7783 for the three limit leaves,
  # :9596-9650 for the two stop-limit leaves). `@leaf_fields` records that per `{type, tif}`
  # and `unexpected_fields/2` refuses a field outside it, so a field present here is one the
  # leaf's own schema names; this function only has to render what is there.
  #
  # Both sizes on a market order is two different orders: `quantity` silently won once, so
  # "spend $100" with a `quantity: 5` beside it bought five units at whatever they cost.
  # Refused in `order_sizing/2`, not chosen.
  defp configuration_leaf(:market, request), do: {:ok, size_entry(request)}

  defp configuration_leaf(_type, request) do
    with {:ok, post_only} <- post_only(request),
         {:ok, direction} <- stop_direction(Map.get(request, :stop_direction)) do
      leaf =
        request
        |> size_entry()
        |> Map.put("limit_price", wire_number(Map.fetch!(request, :price)))
        |> put_unless_nil("stop_price", Map.get(request, :stop_price))
        |> put_unless_nil("post_only", post_only)
        |> put_unless_nil("stop_direction", direction)
        |> put_end_time(Map.get(request, :end_time))

      {:ok, leaf}
    end
  end

  # `base_size` or `quote_size`, whichever `order_sizing/2` left (never both).
  defp size_entry(request) do
    case {Map.get(request, :quantity), Map.get(request, :quote_size)} do
      {nil, quote_size} -> %{"quote_size" => wire_number(quote_size)}
      {quantity, _none} -> %{"base_size" => wire_number(quantity)}
    end
  end

  # `StopPriceDirection`'s enum is `STOP_DIRECTION_STOP_UP` / `STOP_DIRECTION_STOP_DOWN`
  # (docs/reference/coinbase/openapi/at-spec.yaml:9654-9660). `:up`/`:down` is the convenient
  # shorthand; a caller who already has the venue's own string can pass that through
  # unchanged. **Never inferred from `side`** — a stop's trigger direction is a trading
  # decision the caller makes, not a fact this package can derive from which side of the
  # book the order is on, and guessing it would be exactly the substitution this family
  # refuses on a call that places a live order.
  defp stop_direction(nil), do: {:ok, nil}
  defp stop_direction(:up), do: {:ok, "STOP_DIRECTION_STOP_UP"}
  defp stop_direction(:down), do: {:ok, "STOP_DIRECTION_STOP_DOWN"}
  @stop_directions ["STOP_DIRECTION_STOP_UP", "STOP_DIRECTION_STOP_DOWN"]

  defp stop_direction(value) when value in @stop_directions, do: {:ok, value}

  # Any other string is outside the spec's enum and its handling by the venue is unmeasured:
  # refused, not sent on a live order.
  defp stop_direction(other), do: {:error, {:invalid_stop_direction, other}}

  # `post_only` is a JSON boolean. A string such as `"yes"` was stringified and sent.
  defp post_only(request) do
    case Map.get(request, :post_only) do
      value when is_nil(value) or is_boolean(value) -> {:ok, value}
      other -> {:error, {:invalid_post_only, other}}
    end
  end

  defp put_unless_nil(map, _key, nil), do: map

  defp put_unless_nil(map, key, %Decimal{} = value),
    do: Map.put(map, key, wire_number(value))

  # `post_only` is documented as a JSON boolean
  # (docs/reference/coinbase/openapi/at-spec.yaml:7803, :7839) — `true`/`false`, not the
  # string `"true"`. The catch-all clause below stringified everything through `to_string/1`,
  # which is right for an enum atom or a plain string but turns a boolean into a string the
  # venue's schema does not accept for this field. Matched ahead of the catch-all so a
  # boolean is put through unchanged and Jason encodes it as JSON `true`/`false`.
  defp put_unless_nil(map, key, value) when is_boolean(value), do: Map.put(map, key, value)

  # A list is an `explode: true` array, kept a list so `query/1` sends one key per element.
  # `to_string/1` concatenated it: `["OPEN", "PENDING"]` went out as `OPENPENDING`.
  defp put_unless_nil(map, key, values) when is_list(values),
    do: Map.put(map, key, Enum.map(values, &to_string/1))

  defp put_unless_nil(map, key, value), do: Map.put(map, key, to_string(value))

  # `end_time` is documented as an RFC3339 timestamp
  # (docs/reference/coinbase/openapi/at-spec.yaml:7828-7831, :9640-9643). `to_string/1` on a
  # `%DateTime{}` goes through `String.Chars`, which renders `"2021-05-31 09:59:59Z"` — a
  # space where RFC3339 requires `T` — and is not a timestamp this venue reads.
  # `DateTime.to_iso8601/1` is the one that produces the `T` separator the format requires.
  defp put_end_time(leaf, nil), do: leaf

  defp put_end_time(leaf, %DateTime{} = value),
    do: Map.put(leaf, "end_time", DateTime.to_iso8601(value))

  defp put_end_time(leaf, value) when is_binary(value), do: Map.put(leaf, "end_time", value)

  # **`Decimal.to_string/1` defaults to SCIENTIFIC notation, and `to_string/1` on a
  # `%Decimal{}` goes through `String.Chars` to the same default.** So a price or size that
  # carries an exponent is serialised as `"1.5E+2"` or `"1E-8"` — which is not a number this
  # venue reads, and is a different order if it reads it at all.
  #
  # An exponent is not exotic. `Decimal.normalize/1` — the ordinary way to strip trailing
  # zeros — turns `150.00` into `1.5E+2`, and anything below a millionth carries one by
  # construction: `Decimal.new("0.00000001")` is `1E-8`.
  #
  # Four of the five venue packages already said this somewhere: `Prime.convert_params/3`
  # in this very repo, `dp_exchange_robinhood`'s `decimal_string/1` ("Full notation, never
  # scientific: `1.0e-4` is not a quantity this venue reads"), and two others. None of them
  # covered the ORDER path, which is the one that spends money.
  #
  # Only a `%Decimal{}` is accepted: every caller passes an amount `normalise_amounts/2` (or
  # `order_amount/1`) already turned into one, so a `to_string/1` fallback for anything else
  # was unreachable and would only have re-opened the hole this comment describes.
  defp wire_number(%Decimal{} = value), do: Decimal.to_string(value, :normal)

  # The venue's own object, sent as it was given. `put_unless_nil/3` stringifies, which turns
  # a nested map into its inspect form and the venue into a caller error.
  defp put_raw_unless_nil(map, _key, nil), do: map
  defp put_raw_unless_nil(map, key, value), do: Map.put(map, key, value)

  # The fields every order names. `Map.fetch!/2` raised `KeyError` in the caller's process
  # for each of them, on a money-moving call; a request that is not a map is refused by
  # `order_plan/2` before any of these run.
  defp order_symbol_field(request) do
    # An absent symbol is `{:invalid_symbol, nil}`, not `{:missing_field, :symbol}` (DV2): the
    # same tag as a blank or non-text one, on every venue of the family.
    symbol = Map.get(request, :symbol)

    with :ok <- order_symbol(symbol), do: {:ok, symbol}
  end

  defp order_side_field(request) do
    with {:ok, side} <- required_field(request, :side, {:missing_field, :side}) do
      order_side(side)
    end
  end

  # Blank after trimming is no product either (`Feed.check_symbols/1` refuses it too); a
  # whitespace-only symbol built `/products/%20/ticker`.
  defp order_symbol(symbol) when is_binary(symbol) do
    if String.trim(symbol) == "", do: {:error, {:invalid_symbol, symbol}}, else: :ok
  end

  defp order_symbol(symbol), do: {:error, {:invalid_symbol, symbol}}

  # `side |> to_string() |> String.upcase()` sent whatever it was given: `:hold` went out as
  # `"HOLD"` and `"buyy"` as `"BUYY"`, for the venue to reject (or, on a future enum value,
  # to accept). Only the two sides that exist are sent, and always as the atom the returned
  # `Order` carries.
  defp order_side(side) when side in [:buy, :sell], do: {:ok, side}

  defp order_side(side) when is_binary(side) do
    case String.downcase(side) do
      "buy" -> {:ok, :buy}
      "sell" -> {:ok, :sell}
      _other -> {:error, {:invalid_side, side}}
    end
  end

  defp order_side(side), do: {:error, {:invalid_side, side}}

  defp required_field(request, key, error) do
    case Map.get(request, key) do
      nil -> {:error, error}
      value -> {:ok, value}
    end
  end

  # The venue answers 200 with `success: false` for a rejected order. Treating that as a
  # placed order is the failure this clause exists to prevent — the HTTP call succeeded and
  # the order did not.
  #
  # `success: true` means an order is live at the venue. That was once returned as `{:ok, _}`
  # even when the body's id was unreadable (`id: nil`), on the argument (2026-10-10) that an
  # `{:error, _}` reads as "nothing was placed" and a caller retrying on it places a second
  # order. `{:order_unconfirmed, ...}` makes the opposite claim, that the order MAY be live,
  # and carries the `client_order_id` to look it up with, which is why it replaced the `nil`
  # id (see below).
  #
  # The same holds when `success_response` is missing altogether: `success` is the only field
  # the spec requires on `NewOrderResponse` (at-spec.yaml:8177-8198), and an absent object is
  # no more evidence that nothing was placed than an unreadable one.
  #
  # **Superseded 2026-10-12 (family convention DV5).** An order the caller cannot name is not
  # an order it can manage: a `2xx` without a readable `order_id` is
  # `{:order_unconfirmed, client_order_id, {:missing_required_field, :order_id}}`, which says
  # the order MAY be live and hands back the id to look it up with (`get_orders/2`), instead
  # of `{:ok, %Order{id: nil}}`. `Core.Types.Order` requires an id. Still no retry on it.
  defp to_placed_order(%{"success" => true} = response, plan) do
    case response |> Map.get("success_response") |> success_order_id() do
      nil -> unconfirmed(plan.client_order_id, {:missing_required_field, :order_id})
      id -> {:ok, placed_order(id, plan)}
    end
  end

  # `DUPLICATE_CLIENT_ORDER_ID` is the venue saying the id was used before, which after an
  # internal retry means THIS call's earlier attempt may have been placed. Refusing it as a
  # rejection told the caller nothing was placed and invited a second order under a new id.
  defp to_placed_order(%{"success" => false} = response, plan) do
    reason = failure_reason(response)

    if duplicate_client_order_id?(reason),
      do: unconfirmed(plan.client_order_id, :duplicate_client_order_id),
      else: {:refused, {:order_rejected, reason}}
  end

  # A 2xx that is not a map, or is a map without `success`, proves nothing either way: the
  # request reached the venue and what came back cannot be read as a yes or a no.
  defp to_placed_order(_other, plan),
    do: unconfirmed(plan.client_order_id, :unexpected_response_shape)

  defp placed_order(id, plan) do
    %Types.Order{
      id: id,
      symbol: plan.symbol,
      side: plan.side,
      order_type: plan.order_type,
      time_in_force: plan.time_in_force,
      # Decimals, the type `Order` declares; normalised by `order_plan/2`.
      quantity: plan.quantity,
      price: plan.price,
      stop_price: plan.stop_price,
      status: :pending,
      provider: :coinbase
    }
  end

  defp duplicate_client_order_id?(reason) when is_binary(reason),
    do: String.contains?(reason, "DUPLICATE_CLIENT_ORDER_ID")

  defp duplicate_client_order_id?(_reason), do: false

  # **Unconfirmed writes.** The outcome of a write that may have reached the venue without
  # proof that it did or did not act: carries the `client_order_id` actually sent (nil where
  # the write has none) so the caller can look the order up before trying again.
  defp unconfirmed(client_order_id, reason),
    do: {:error, {:order_unconfirmed, client_order_id, bounded_reason(reason)}}

  # An error from `post_json/4` for a write. A venue answer in the 4xx refusal set is a
  # refusal; a failure decided BEFORE anything left this process (our own rate limiter, a
  # signing or encoding failure) is a plain error; anything else may have reached the venue.
  #
  # `counted` is `{calls, opts}`, `calls` being the `counting/2` counter of this call's
  # signer, or `nil` for a write sent once. A pre-send failure is plain only when NO attempt
  # was sent before it: the same limiter refusal on a retry, after a first attempt left the
  # process, is unconfirmed.
  defp write_error(reason, client_order_id, counted),
    do: tagged_write_error(reason, client_order_id, counted, &unconfirmed/2)

  # The same decision for a write that is not an order (family convention W1): `key` is the
  # correlation key actually sent (`nil` where the write carries none) and the answer is
  # `{:error, {:write_unconfirmed, key, reason}}`.
  defp write_failure(reason, key, counted \\ nil),
    do: tagged_write_error(reason, key, counted, &write_unconfirmed/2)

  defp write_unconfirmed(key, reason),
    do: {:error, {:write_unconfirmed, key, bounded_reason(reason)}}

  defp tagged_write_error(reason, key, counted, build) do
    case write_classify(reason) do
      # A 4xx answered to an internal RETRY (family convention W2): an earlier attempt of this
      # same call already left the process (a 5xx or a timeout), and the venue objecting to
      # the repeat does not say that attempt placed nothing. Only a first attempt's 4xx is a
      # refusal.
      {:refused, refusal} = refused ->
        if attempts_made(counted) > 1, do: build.(key, refusal), else: refused

      {:error, inner} ->
        cond do
          pre_send_failure?(reason) and sent_attempts(counted) == 0 -> {:error, inner}
          # A 429 to the FIRST attempt: the venue throttled the request before acting on it,
          # which is a plain, retryable error (DV6). Answered to a retry it proves nothing
          # about the attempt before it, so it falls through to unconfirmed.
          too_many_requests?(reason) and attempts_made(counted) <= 1 -> {:error, inner}
          true -> build.(key, inner)
        end
    end
  end

  # DV6: EVERY 4xx the venue answers to a write's first attempt is a refusal of that request
  # (409, 415, 422 and the rest included), except 429, which is throttling and stays a plain
  # error. A 404 keeps `classify/1`'s own `:not_found`. Reads keep `classify/2`: only a write
  # has an unconfirmed class that a bare 4xx would otherwise fall into.
  defp write_classify({:http_status, status, body})
       when status in 400..499 and status not in [404, 429],
       do: {:refused, refusal(status, body)}

  defp write_classify(reason), do: classify(reason)

  # `Core.HttpClient` handles a venue 429 itself (the held bucket, `Retry-After`) and answers
  # it as this tagged message whether or not `raw_status` is set, so there is never a
  # `{:http_status, 429, _}` to match here.
  defp too_many_requests?({:exchange_error, _venue, "Rate limited by the venue" <> _rest}),
    do: true

  defp too_many_requests?(_reason), do: false

  # How many attempts of this call were signed and sent when a response (even a 4xx) came
  # back: every signature of an attempt that got an answer was sent. `nil` is a write sent once.
  defp attempts_made(nil), do: 1

  defp attempts_made({calls, opts}) do
    signed = :atomics.get(calls, 1)
    if Config.opt(opts, :rate_limit_blocking, false), do: div(signed, 2), else: signed
  end

  # `Core.HttpClient` signs once per attempt, just before the limiter is asked (twice per
  # attempt with a blocking limiter), so the count tells how many attempts really left the
  # process: the last signature of a pre-send failure was never sent.
  defp counting(signer, calls) do
    fn ->
      :atomics.add(calls, 1, 1)
      signer.()
    end
  end

  defp sent_attempts(nil), do: 0

  defp sent_attempts({calls, opts}) do
    signed = :atomics.get(calls, 1)

    if Config.opt(opts, :rate_limit_blocking, false),
      do: div(signed, 2),
      else: max(signed - 1, 0)
  end

  defp pre_send_failure?({:exchange_error, _venue, :rate_limit_timeout}), do: true

  defp pre_send_failure?({:exchange_error, _venue, "Throttled by our own rate limiter" <> _rest}),
    do: true

  defp pre_send_failure?({:exchange_error, _venue, "Rate limiter unavailable"}), do: true
  defp pre_send_failure?({:exchange_error, _venue, _reason}), do: false

  # DELIBERATE DEFENSIVE CLAUSES, unreachable today: a response (or an oversized one) means
  # the request left the process, so these must never fall into the catch-all below, which
  # reads "decided before anything was sent". `request_opts` always sets `provider`, so
  # `Core.HttpClient` wraps `:response_too_large` in an `:exchange_error`, and the only
  # `{:http_status, _, _}` a write sees is a 4xx that `write_classify/1` has already turned
  # into a refusal (404 and 429 included: 429 is the client's own tagged message). Should
  # either shape ever arrive bare, it fails closed as unconfirmed rather than plain.
  defp pre_send_failure?({:http_status, _status, _body}), do: false
  defp pre_send_failure?({:response_too_large, _limit}), do: false
  # What is left is raised before the request: the header function's signing error or
  # `:unencodable_body`.
  defp pre_send_failure?(_local), do: true

  @max_unconfirmed_text 256

  defp bounded_reason(reason) when is_atom(reason), do: reason

  defp bounded_reason(reason) when is_binary(reason),
    do: String.slice(reason, 0, @max_unconfirmed_text)

  defp bounded_reason({:exchange_error, venue, message}) when is_atom(venue),
    do: {:exchange_error, venue, bounded_reason(message)}

  defp bounded_reason({:missing_required_field, field}) when is_atom(field),
    do: {:missing_required_field, field}

  defp bounded_reason(reason) do
    reason
    |> inspect(limit: 20, printable_limit: 200)
    |> String.slice(0, @max_unconfirmed_text)
  end

  # `NewOrderErrorResponse` (place_order's and close_position's shared error shape — both
  # `NewOrderResponse.error_response` and `ClosePositionResponse.error_response` are the
  # same schema) declares `new_order_failure_reason` **required**
  # (docs/reference/coinbase/openapi/at-spec.yaml:7962-7967) — the current, coded reason.
  # `error` is the same information under the field it replaced, marked "(Deprecated)"
  # (at-spec.yaml:7947-7950) but still the venue's own field, so it stays as a fallback
  # rather than being dropped. `message` and `error_details` are prose, not a code, and sit
  # between the two: read when the structured reason is somehow absent despite being
  # required, ahead of the deprecated field.
  #
  # The clause this replaced matched a top-level `"failure_reason"` key. That field is real,
  # but it belongs to `CancelOrderResponse` (at-spec.yaml:6389-6394) — a schema neither of
  # this function's two callers is ever handed; `cancel_order/3` reads it inline at its own
  # call site instead. Kept here, it matched nothing either schema sends and would have
  # quietly done so forever without a fixture ever exercising it.
  #
  # Every reason is bounded (`bounded_text/1`): a venue string went whole into the
  # `{:order_rejected, _}` / `{:close_rejected, _}` the caller logs.
  defp failure_reason(%{"error_response" => %{"new_order_failure_reason" => reason}})
       when is_binary(reason),
       do: bounded_text(reason)

  defp failure_reason(%{"error_response" => %{"message" => message}})
       when is_binary(message),
       do: bounded_text(message)

  defp failure_reason(%{"error_response" => %{"error_details" => details}})
       when is_binary(details),
       do: bounded_text(details)

  defp failure_reason(%{"error_response" => %{"error" => error}}) when is_binary(error),
    do: bounded_text(error)

  defp failure_reason(_response), do: :unspecified

  # A POST carrying a JSON body. Separate from `request/5` rather than an extra parameter on
  # it, because every existing caller is a GET and adding an argument to all of them to
  # serve one is how a helper becomes hard to read.
  #
  # The body is **not** signed: this venue's JWT is scoped to the method and URI, so the
  # signature does not cover the payload (see `Auth.rest_headers/4`, whose body argument is
  # ignored on purpose).
  defp post_json(path, body, credentials, opts, wrap \\ &Function.identity/1),
    do: json_request(:post, path, body, credentials, opts, wrap)

  # One attempt, for a write the venue cannot tell from its own repeat. `Core.HttpClient`
  # retried a 5xx or a transport error three times by default (a non-GET is now sent once
  # unless a caller opts in, but this forces it either way), and neither says whether the
  # venue acted before it answered. A timed-out `move_funds` retried moves the funds again,
  # and so does a retried sweep. A retried `convert/trade` commit or `orders/edit` that
  # already took effect comes back refused, telling the caller a success failed, and a
  # retried portfolio create leaves a duplicate. None carries an idempotency key this
  # package can supply. `place_order/3` and `close_position/3` carry `client_order_id` and
  # keep their retries.
  #
  # `Keyword.put`, not `put_new`: "sent once" is a guarantee, so a caller's `retry_attempts: 3`
  # cannot turn a transfer or a cancel into three sends.
  defp post_once(path, body, credentials, opts),
    do: post_json(path, body, credentials, once(opts))

  # The same one attempt for a `DELETE`, whose repeat after a lost answer is a 404 for a
  # deletion that happened.
  defp once(opts), do: Keyword.put(opts, :retry_attempts, 1)

  # **Every caller of this function is a write, and there is no public path for one.** So
  # unlike `request/5` there is no anonymous branch here: credentials that cannot sign
  # refuse locally, by name, rather than producing an unauthenticated POST for the venue
  # to reject as an opaque 401. A malformed `api_secret` reaching `place_order/3` used to
  # do exactly that.
  defp json_request(method, path, body, credentials, opts, wrap) do
    # Core retries a non-GET once by default; the paths that reach here without `once/1` are
    # safe to repeat, so three attempts are requested explicitly (a caller can still lower
    # it): an order or close carries `client_order_id`, which the venue treats as an
    # idempotency key; a preview, a convert quote and the same-value PUT/setting writes
    # change nothing a repeat could double. Every send re-signs.
    opts = Keyword.update(opts, :retry_attempts, 3, &(&1 || 3))
    signer = wrap.(signer(method, @api_path <> path, credentials))
    send_json_request(method, path, signer, body, opts)
  end

  defp send_json_request(method, path, headers, body, opts) do
    request_opts =
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
      |> Keyword.put(:raw_status, true)
      |> Keyword.put_new(:limiter, Config.opt(opts, :limiter, DpExchange.Coinbase.RateLimiter))

    # `trade_incentive_metadata` is the caller's own term, sent as given, so it can be
    # something Jason has no encoding for; that was a `Protocol.UndefinedError` raised in the
    # caller's process on a money-moving call. Refused as a value, before anything is sent.
    with {:ok, encoded} <- encode_body(body) do
      method
      |> HttpClient.request(@base_url <> @api_path <> path, headers, encoded, request_opts)
      |> split_status()
    end
  end

  defp encode_body(body) do
    {:ok, Jason.encode!(body)}
  rescue
    _error in [Protocol.UndefinedError, Jason.EncodeError] -> {:error, :unencodable_body}
  end

  # A v4 UUID from the VM's own CSPRNG, rather than a dependency.
  #
  # Coinbase requires `client_order_id` and treats it as an idempotency key: re-sending one
  # returns the original order instead of placing a second. That makes it worth generating
  # correctly — a colliding id would silently return someone else's order — and not worth a
  # library for sixteen bytes.
  # Moved to `DpExchange.Coinbase.IdempotencyKey` when `Prime`'s staking calls turned out to
  # need the same thing under the venue's other name for it, `idempotency_key`. Two copies
  # inside one package is the shape `Core.Fanout`'s moduledoc records at five-package scale:
  # a fix lands in one copy and not the other.
  defp generate_client_order_id, do: IdempotencyKey.generate()

  @doc """
  Cancels an order.

  ## The venue has no single-order cancel, and the batch one refuses per order

  Coinbase cancels through `POST /orders/batch_cancel`, which takes `order_ids` and answers
  with a `results` array — one entry per id, each with its own `success` and
  `failure_reason`. A batch of one is still a batch, so **the HTTP call succeeding says
  nothing about whether the order was cancelled**.

  A caller asking to cancel one order gets one answer: the result for that id, or a refusal
  carrying the venue's reason. An order already filled or already cancelled comes back as a
  refusal rather than an `:ok`, because "I cancelled it" and "it was not there to cancel"
  are different facts and a caller retrying on the second is chasing nothing.
  """
  @spec cancel_order(map(), String.t(), keyword()) ::
          {:ok, :cancelled} | {:error, term()} | {:refused, term()}
  def cancel_order(credentials, order_id, opts) do
    # `[nil]` or `[""]` is a batch that names no order; the venue's per-row answer for it
    # would be `order_not_in_response` at best. Refused before anything is sent.
    with :ok <- validate_order_id(order_id) do
      # Once, as `post_once/4` says: a cancel that took effect before a lost answer, retried,
      # comes back "not there to cancel", a refusal for an order this call did cancel.
      case post_once("/orders/batch_cancel", %{"order_ids" => [order_id]}, credentials, opts) do
        {:ok, %{body: body}} -> cancel_result(body, order_id)
        {:error, reason} -> classify(reason)
      end
    end
  end

  defp cancel_result(%{"results" => results}, order_id) when is_list(results) do
    # A row that is not an object cannot be about this order; it used to raise here.
    case Enum.find(results, &(is_map(&1) and &1["order_id"] == order_id)) do
      %{"success" => true} ->
        {:ok, :cancelled}

      # Bounded, and a string: a venue's `failure_reason` was copied whole into the return
      # value (a whole error page, or a map), as `refusal/2`'s text never was.
      %{"success" => false, "failure_reason" => reason} when is_binary(reason) ->
        {:refused, {:cancel_rejected, bounded_text(reason)}}

      # The venue answered about orders, and none of them was the one asked about. That is
      # not a cancelled order and it is not an error from the transport either.
      nil ->
        {:error, :order_not_in_response}

      # A row for this order that is neither a success nor a stated failure: `success: false`
      # with no `failure_reason`, or a non-boolean `success`. This used to raise
      # `CaseClauseError` in the caller's process (found 2026-10-10 by reading the clauses).
      # Neither cancelled nor refused for a stated reason, so nothing is claimed.
      _malformed ->
        {:error, :unexpected_response_shape}
    end
  end

  defp cancel_result(_body, _order_id), do: {:error, :unexpected_response_shape}

  @doc """
  One order by its venue id.

  The venue wraps it as `%{"order" => ...}`. A response without that key is an unreadable
  answer rather than a missing order — the second would be a refusal, and telling them
  apart is what stops a caller treating a parse failure as "no such order".
  """
  @spec get_order(map(), String.t(), keyword()) ::
          {:ok, Types.Order.t()} | {:error, term()} | {:refused, term()}
  def get_order(credentials, order_id, opts) do
    # `""` would build `/orders/historical/`, a different endpoint, `"  "` an id of spaces,
    # and `nil` or a map would be interpolated into the path. None names an order.
    with :ok <- validate_order_id(order_id) do
      case request(:get, "/orders/historical/#{segment(order_id)}", credentials, opts) do
        {:ok, %{body: %{"order" => order}}} when is_map(order) -> to_order(order)
        {:ok, %{body: _other}} -> {:error, :unexpected_response_shape}
        {:error, reason} -> classify(reason)
      end
    end
  end

  @doc """
  Orders, most recent first.

  `:status` and `:symbol` in `opts` filter at the venue rather than here — a client-side
  filter over one page would silently drop matching orders that were on the next one. Each
  takes one value or a list (`status: [:open, :pending]`), sent as the spec's repeated
  `order_status` / `product_ids` keys.

  `:limit` is the venue's **page size**, not a cap on the result: the walk below collects
  every page, so a caller wanting at most N orders takes them from the list.

  **This follows the venue's cursor to the end**, bounded by `@max_order_pages`.

  It used to return one page and say so, on the reasoning that a stated limit is better than
  a total worth trusting. The statement was honest and the behaviour was still wrong: the
  same doc named the harm — "a caller reconciling positions against a truncated order list
  would find a difference it could not explain" — and this module already refuses to accept
  that shape twice over, for `get_balances/2` ("a truncated balance list is the worst shape
  this family has: every number in it is real") and for `get_trade_history/2`. An order list
  is the same shape and the same envelope.

  A venue that sends no cursor is unaffected: the walk stops on the first page, exactly as
  before. A server that always says `has_next` answers `{:error, :history_truncated}`
  rather than looping inside a facade call.

  A page that says `has_next: true` but carries no cursor is
  `{:error, :pagination_cursor_missing}` — the venue promised more and gave no way to ask
  for it, and returning the first page as the whole list is the truncation this walk exists
  to prevent. An empty page carrying `proof_token_required: true` is
  `{:refused, :proof_token_required}`. A row with no readable `order_id` refuses the list.
  """
  @spec get_orders(map(), keyword()) ::
          {:ok, [Types.Order.t()]} | {:error, term()} | {:refused, term()}
  def get_orders(credentials, opts) do
    with :ok <- validate_order_filters(opts),
         {:ok, orders} <- all_orders(credentials, opts, nil, [], 0) do
      # A row that is not an object refuses the whole list. It used to raise out of
      # `to_order/1`; skipping it instead would hand back the truncated order list this
      # function's doc already names as the wrong shape.
      if Enum.all?(orders, &is_map/1),
        do: decode_orders(orders),
        else: {:error, :unexpected_response_shape}
    end
  end

  defp decode_orders(rows) do
    rows |> Enum.reduce_while({:ok, []}, &accumulate_order/2) |> reversed() |> distinct_orders()
  end

  # One order listed twice (a page boundary that overlaps) is double-counted exposure when a
  # consumer sums open orders; which copy is current is the venue's to say, so it is refused.
  defp distinct_orders({:ok, orders} = result) do
    if unique_by?(orders, & &1.id), do: result, else: {:error, :unexpected_response_shape}
  end

  defp distinct_orders(other), do: other

  defp accumulate_order(row, {:ok, acc}) do
    case to_order(row) do
      {:ok, order} -> {:cont, {:ok, [order | acc]}}
      error -> {:halt, error}
    end
  end

  defp reversed({:ok, list}), do: {:ok, Enum.reverse(list)}
  defp reversed(error), do: error

  @max_order_pages 50

  defp all_orders(_credentials, _opts, _cursor, _acc, page) when page >= @max_order_pages,
    do: {:error, :history_truncated}

  defp all_orders(credentials, opts, cursor, acc, page) do
    params =
      %{}
      |> put_unless_nil("order_status", opts |> Keyword.get(:status) |> order_status_param())
      |> put_unless_nil("product_ids", venue_symbol(Keyword.get(opts, :symbol)))
      |> put_unless_nil("retail_portfolio_id", Keyword.get(opts, :portfolio))
      |> put_unless_nil("limit", Keyword.get(opts, :limit))
      |> put_unless_nil("cursor", cursor)

    case request(:get, "/orders/historical/batch", credentials, opts, params) do
      {:ok, %{body: %{"orders" => orders} = body}} when is_list(orders) ->
        collected = [orders | acc]

        # Same envelope and same reading as `all_accounts/5`: the venue's own `has_next`,
        # and a cursor that is actually a cursor. A venue that sends neither stops here,
        # which is what every response looked like before this walked at all. `has_next`
        # without a cursor is an error (see `next_cursor/2`), and so is an empty page that
        # says `proof_token_required`: the history is withheld, not empty.
        with {:ok, step} <- order_step(body, orders, cursor) do
          case step do
            {:next, next} -> all_orders(credentials, opts, next, collected, page + 1)
            :done -> {:ok, collected |> Enum.reverse() |> Enum.concat()}
          end
        end

      {:ok, %{body: _other}} ->
        {:error, :unexpected_response_shape}

      {:error, reason} ->
        classify(reason)
    end
  end

  defp order_step(%{"proof_token_required" => true}, [], _cursor),
    do: {:refused, :proof_token_required}

  defp order_step(body, _orders, cursor) do
    case next_cursor(body, cursor) do
      {:error, _reason} = error -> error
      step -> {:ok, step}
    end
  end

  defp order_status_param(nil), do: nil

  defp order_status_param(statuses) when is_list(statuses),
    do: Enum.map(statuses, &order_status_param/1)

  defp order_status_param(status) when is_atom(status) or is_binary(status),
    do: status |> to_string() |> String.upcase()

  # The filter must be one of `OrderExecutionStatus`'s values (at-spec.yaml:8577-8589); the
  # venue's handling of any other word is unmeasured, so it is refused rather than sent.
  @status_filters ~w(PENDING OPEN FILLED CANCELLED EXPIRED FAILED UNKNOWN_ORDER_STATUS QUEUED
                     CANCEL_QUEUED EDIT_QUEUED)

  defp valid_statuses(statuses) do
    statuses
    |> List.wrap()
    |> Enum.find(&(not known_status?(&1)))
    |> case do
      nil -> :ok
      bad -> {:error, {:invalid_status, bad}}
    end
  end

  defp known_status?(status) when is_atom(status) or is_binary(status),
    do: String.upcase(to_string(status)) in @status_filters

  defp known_status?(_other), do: false

  # `SymbolFormat.to_exchange_symbol/1` has no clause for a non-binary, so `symbol: :btc` or
  # `symbol: [nil]` raised `FunctionClauseError` in the caller's process, and `""` filtered
  # nothing while looking like a filter. A filter is a non-empty string or a list of them.
  defp valid_order_symbols(nil), do: :ok

  defp valid_order_symbols(symbols) do
    list = List.wrap(symbols)

    if list != [] and Enum.all?(list, &(is_binary(&1) and &1 != "")),
      do: :ok,
      else: {:error, {:invalid_symbol, symbols}}
  end

  # The venue's page size. Sent as given before, so `limit: 0`, `-5` or `"x"` reached the
  # venue, whose reading of them is unmeasured.
  # The spec types `limit` as int32 for the order list and int64 for fills (at-spec.yaml:900-908,
  # :1041-1047). Above the type is `{:invalid_option, :limit, v}`, as `get_trades/2` answers it,
  # rather than a value the venue's decoder cannot hold sent for it to reject (or wrap).
  defp valid_page_size(nil, _max), do: :ok

  defp valid_page_size(limit, max) when is_integer(limit) and limit > max,
    do: {:error, {:invalid_option, :limit, limit}}

  defp valid_page_size(limit, _max) when is_integer(limit) and limit > 0, do: :ok
  defp valid_page_size(limit, _max), do: {:error, {:invalid_limit, limit}}

  defp venue_symbol(nil), do: nil
  defp venue_symbol(symbols) when is_list(symbols), do: Enum.map(symbols, &venue_symbol/1)
  defp venue_symbol(symbol), do: SymbolFormat.to_exchange_symbol(symbol)

  # The venue's status vocabulary, mapped to the contract's. `OrderExecutionStatus`'s full
  # enum (docs/reference/coinbase/openapi/at-spec.yaml:8577-8589): PENDING, OPEN, FILLED,
  # CANCELLED, EXPIRED, FAILED, UNKNOWN_ORDER_STATUS, QUEUED, CANCEL_QUEUED, EDIT_QUEUED —
  # this map used to be missing the last two.
  #
  # `QUEUED`, `CANCEL_QUEUED` and `EDIT_QUEUED` are the venue's own intermediate states —
  # accepted-not-yet-working, accepted-for-cancellation-but-still-live, and
  # accepted-for-edit-but-still-live. All three map to `:open`: the order exists and may
  # still fill, which is what a caller needs to know. Mapping CANCEL_QUEUED to `:cancelled`,
  # or EDIT_QUEUED to whatever the edit changes it to, would tell a caller something about
  # the order that has not happened yet.
  #
  # `UNKNOWN_ORDER_STATUS` is the venue's own explicit "unspecified" value — not a status
  # this package fails to recognise, but one Coinbase itself declines to name. It is listed
  # here mapping to `nil` rather than left absent, so the mapping states that outcome on
  # purpose instead of producing it by omission the same way an unrecognised future status
  # would.
  @statuses %{
    "PENDING" => :pending,
    "QUEUED" => :open,
    "OPEN" => :open,
    "CANCEL_QUEUED" => :open,
    "EDIT_QUEUED" => :open,
    "FILLED" => :filled,
    "CANCELLED" => :cancelled,
    "EXPIRED" => :expired,
    "FAILED" => :rejected,
    "UNKNOWN_ORDER_STATUS" => nil
  }

  # An order naming no id cannot be cancelled, edited or reconciled, and a list of them looks
  # complete. The id is refused rather than carried as `nil` (the spec lists `order_id` among
  # `Order`'s required fields, at-spec.yaml:8225-8229).
  defp to_order(order) do
    with {:ok, id} <- required_id(order["order_id"], :order_id) do
      {:ok, build_order(order, id)}
    end
  end

  defp build_order(order, id) do
    leaf = order_leaf(order["order_configuration"])
    filled = order["filled_size"] |> decimal() |> non_negative()

    %Types.Order{
      id: id,
      symbol: order |> Map.get("product_id") |> canonical_or_nil(),
      side: order |> Map.get("side") |> side_atom(),
      order_type: order |> Map.get("order_type") |> type_atom(),
      time_in_force: order |> Map.get("time_in_force") |> tif_atom(),
      # `filled_size` is what has filled, not what was asked for — reusing it here made a
      # partially-filled order's remaining size read as zero on every read after placement.
      # The venue echoes what was actually requested in `order_configuration`, the same
      # place `closing_configuration/1` below already reads it from for a closing order.
      #
      # A size or price below zero is `nil`, as an unreadable one is (`non_negative/1`): a
      # `filled_size` of `"-1"` was a negative filled quantity on a real-looking order.
      quantity: leaf["base_size"] |> decimal() |> non_negative(),
      # The limit and stop prices the order was placed with, from the same echoed leaf. They
      # were never read, so every order read back had `price: nil` while `place_order/3`'s
      # own return and the fake both carried one. Absent on a market leaf, where `nil` is true.
      price: leaf["limit_price"] |> decimal() |> non_negative(),
      stop_price: leaf["stop_price"] |> decimal() |> non_negative(),
      filled_quantity: filled,
      average_price:
        average_price(
          order["average_filled_price"] |> decimal() |> non_negative(),
          filled
        ),
      fee: decimal(order["total_fees"]),
      # `Order` has no `fee_currency` field
      # (docs/reference/coinbase/openapi/at-spec.yaml:8223-8330) — this used to read one
      # anyway, which is silent under `Map.get/2`'s default `nil` and looked identical to a
      # field the venue simply left blank. The quote currency in `product_id` is where a
      # correct value would live, but the venue never states that total_fees is charged in
      # the quote currency rather than a rewards token or something else, so inferring it
      # from the symbol would be a guess wearing the shape of a fact. `nil` stays `nil`
      # because there is truly nothing documented to read here.
      fee_currency: nil,
      # An unmapped status is `nil`, never a guess. A caller branching on :open would
      # otherwise act on a state the venue named and this package did not recognise.
      status: Map.get(@statuses, order["status"]),
      created_at: parse_created(order["created_time"]),
      provider: :coinbase
    }
  end

  # A quote-sized market order's leaf carries `quote_size`, not `base_size`, and there is
  # no rate here to convert one to the other — `nil`, not a guess, same as
  # `closing_configuration/1` below for the same shape.
  #
  # The single leaf of `order_configuration`, or an empty map when there is none to read.
  defp order_leaf(%{} = configuration) when map_size(configuration) == 1 do
    case Map.values(configuration) do
      [%{} = leaf] -> leaf
      _not_a_leaf -> %{}
    end
  end

  defp order_leaf(_absent), do: %{}

  # Only a string is a product id. Anything else used to reach
  # `SymbolFormat.to_canonical_symbol/1` and raise out of `get_order/3`, `get_orders/2` and
  # `get_trade_history/2`; it is now the same absent symbol as `nil`, which `to_order/1`
  # carries as `nil` and `required_symbol/1` refuses.
  defp canonical_or_nil(native) when is_binary(native),
    do: SymbolFormat.to_canonical_symbol(native)

  defp canonical_or_nil(_absent), do: nil

  defp side_atom("BUY"), do: :buy
  defp side_atom("SELL"), do: :sell
  defp side_atom(_other), do: nil

  # See `to_trade/2`'s comment: the venue's tape reports the maker's side, and
  # `Core.Types.Trade.side` wants the taker's — the two are always opposite one another for
  # the same print. Only used there; `side_atom/1` alone is right for an order's own side.
  defp maker_side_to_taker(:buy), do: :sell
  defp maker_side_to_taker(:sell), do: :buy
  defp maker_side_to_taker(nil), do: nil

  defp type_atom("MARKET"), do: :market
  defp type_atom("LIMIT"), do: :limit
  defp type_atom("STOP_LIMIT"), do: :stop_limit
  # The spec's `OrderType` enum names `STOP` ("becomes a market order when triggered") and
  # Core's `Order.order_type` has `:stop`; mapping it to `nil` threw a stated type away.
  # BRACKET, TWAP, ROLL_*, LIQUIDATION and SCALED have no Core atom and stay `nil`.
  defp type_atom("STOP"), do: :stop
  defp type_atom(_other), do: nil

  defp tif_atom("GOOD_UNTIL_CANCELLED"), do: :gtc
  defp tif_atom("GOOD_UNTIL_DATE_TIME"), do: :gtd
  defp tif_atom("IMMEDIATE_OR_CANCEL"), do: :ioc
  defp tif_atom("FILL_OR_KILL"), do: :fok
  defp tif_atom(_other), do: nil

  defp parse_created(nil), do: nil

  defp parse_created(value) do
    case parse_time(value) do
      {:ok, at} -> at
      _unparsable -> nil
    end
  end

  @doc """
  Previews an order without placing it.

  Takes the same request as `place_order/3` and builds the same `order_configuration`, so a
  preview that succeeds is a preview of the order that would actually be sent. Building the
  request differently here — a simpler path, a defaulted field — would preview something
  else and report it as the order.

  **A preview carrying `errs` is a refusal, not a preview.** The venue answers `200` with a
  populated error list for an order it would reject, and returning that as a successful
  preview would tell a caller its order is fine when the venue has already said it is not.

  `warning` is passed through untouched and does **not** make this a refusal: a warning is
  the venue saying "this will execute, and you may not like how".
  """
  @spec preview_order(map(), term(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def preview_order(credentials, request, opts) do
    with {:ok, plan} <- order_plan(request, :preview),
         :ok <- validate_credentials(credentials) do
      body =
        Map.merge(plan.margin, %{
          "product_id" => SymbolFormat.to_exchange_symbol(plan.symbol),
          "side" => plan.side |> to_string() |> String.upcase(),
          "order_configuration" => plan.configuration
        })

      case post_json("/orders/preview", body, credentials, opts) do
        {:ok, %{body: response}} -> preview_result(response)
        {:error, reason} -> classify(reason)
      end
    end
  end

  defp preview_result(%{"errs" => errs} = _response) when is_list(errs) and errs != [] do
    {:refused, {:preview_rejected, errs}}
  end

  # `errs` is the venue's list of reasons. Anything else that is present (a string, a map, a
  # number) is not an empty list: it fell through to the success clause below and a preview
  # the venue had put an error on read as a green light.
  defp preview_result(%{"errs" => errs}) when not (is_nil(errs) or is_list(errs)),
    do: {:error, :unexpected_response_shape}

  defp preview_result(%{} = response) do
    {:ok,
     %{
       order_total: decimal(response["order_total"]),
       commission_total: decimal(response["commission_total"]),
       base_size: decimal(response["base_size"]),
       quote_size: decimal(response["quote_size"]),
       best_bid: decimal(response["best_bid"]),
       best_ask: decimal(response["best_ask"]),
       slippage: decimal(response["slippage"]),
       # The venue's own words, unedited. A warning summarised here is a warning a caller
       # cannot act on.
       warning: response["warning"],
       preview_id: response["preview_id"]
     }}
  end

  defp preview_result(_other), do: {:error, :unexpected_response_shape}

  @doc """
  Prices an amendment to a working order **without making it**.

  `/orders/edit_preview` takes the same body as `/orders/edit` and answers with what the
  amended order would cost. The reason this is not `preview_order/3` with an id: the venue
  prices the amendment against the resting order's own state, including whatever of it has
  already filled. Asking what a fresh order of the new size would cost is a different
  question with a different answer.

  Accepts the same changes `replace_order/4` does — `:price` and `:quantity`, **both
  required** — and refuses anything else here rather than sending it and reading the venue's
  business error. See `replace_order/4`'s doc for why both, even to change only one.

  **The response's `errors` array is the refusal.** As with `/orders/preview`, an HTTP 200
  carrying errors is the venue saying no; this returns `{:refused, …}` rather than an `:ok`
  a caller would read as a green light.
  """
  @spec preview_replace(map(), String.t(), term(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def preview_replace(credentials, order_id, changes, opts) do
    with {:ok, body} <- edit_body(order_id, changes) do
      case post_json("/orders/edit_preview", body, credentials, opts) do
        {:ok, %{body: response}} -> edit_preview_result(response)
        {:error, reason} -> classify(reason)
      end
    end
  end

  defp edit_preview_result(%{"errors" => errors}) when is_list(errors) and errors != [] do
    {:refused, {:edit_preview_rejected, errors}}
  end

  # As `preview_result/1`: a present `errors` that is not a list is unreadable, not empty.
  defp edit_preview_result(%{"errors" => bad}) when not (is_nil(bad) or is_list(bad)),
    do: {:error, :unexpected_response_shape}

  defp edit_preview_result(%{} = response) do
    {:ok,
     %{
       order_total: decimal(response["order_total"]),
       commission_total: decimal(response["commission_total"]),
       base_size: decimal(response["base_size"]),
       quote_size: decimal(response["quote_size"]),
       best_bid: decimal(response["best_bid"]),
       best_ask: decimal(response["best_ask"]),
       average_filled_price: decimal(response["average_filled_price"]),
       order_margin_total: decimal(response["order_margin_total"]),
       slippage: decimal(response["slippage"])
     }}
  end

  defp edit_preview_result(_other), do: {:error, :unexpected_response_shape}

  @doc """
  Flattens an open position on `symbol` by having the venue place the closing order.

  **This places an order.** The venue works out the side and the size from the position it
  holds, which is the whole point: a caller doing `get_positions/1` then `place_order/3`
  sizes against the position as of its last read, and a position that moved in between
  leaves a residue or overshoots into a position the other way. Only the venue closes to
  exactly zero.

  `size` is optional and partial-closes when given, in **contracts**, not base units — the
  venue's own wording. Omitted, the whole position goes.

  The response envelope is `/orders`'s, so a refusal arrives as a `200` with
  `"success" => false` and is returned as `{:refused, …}`.

  **The returned `Order` carries no side.** The venue does not echo one and this package
  will not infer it: the side of a closing order is the opposite of a position whose
  direction was never read here, and guessing it is exactly the substitution this family
  refuses.
  """
  @spec close_position(map(), String.t(), keyword()) ::
          {:ok, Types.Order.t()} | {:error, term()} | {:refused, term()}
  def close_position(credentials, symbol, opts) do
    with {:ok, client_order_id, size} <- close_request(symbol, opts),
         :ok <- validate_credentials(credentials) do
      body =
        %{
          "client_order_id" => client_order_id,
          "product_id" => SymbolFormat.to_exchange_symbol(symbol)
        }
        |> put_unless_nil("size", size)

      calls = :atomics.new(1, signed: false)

      case post_json("/orders/close_position", body, credentials, opts, &counting(&1, calls)) do
        {:ok, %{body: response}} -> to_closing_order(response, symbol, client_order_id)
        {:error, reason} -> write_error(reason, client_order_id, {calls, opts})
      end
    end
  end

  # `success: true` means the venue placed an order, so an unreadable `success_response`
  # must not become a plain error: a caller reading `{:error, _}` would believe nothing was
  # placed and act on that, with a live order at the venue. It used to raise instead, which
  # told the caller the same wrong thing. It was then reported as `{:ok, %Order{id: nil}}`,
  # which `Core.Types.Order` does not allow (it requires an id): since DV5 a close, like a
  # placement, whose `success_response` names no readable `order_id` is
  # `{:order_unconfirmed, client_order_id, {:missing_required_field, :order_id}}` — the order
  # MAY be live, and the id sent is what to look it up with.
  defp success_order_id(%{"order_id" => id}) when is_binary(id) and id != "", do: id
  defp success_order_id(_unreadable), do: nil

  # A missing `success_response` is read the same way as an unreadable one: `success` is the
  # only field the spec requires of `ClosePositionResponse`'s envelope.
  defp to_closing_order(%{"success" => true} = response, symbol, client_order_id) do
    case response |> Map.get("success_response") |> success_order_id() do
      nil -> unconfirmed(client_order_id, {:missing_required_field, :order_id})
      id -> {:ok, closing_order(id, symbol, response)}
    end
  end

  defp to_closing_order(%{"success" => false} = response, _symbol, client_order_id) do
    reason = failure_reason(response)

    if duplicate_client_order_id?(reason),
      do: unconfirmed(client_order_id, :duplicate_client_order_id),
      else: {:refused, {:close_rejected, reason}}
  end

  defp to_closing_order(_other, _symbol, client_order_id),
    do: unconfirmed(client_order_id, :unexpected_response_shape)

  defp closing_order(id, symbol, response) do
    # The venue echoes the order it placed in `order_configuration`, which is the only
    # statement of what this order *is* — the caller never said. Read from there rather
    # than assumed, and `nil` for anything it does not name.
    {type, tif, quantity} = closing_configuration(response["order_configuration"])

    %Types.Order{
      id: id,
      symbol: symbol,
      # **Not inferred.** A closing order's side is the opposite of the position's, and
      # this package never read the position — the venue did. Filling in `:sell` because
      # closing is usually selling is the substitution this family refuses.
      side: nil,
      order_type: type,
      time_in_force: tif,
      quantity: quantity,
      status: :pending,
      provider: :coinbase
    }
  end

  # `@configurations` read backwards. The venue's single key names the type and the
  # time-in-force at once, so one lookup answers both — and a key this package does not know
  # answers neither rather than the nearest pair.
  @configuration_names Map.new(@configurations, fn {pair, name} -> {name, pair} end)

  defp closing_configuration(%{} = configuration) when map_size(configuration) == 1 do
    [{name, leaf}] = Map.to_list(configuration)
    {type, tif} = Map.get(@configuration_names, name, {nil, nil})
    {type, tif, decimal(is_map(leaf) && leaf["base_size"])}
  end

  defp closing_configuration(_absent), do: {nil, nil, nil}

  @doc """
  Changes the price or size of a working order.

  **This venue edits in place; it does not cancel and re-place.** That distinction is the
  reason `replace_order/4` is worth having at all: a cancel-then-place opens a window in
  which no order is live, and on a moving market that window is where the fill a caller
  wanted goes to someone else.

  Coinbase accepts `price` and `size` only. **Anything else in the request is refused rather
  than dropped** — a caller trying to change the side or the time-in-force is describing a
  different order, and silently editing only the price would leave it holding one it did not
  ask for.

  **Both `price` and `size` must be given, even to change only one.**
  `EditOrderRequest` declares `order_id`, `price` *and* `size` all required
  (docs/reference/coinbase/openapi/at-spec.yaml:6809-6852) — there is no documented meaning
  for the venue reusing the order's current value when one is absent, so this package does
  not assume one. It used to send whichever of the two the caller supplied and omit the
  other with `put_unless_nil/3`, which produced a request the schema does not describe; what
  the venue actually does with a `size`-less edit was never measured and is not this
  package's to guess. The alternative — reading the order first via `get_order/3` to fill in
  the unchanged field — was rejected: the read and the edit are two round trips, and an order
  that partially fills or is cancelled in between makes the "unchanged" value stale by the
  time it is replayed as part of a request that claims to be unchanged. Refusing locally is
  the fail-closed answer; `preview_replace/4` refuses the identical way.

  A `200` carrying `success: false` is a refusal, as everywhere else on this venue.

  **`{:error, {:replace_accepted_unread, order_id, reason}}` means the edit WAS
  applied.** The venue accepted it, then the read-back of the order failed with `reason`.
  Do not retry the edit; read the order with `get_order/3` to learn its state.

  **`{:error, {:order_unconfirmed, nil, reason}}` means the edit MAY have been applied**: the
  request was sent and the answer was a transport failure, a 5xx or a `2xx` that is not a
  readable `success` (sent once, never retried). The first element is `nil` because an edit
  carries no `client_order_id`; read the order with `get_order/3` before editing again. Errors
  decided before sending (validation, credentials, our own rate limiter) are plain
  `{:error, reason}`.
  """
  @spec replace_order(map(), String.t(), term(), keyword()) ::
          {:ok, Types.Order.t()} | {:error, term()} | {:refused, term()}
  def replace_order(credentials, order_id, changes, opts) do
    with {:ok, body} <- edit_body(order_id, changes),
         :ok <- validate_credentials(credentials) do
      case post_once("/orders/edit", body, credentials, opts) do
        {:ok, %{body: response}} -> edit_result(response, order_id, credentials, opts)
        {:error, reason} -> write_error(reason, nil, nil)
      end
    end
  end

  @editable [:price, :quantity]

  # The `/orders/edit` and `/orders/edit_preview` body, or the local refusal. The order id is
  # checked here too: `nil` would send `"order_id": null` for an edit that names nothing.
  defp edit_body(order_id, changes) do
    with :ok <- edit_order_id(order_id),
         :ok <- editable_changes(changes),
         {:ok, amounts} <- normalise_amounts(@editable, changes) do
      {:ok,
       %{
         "order_id" => order_id,
         "price" => wire_number(Map.fetch!(amounts, :price)),
         "size" => wire_number(Map.fetch!(amounts, :quantity))
       }}
    end
  end

  defp edit_order_id(order_id), do: validate_order_id(order_id)

  @doc """
  The order-id check `get_order/3`, `cancel_order/3` and `replace_order/4` run first, before
  the account option and credentials: an id that is `nil`, not text, or blank after trimming
  is `{:error, {:invalid_order_id, value}}`. `"  "` used to be sent percent-encoded.
  """
  @spec validate_order_id(term()) :: :ok | {:error, {:invalid_order_id, term()}}
  def validate_order_id(order_id) when is_binary(order_id) do
    if String.trim(order_id) == "", do: {:error, {:invalid_order_id, order_id}}, else: :ok
  end

  def validate_order_id(order_id), do: {:error, {:invalid_order_id, order_id}}

  # `Map.keys/1` raised `BadMapError` for `nil` or a keyword list, in the caller's process.
  defp editable_changes(changes) when not is_map(changes),
    do: {:error, {:invalid_order_changes, changes}}

  defp editable_changes(changes) do
    case Map.keys(changes) -- @editable do
      [] -> editable_present(changes)
      unsupported -> {:error, {:unsupported_order_edit, unsupported}}
    end
  end

  # `EditOrderRequest` requires both `price` and `size` on every edit
  # (docs/reference/coinbase/openapi/at-spec.yaml:6809-6852). This used to accept either one
  # alone and omit the other from the body — a shape the schema does not describe and this
  # package never measured the venue's handling of. Refusing locally when only one is given is
  # the fail-closed choice over guessing at the omitted field's meaning or reading the other
  # value back from `get_order/3`, which would still be racing the order's live state.
  #
  # "Given" means non-nil. `Map.has_key?/2` counted `price: nil` as given, and
  # `wire_number(nil)` then sent `"price": ""` for the venue to reject on a field it might
  # not name.
  defp editable_present(changes) do
    has_price = Map.get(changes, :price) != nil
    has_quantity = Map.get(changes, :quantity) != nil

    cond do
      has_price and has_quantity -> :ok
      has_price or has_quantity -> {:error, :missing_required_edit_field}
      true -> {:error, :no_order_changes}
    end
  end

  defp edit_result(%{"success" => true}, order_id, credentials, opts) do
    # The venue's edit response carries no order body — only that it worked. Building an
    # `Order` from the request would report what was *asked for* as though the venue had
    # confirmed it, which is a different thing and the one this family keeps getting wrong.
    #
    # So the order is read back. It costs a second call and returns the venue's own view,
    # including whatever it did with the edit that the caller did not ask for.
    #
    # **The edit is already applied when that read fails.** A bare `{:error, _}` here told the
    # caller an edit that took effect had failed, and a caller retrying it edits twice or
    # cancels the order believing it unchanged. Found 2026-10-10 by reading this clause. The
    # refetch failure is wrapped, naming the order, so it cannot be mistaken for a failed edit.
    # (`:replace_accepted_unread` is the family's name for it; it was
    # `:edit_accepted_refetch_failed`.)
    case get_order(credentials, order_id, opts) do
      {:ok, _order} = ok -> ok
      {:error, reason} -> {:error, {:replace_accepted_unread, order_id, reason}}
      {:refused, reason} -> {:error, {:replace_accepted_unread, order_id, reason}}
    end
  end

  defp edit_result(%{"success" => false} = response, _order_id, _credentials, _opts) do
    {:refused, {:edit_rejected, edit_failure(response)}}
  end

  # A 2xx that is neither a `success: true` nor a `success: false` map proves nothing: the
  # edit reached the venue and may have been applied.
  defp edit_result(_other, _order_id, _credentials, _opts),
    do: unconfirmed(nil, :unexpected_response_shape)

  # `EditOrderError` (one entry of `EditOrderResponse.errors`) carries `edit_failure_reason`
  # and, as a second field, `preview_failure_reason`
  # (docs/reference/coinbase/openapi/at-spec.yaml:6726-6734). This used to read only the
  # first and treat the whole call as `:unspecified` when it was absent, even when the
  # entry's `preview_failure_reason` named the reason instead.
  #
  # Both enums start with an `UNKNOWN_*` zero value (`UNKNOWN_EDIT_ORDER_FAILURE_REASON`,
  # `UNKNOWN_PREVIEW_FAILURE_REASON`), the venue's "not set". An entry that states a real
  # `preview_failure_reason` beside the unset edit one used to be reported as the unset edit
  # reason, hiding the one reason it gave. A stated reason wins over an `UNKNOWN_*` one; with
  # none stated the edit reason is kept as before.
  defp edit_failure(%{"errors" => [%{} = error | _rest]}) do
    reasons =
      Enum.filter(
        [error["edit_failure_reason"], error["preview_failure_reason"]],
        &is_binary/1
      )

    reason =
      Enum.find(reasons, &(not String.starts_with?(&1, "UNKNOWN_"))) ||
        List.first(reasons) || :unspecified

    bounded_text(reason)
  end

  defp edit_failure(_response), do: :unspecified
end

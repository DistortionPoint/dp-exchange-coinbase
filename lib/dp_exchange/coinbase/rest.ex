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

  ## Historical candles are public

  `/market/products/{id}/candles`, no auth. The authenticated variant `401`s on every
  backfill call, which is what it did until 2026-07-02.

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

  alias DpExchange.Coinbase.{Auth, SymbolFormat}
  alias DpExchange.Core.{HttpClient, Timeframe, Types}

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
  """
  @spec get_price(String.t(), keyword()) ::
          {:ok, Types.Quote.t()} | {:error, term()} | {:refused, term()}
  def get_price(symbol, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    credentials = Keyword.get(opts, :credentials)

    path =
      if credentials,
        do: "/products/#{native}/ticker",
        else: "/market/products/#{native}/ticker"

    case request(:get, path, credentials, opts) do
      {:ok, %{body: body}} -> to_quote(body, symbol)
      {:error, reason} -> classify(reason)
    end
  end

  @doc """
  Historical candles for `symbol` at `timeframe`.

  A timeframe Coinbase does not serve is an **error**, never the nearest width.
  """
  @spec get_historical_prices(String.t(), String.t(), keyword(), keyword()) ::
          {:ok, [Types.Quote.t()]} | {:error, term()} | {:refused, term()}
  def get_historical_prices(symbol, timeframe, range, opts) do
    with {:ok, enum} <- granularity_enum(timeframe),
         {:ok, params} <- candle_params(timeframe, range, enum) do
      native = SymbolFormat.to_exchange_symbol(symbol)

      case request(:get, "/market/products/#{native}/candles", nil, opts, params) do
        {:ok, %{body: body}} -> to_candles(body, symbol, timeframe)
        {:error, reason} -> classify(reason)
      end
    end
  end

  @doc "Every product Coinbase lists, as canonical symbols."
  @spec get_symbols(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def get_symbols(opts) do
    case request(:get, "/market/products", nil, opts) do
      {:ok, %{body: %{"products" => products}}} ->
        {:ok, Enum.map(products, &SymbolFormat.to_canonical_symbol(&1["product_id"]))}

      {:ok, _unexpected} ->
        {:error, :unexpected_response_shape}

      {:error, reason} ->
        classify(reason)
    end
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
  until `has_next` is false, bounded by `@max_pages` — a server that always says `has_next`
  would otherwise loop forever inside a facade call.

  `:timestamp` is when the request was made. A balance has no venue event time; see
  `Core.Types.Balance`.
  """
  @spec get_balances(map(), keyword()) ::
          {:ok, [Types.Balance.t()]} | {:error, term()} | {:refused, term()}
  def get_balances(credentials, opts) do
    asked_at = DateTime.utc_now()

    with {:ok, accounts} <- all_accounts(credentials, opts, nil, [], 0) do
      {:ok, Enum.map(accounts, &to_balance(&1, asked_at))}
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
  """
  @spec get_accounts(map(), keyword()) ::
          {:ok, [map()]} | {:error, term()} | {:refused, term()}
  def get_accounts(credentials, opts) do
    case Keyword.get(opts, :uuid) do
      nil ->
        all_accounts(credentials, opts, nil, [], 0)

      uuid ->
        case request(:get, "/accounts/#{uuid}", credentials, opts) do
          {:ok, %{body: %{"account" => account}}} -> {:ok, [account]}
          {:ok, _unexpected} -> {:error, :unexpected_response_shape}
          {:error, reason} -> classify(reason)
        end
    end
  end

  @max_account_pages 50

  defp all_accounts(_credentials, _opts, _cursor, _acc, page) when page >= @max_account_pages,
    do: {:error, :too_many_account_pages}

  defp all_accounts(credentials, opts, cursor, acc, page) do
    params =
      %{}
      |> put_unless_nil("limit", Keyword.get(opts, :limit))
      |> put_unless_nil("cursor", cursor)

    case request(:get, "/accounts", credentials, opts, params) do
      {:ok, %{body: %{"accounts" => accounts} = body}} ->
        collected = acc ++ accounts

        # `has_next` is the venue's word for it. An empty page with `has_next` still true
        # is the venue's business; the page counter is what stops this either way.
        if body["has_next"] == true and is_binary(body["cursor"]) and body["cursor"] != "" do
          all_accounts(credentials, opts, body["cursor"], collected, page + 1)
        else
          {:ok, collected}
        end

      {:ok, _unexpected} ->
        {:error, :unexpected_response_shape}

      {:error, reason} ->
        classify(reason)
    end
  end

  defp to_balance(account, asked_at) do
    available = amount(account["available_balance"])
    hold = amount(account["hold"])

    %Types.Balance{
      currency: account["currency"],
      balance: total_balance(available, hold),
      available_balance: available,
      hold: hold,
      timestamp: asked_at,
      provider: :coinbase
    }
  end

  # Both or nothing. "Available 1, total unknown" and "total equals available" are
  # different claims, and a consumer sizing against the second when the first is true
  # trades against money that is held.
  defp total_balance(nil, _hold), do: nil
  defp total_balance(_available, nil), do: nil
  defp total_balance(available, hold), do: Decimal.add(available, hold)

  defp amount(%{"value" => value}), do: decimal(value)
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

  The response pages on `cursor`, and this follows it to `@max_fill_pages`.
  """
  @spec get_trade_history(map(), keyword()) ::
          {:ok, [Types.Fill.t()]} | {:error, term()} | {:refused, term()}
  def get_trade_history(credentials, opts) do
    wanted = Keyword.get(opts, :trade_types, ["FILL"])

    with {:ok, rows} <- all_fills(credentials, opts, nil, [], 0) do
      rows
      |> Enum.filter(&(&1["trade_type"] in wanted))
      |> Enum.reduce_while({:ok, []}, fn row, {:ok, acc} ->
        case to_fill(row) do
          {:ok, fill} -> {:cont, {:ok, [fill | acc]}}
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, fills} -> {:ok, Enum.reverse(fills)}
        error -> error
      end
    end
  end

  @max_fill_pages 50

  defp all_fills(_credentials, _opts, _cursor, _acc, page) when page >= @max_fill_pages,
    do: {:error, :too_many_fill_pages}

  defp all_fills(credentials, opts, cursor, acc, page) do
    params =
      %{}
      |> put_unless_nil("order_ids", Keyword.get(opts, :order_id))
      |> put_unless_nil("product_ids", exchange_symbol(Keyword.get(opts, :symbol)))
      |> put_unless_nil("start_sequence_timestamp", timestamp_param(Keyword.get(opts, :start)))
      |> put_unless_nil("end_sequence_timestamp", timestamp_param(Keyword.get(opts, :end)))
      |> put_unless_nil("limit", Keyword.get(opts, :limit))
      |> put_unless_nil("cursor", cursor)

    case request(:get, "/orders/historical/fills", credentials, opts, params) do
      {:ok, %{body: %{"fills" => fills} = body}} ->
        collected = acc ++ fills
        next = body["cursor"]

        # An empty cursor is the venue saying "no more". Re-sending it would ask for the
        # same page forever, which the page bound would eventually stop — but stopping here
        # is the correct reading, not a fallback.
        if is_binary(next) and next != "" and fills != [] do
          all_fills(credentials, opts, next, collected, page + 1)
        else
          {:ok, collected}
        end

      {:ok, _unexpected} ->
        {:error, :unexpected_response_shape}

      {:error, reason} ->
        classify(reason)
    end
  end

  defp exchange_symbol(nil), do: nil
  defp exchange_symbol(symbol), do: SymbolFormat.to_exchange_symbol(symbol)

  defp timestamp_param(nil), do: nil
  defp timestamp_param(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp timestamp_param(other), do: other

  # An undated fill is refused rather than stamped with the local clock. A fill is an event
  # that happened at a moment; a client timestamp on one places it wrongly in a trade
  # history while looking entirely reasonable.
  defp to_fill(row) do
    with {:ok, timestamp} <- parse_time(row["trade_time"]) do
      {:ok,
       %Types.Fill{
         order_id: row["order_id"],
         trade_id: row["trade_id"],
         symbol: canonical_or_nil(row["product_id"]),
         side: side_atom(row["side"]),
         quantity: decimal(row["size"]),
         price: decimal(row["price"]),
         fee: decimal(row["commission"]),
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
  defp candle_params(timeframe, range, enum) do
    finish = Keyword.get_lazy(range, :end, &DateTime.utc_now/0)
    width = timeframe_seconds(timeframe)
    start = Keyword.get_lazy(range, :start, fn -> DateTime.add(finish, -width * 300, :second) end)

    requested = div(DateTime.diff(finish, start, :second), width)

    if requested > @max_candles do
      {:error, {:range_too_wide, requested: requested, max: @max_candles}}
    else
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

  defp request(method, path, credentials, opts, params \\ %{}) do
    headers =
      if credentials do
        HttpClient.build_auth_headers(
          method,
          @api_path <> path,
          nil,
          credentials,
          &Auth.rest_headers/4
        )
      else
        []
      end

    url = @base_url <> @api_path <> path

    request_opts =
      opts
      |> Keyword.take([:timeout, :retry_attempts, :retry_delay, :plug, :weight])
      |> Keyword.put(:provider, :coinbase)
      # This venue's own limiter, configured from its own declared ceiling.
      |> Keyword.put_new(:limiter, Keyword.get(opts, :limiter, DpExchange.Coinbase.RateLimiter))

    HttpClient.request(method, url <> query(params), headers, nil, request_opts)
  end

  defp query(params) when params == %{}, do: ""

  defp query(params) do
    "?" <> URI.encode_query(params)
  end

  # A 404 from this venue means the product is not listed — a permanent answer, and the
  # distinction a caller needs: a refusal is not retried, an error is.
  # The reason arrives already unwrapped from `{:error, reason}`, so it is either a bare
  # message or the venue-tagged form — never `{:error, _}` again. A clause for the
  # double-wrapped shape was here and could never match; dialyzer said so as soon as
  # Core's spec was accurate enough to tell.
  defp classify({:exchange_error, _venue, message}) when is_binary(message),
    do: refusal_or_error(message)

  defp classify(message) when is_binary(message), do: refusal_or_error(message)
  defp classify(reason), do: {:error, reason}

  defp refusal_or_error(message) do
    if String.contains?(message, "404"), do: {:refused, :not_listed}, else: {:error, message}
  end

  # ONE shape, not two. The adapter this was ported from branched on whether credentials
  # were supplied, formatting `:public_ticker` as a flat `{"price": …}` object and
  # `:auth_ticker` as `{"trades": [...]}`.
  #
  # Measured 2026-08-28: **both endpoints return the trades shape.** Either the public
  # response changed or the assumption was never right; the branch is gone either way,
  # because two formatters for one shape is a second place to be wrong about the venue.
  defp to_quote(%{"trades" => [trade | _rest]} = _body, symbol) do
    with {:ok, at} <- parse_time(trade["time"]) do
      {:ok,
       %Types.Quote{
         symbol: symbol,
         price: decimal(trade["price"]),
         volume: decimal(trade["size"]),
         timestamp: at,
         provider: :coinbase
       }}
    end
  end

  defp to_quote(_body, _symbol), do: {:error, :unexpected_response_shape}

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
  """
  @spec get_top_of_book(String.t(), keyword()) ::
          {:ok, Types.TopOfBook.t()} | {:error, term()} | {:refused, term()}
  def get_top_of_book(symbol, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    credentials = Keyword.get(opts, :credentials)
    observed_at = DateTime.utc_now()

    case request(:get, "/best_bid_ask", credentials, opts, %{"product_ids" => native}) do
      {:ok, %{body: %{"pricebooks" => [pricebook | _rest]}}} ->
        build_top_of_book(native, pricebook, observed_at)

      # The venue answered and named no book for this product. Not an error, and not an
      # empty book either — there is nothing to quote.
      {:ok, %{body: %{"pricebooks" => []}}} ->
        {:refused, :not_listed}

      {:ok, _unexpected} ->
        {:error, :unexpected_response_shape}

      {:error, reason} ->
        classify(reason)
    end
  end

  defp build_top_of_book(native, pricebook, observed_at) do
    {bid, bid_size} = best_level(pricebook["bids"])
    {ask, ask_size} = best_level(pricebook["asks"])

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

  # An empty side is a real state — one side of a book can be empty — and `nil` says so.
  # Zero would claim someone is quoting nothing at a price of nothing.
  defp best_level([%{"price" => price, "size" => size} | _rest]),
    do: {decimal(price), decimal(size)}

  defp best_level(_absent), do: {nil, nil}

  defp pricebook_time(%{"time" => time}) do
    case parse_time(time) do
      {:ok, at} -> at
      _no_time -> nil
    end
  end

  defp pricebook_time(_absent), do: nil

  @doc """
  The order book for `symbol` — `GET /product_book`.

  `opts[:limit]` bounds the levels per side; `opts[:aggregation_price_increment]` groups
  them, which is the venue's own word for it.

  **Both sides come back as the venue ordered them, unsorted here.** A book's order is the
  venue's statement about its own matching, and re-sorting it would hide a venue that sent
  a crossed or out-of-order book — which is exactly the thing worth seeing.

  `timestamp` is the pricebook's own `time`. **A book the venue did not stamp is refused**:
  a depth snapshot with the local clock on it cannot be told apart from a current one, and
  a stale book read as current is the most expensive kind of wrong number here.
  """
  @spec get_order_book(String.t(), keyword()) ::
          {:ok, Types.OrderBook.t()} | {:error, term()} | {:refused, term()}
  def get_order_book(symbol, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    credentials = Keyword.get(opts, :credentials)

    params =
      %{"product_id" => native}
      |> put_unless_nil("limit", Keyword.get(opts, :limit))
      |> put_unless_nil(
        "aggregation_price_increment",
        Keyword.get(opts, :aggregation_price_increment)
      )

    # The venue publishes the same book twice: `/market/product_book` unauthenticated and
    # `/product_book` for a credential. Reading the public one while holding a credential
    # would silently forgo whatever the authenticated view adds.
    path = if credentials, do: "/product_book", else: "/market/product_book"

    case request(:get, path, credentials, opts, params) do
      {:ok, %{body: %{"pricebook" => pricebook}}} -> build_order_book(native, pricebook)
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
    end
  end

  defp build_order_book(native, pricebook) do
    with {:ok, timestamp} <- parse_time(pricebook["time"]) do
      {:ok,
       %Types.OrderBook{
         symbol: SymbolFormat.to_canonical_symbol(native),
         bids: levels(pricebook["bids"]),
         asks: levels(pricebook["asks"]),
         timestamp: timestamp,
         # The venue publishes no sequence number on this endpoint. `nil` means it did not
         # say, so a caller cannot use this book to detect a gap in a stream.
         sequence: nil,
         provider: :coinbase
       }}
    end
  end

  defp levels(rows) when is_list(rows) do
    for %{"price" => price, "size" => size} <- rows, do: {decimal(price), decimal(size)}
  end

  defp levels(_absent), do: []

  # **This built `Quote`s with `price: close` until 2026-09-01.** The venue sends open,
  # high, low and close; three of them were discarded here, at the boundary, where no
  # caller could see it happen. Every value that came out was real, and a caller reading
  # `price` had no way to learn it was holding one corner of a bar.
  #
  # It is the same defect 2.10 of the coverage plan found in Schwab, and the reasoning
  # behind it was the same: "a bar's price, for a series, is where it ended".
  defp to_candles(%{"candles" => candles}, symbol, timeframe) do
    candles
    |> Enum.reduce_while({:ok, []}, fn candle, {:ok, acc} ->
      case to_candle(candle, symbol, timeframe) do
        {:ok, bar} -> {:cont, {:ok, [bar | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, bars} -> {:ok, bars |> Enum.reverse() |> Enum.sort_by(& &1.opened_at, DateTime)}
      error -> error
    end
  end

  defp to_candles(_body, _symbol, _timeframe), do: {:error, :unexpected_response_shape}

  defp to_candle(candle, symbol, timeframe) do
    with {:ok, opened_at} <- candle_start(candle["start"]) do
      {:ok,
       %Types.Candle{
         symbol: symbol,
         timeframe: timeframe,
         # The venue's own bucket start, used as-is. Not re-derived, not rounded.
         opened_at: opened_at,
         open: decimal(candle["open"]),
         high: decimal(candle["high"]),
         low: decimal(candle["low"]),
         close: decimal(candle["close"]),
         volume: decimal(candle["volume"]),
         provider: :coinbase
       }}
    end
  end

  # An undated bar cannot be placed in a series, and the local clock would place it wrongly
  # while looking right. Refuse instead.
  defp candle_start(start) when is_binary(start) do
    case Integer.parse(start) do
      {seconds, ""} -> {:ok, DateTime.from_unix!(seconds)}
      _not_an_epoch -> {:error, :missing_venue_timestamp}
    end
  end

  defp candle_start(start) when is_integer(start), do: {:ok, DateTime.from_unix!(start)}
  defp candle_start(_absent), do: {:error, :missing_venue_timestamp}

  # `nil` rather than zero for an absent number. Zero is a price, and a venue that did
  # not report volume has not reported zero volume.
  defp decimal(nil), do: nil

  # Coinbase sends `""` for a bid or ask it has no value for, and `Decimal.new/1` raises
  # on it. Empty is absent, not zero — zero is a price, and a venue that did not quote a
  # bid has not quoted a bid of nothing.
  defp decimal(""), do: nil
  defp decimal(value) when is_binary(value), do: Decimal.new(value)
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

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
  which is worth knowing rather than being quietly given.
  """
  @spec place_order(map(), map(), keyword()) ::
          {:ok, Types.Order.t()} | {:error, term()} | {:refused, term()}
  def place_order(credentials, request, opts) do
    with {:ok, configuration} <- order_configuration(request) do
      body = %{
        "client_order_id" => Map.get(request, :client_order_id) || generate_client_order_id(),
        "product_id" => SymbolFormat.to_exchange_symbol(Map.fetch!(request, :symbol)),
        "side" => request |> Map.fetch!(:side) |> to_string() |> String.upcase(),
        "order_configuration" => configuration
      }

      case post_json("/orders", body, credentials, opts) do
        {:ok, %{body: response}} -> to_placed_order(response, request)
        {:error, reason} -> classify(reason)
      end
    end
  end

  # The sparse cross-product, written out. A pair absent from this table is absent from the
  # venue, and `order_configuration/1` refuses rather than reaching for a neighbour.
  @configurations %{
    {:market, :ioc} => "market_market_ioc",
    {:market, :fok} => "market_market_fok",
    {:limit, :gtc} => "limit_limit_gtc",
    {:limit, :gtd} => "limit_limit_gtd",
    {:limit, :fok} => "limit_limit_fok",
    {:stop_limit, :gtc} => "stop_limit_stop_limit_gtc",
    {:stop_limit, :gtd} => "stop_limit_stop_limit_gtd"
  }

  defp order_configuration(request) do
    type = Map.get(request, :order_type, :limit)
    tif = Map.get(request, :time_in_force, :gtc)

    case Map.fetch(@configurations, {type, tif}) do
      {:ok, key} -> build_configuration(key, type, request)
      :error -> {:error, {:unsupported_order_combination, type, tif}}
    end
  end

  defp build_configuration(key, type, request) do
    with {:ok, leaf} <- configuration_leaf(type, request) do
      {:ok, %{key => leaf}}
    end
  end

  # A market order sizes in base or quote; a limit order needs a price. Missing either is an
  # error rather than a default, because a default here is a different order.
  defp configuration_leaf(:market, request) do
    case {Map.get(request, :quantity), Map.get(request, :quote_size)} do
      {nil, nil} -> {:error, :missing_order_size}
      {nil, quote_size} -> {:ok, %{"quote_size" => to_string(quote_size)}}
      {quantity, _quote_size} -> {:ok, %{"base_size" => to_string(quantity)}}
    end
  end

  defp configuration_leaf(:limit, request) do
    with {:ok, price} <- required_field(request, :price, :missing_limit_price) do
      leaf = %{
        "base_size" => to_string(Map.fetch!(request, :quantity)),
        "limit_price" => to_string(price)
      }

      {:ok, maybe_put_configuration(leaf, request)}
    end
  end

  defp configuration_leaf(:stop_limit, request) do
    with {:ok, price} <- required_field(request, :price, :missing_limit_price),
         {:ok, stop} <- required_field(request, :stop_price, :missing_stop_price) do
      leaf = %{
        "base_size" => to_string(Map.fetch!(request, :quantity)),
        "limit_price" => to_string(price),
        "stop_price" => to_string(stop)
      }

      {:ok, maybe_put_configuration(leaf, request)}
    end
  end

  defp maybe_put_configuration(leaf, request) do
    leaf
    |> put_unless_nil("post_only", Map.get(request, :post_only))
    |> put_unless_nil("end_time", Map.get(request, :end_time))
  end

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, to_string(value))

  defp required_field(request, key, error) do
    case Map.get(request, key) do
      nil -> {:error, error}
      value -> {:ok, value}
    end
  end

  # The venue answers 200 with `success: false` for a rejected order. Treating that as a
  # placed order is the failure this clause exists to prevent — the HTTP call succeeded and
  # the order did not.
  defp to_placed_order(%{"success" => true, "success_response" => success}, request) do
    {:ok,
     %Types.Order{
       id: success["order_id"],
       symbol: Map.fetch!(request, :symbol),
       side: Map.fetch!(request, :side),
       order_type: Map.get(request, :order_type, :limit),
       time_in_force: Map.get(request, :time_in_force, :gtc),
       quantity: Map.get(request, :quantity),
       price: Map.get(request, :price),
       status: :pending,
       provider: :coinbase
     }}
  end

  defp to_placed_order(%{"success" => false} = response, _request) do
    {:refused, {:order_rejected, failure_reason(response)}}
  end

  defp to_placed_order(_other, _request), do: {:error, :unexpected_response_shape}

  defp failure_reason(%{"error_response" => %{"error" => error}}) when is_binary(error), do: error
  defp failure_reason(%{"failure_reason" => reason}) when is_binary(reason), do: reason
  defp failure_reason(_response), do: :unspecified

  # A POST carrying a JSON body. Separate from `request/5` rather than an extra parameter on
  # it, because every existing caller is a GET and adding an argument to all of them to
  # serve one is how a helper becomes hard to read.
  #
  # The body is **not** signed: this venue's JWT is scoped to the method and URI, so the
  # signature does not cover the payload (see `Auth.rest_headers/4`, whose body argument is
  # ignored on purpose).
  defp post_json(path, body, credentials, opts) do
    headers =
      HttpClient.build_auth_headers(
        :post,
        @api_path <> path,
        nil,
        credentials,
        &Auth.rest_headers/4
      )

    request_opts =
      opts
      |> Keyword.take([:timeout, :retry_attempts, :retry_delay, :plug, :weight])
      |> Keyword.put(:provider, :coinbase)
      |> Keyword.put_new(:limiter, Keyword.get(opts, :limiter, DpExchange.Coinbase.RateLimiter))

    HttpClient.request(
      :post,
      @base_url <> @api_path <> path,
      headers,
      Jason.encode!(body),
      request_opts
    )
  end

  # A v4 UUID from the VM's own CSPRNG, rather than a dependency.
  #
  # Coinbase requires `client_order_id` and treats it as an idempotency key: re-sending one
  # returns the original order instead of placing a second. That makes it worth generating
  # correctly — a colliding id would silently return someone else's order — and not worth a
  # library for sixteen bytes.
  defp generate_client_order_id do
    <<a::32, b::16, _version::4, c::12, _variant::2, d::62>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-a~3.16.0b-~12.16.0b", [
      a,
      b,
      c,
      Bitwise.bsr(d, 50),
      Bitwise.band(d, 0xFFFFFFFFFFFF)
    ])
    |> IO.iodata_to_binary()
  end

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
    case post_json("/orders/batch_cancel", %{"order_ids" => [order_id]}, credentials, opts) do
      {:ok, %{body: body}} -> cancel_result(body, order_id)
      {:error, reason} -> classify(reason)
    end
  end

  defp cancel_result(%{"results" => results}, order_id) when is_list(results) do
    case Enum.find(results, &(&1["order_id"] == order_id)) do
      %{"success" => true} -> {:ok, :cancelled}
      %{"failure_reason" => reason} -> {:refused, {:cancel_rejected, reason}}
      # The venue answered about orders, and none of them was the one asked about. That is
      # not a cancelled order and it is not an error from the transport either.
      nil -> {:error, :order_not_in_response}
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
    case request(:get, "/orders/historical/#{order_id}", credentials, opts) do
      {:ok, %{body: %{"order" => order}}} -> {:ok, to_order(order)}
      {:ok, %{body: _other}} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
    end
  end

  @doc """
  Orders, most recent first.

  `:status` and `:symbol` in `opts` filter at the venue rather than here — a client-side
  filter over one page would silently drop matching orders that were on the next one.

  **This returns one page.** The venue paginates with a cursor and this does not follow it,
  which is a limit worth stating rather than a total worth trusting: a caller reconciling
  positions against a truncated order list would find a difference it could not explain.
  """
  @spec get_orders(map(), keyword()) ::
          {:ok, [Types.Order.t()]} | {:error, term()} | {:refused, term()}
  def get_orders(credentials, opts) do
    params =
      %{}
      |> put_unless_nil("order_status", opts |> Keyword.get(:status) |> order_status_param())
      |> put_unless_nil("product_ids", venue_symbol(Keyword.get(opts, :symbol)))
      |> put_unless_nil("limit", Keyword.get(opts, :limit))

    case request(:get, "/orders/historical/batch", credentials, opts, params) do
      {:ok, %{body: %{"orders" => orders}}} when is_list(orders) ->
        {:ok, Enum.map(orders, &to_order/1)}

      {:ok, %{body: _other}} ->
        {:error, :unexpected_response_shape}

      {:error, reason} ->
        classify(reason)
    end
  end

  defp order_status_param(nil), do: nil

  defp order_status_param(status) when is_atom(status),
    do: status |> to_string() |> String.upcase()

  defp order_status_param(status) when is_binary(status), do: String.upcase(status)

  defp venue_symbol(nil), do: nil
  defp venue_symbol(symbol), do: SymbolFormat.to_exchange_symbol(symbol)

  # The venue's status vocabulary, mapped to the contract's.
  #
  # `QUEUED` and `CANCEL_QUEUED` are the venue's own intermediate states — accepted, not yet
  # working, and accepted-for-cancellation-but-still-live. Both map to `:open`: the order
  # exists and may still fill, which is what a caller needs to know. Mapping CANCEL_QUEUED
  # to `:cancelled` would tell a caller an order is gone while it can still trade.
  @statuses %{
    "PENDING" => :pending,
    "QUEUED" => :open,
    "OPEN" => :open,
    "CANCEL_QUEUED" => :open,
    "FILLED" => :filled,
    "CANCELLED" => :cancelled,
    "EXPIRED" => :expired,
    "FAILED" => :rejected
  }

  defp to_order(order) do
    %Types.Order{
      id: order["order_id"],
      symbol: order |> Map.get("product_id") |> canonical_or_nil(),
      side: order |> Map.get("side") |> side_atom(),
      order_type: order |> Map.get("order_type") |> type_atom(),
      time_in_force: order |> Map.get("time_in_force") |> tif_atom(),
      quantity: decimal(order["filled_size"]),
      filled_quantity: decimal(order["filled_size"]),
      average_price: decimal(order["average_filled_price"]),
      fee: decimal(order["total_fees"]),
      fee_currency: order["fee_currency"],
      # An unmapped status is `nil`, never a guess. A caller branching on :open would
      # otherwise act on a state the venue named and this package did not recognise.
      status: Map.get(@statuses, order["status"]),
      created_at: parse_created(order["created_time"]),
      provider: :coinbase
    }
  end

  defp canonical_or_nil(nil), do: nil
  defp canonical_or_nil(native), do: SymbolFormat.to_canonical_symbol(native)

  defp side_atom("BUY"), do: :buy
  defp side_atom("SELL"), do: :sell
  defp side_atom(_other), do: nil

  defp type_atom("MARKET"), do: :market
  defp type_atom("LIMIT"), do: :limit
  defp type_atom("STOP_LIMIT"), do: :stop_limit
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
  @spec preview_order(map(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def preview_order(credentials, request, opts) do
    with {:ok, configuration} <- order_configuration(request) do
      body = %{
        "product_id" => SymbolFormat.to_exchange_symbol(Map.fetch!(request, :symbol)),
        "side" => request |> Map.fetch!(:side) |> to_string() |> String.upcase(),
        "order_configuration" => configuration
      }

      case post_json("/orders/preview", body, credentials, opts) do
        {:ok, %{body: response}} -> preview_result(response)
        {:error, reason} -> classify(reason)
      end
    end
  end

  defp preview_result(%{"errs" => errs} = _response) when is_list(errs) and errs != [] do
    {:refused, {:preview_rejected, errs}}
  end

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

  Accepts the same changes `replace_order/4` does — `:price` and `:quantity`, at least one
  of them — and refuses anything else here rather than sending it and reading the venue's
  business error.

  **The response's `errors` array is the refusal.** As with `/orders/preview`, an HTTP 200
  carrying errors is the venue saying no; this returns `{:refused, …}` rather than an `:ok`
  a caller would read as a green light.
  """
  @spec preview_replace(map(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def preview_replace(credentials, order_id, changes, opts) do
    with :ok <- editable_changes(changes) do
      body =
        %{"order_id" => order_id}
        |> put_unless_nil("price", Map.get(changes, :price))
        |> put_unless_nil("size", Map.get(changes, :quantity))

      case post_json("/orders/edit_preview", body, credentials, opts) do
        {:ok, %{body: response}} -> edit_preview_result(response)
        {:error, reason} -> classify(reason)
      end
    end
  end

  defp edit_preview_result(%{"errors" => errors}) when is_list(errors) and errors != [] do
    {:refused, {:edit_preview_rejected, errors}}
  end

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
    body =
      %{
        "client_order_id" => Keyword.get(opts, :client_order_id) || generate_client_order_id(),
        "product_id" => SymbolFormat.to_exchange_symbol(symbol)
      }
      |> put_unless_nil("size", Keyword.get(opts, :size))

    case post_json("/orders/close_position", body, credentials, opts) do
      {:ok, %{body: response}} -> to_closing_order(response, symbol)
      {:error, reason} -> classify(reason)
    end
  end

  defp to_closing_order(%{"success" => true, "success_response" => success} = response, symbol) do
    # The venue echoes the order it placed in `order_configuration`, which is the only
    # statement of what this order *is* — the caller never said. Read from there rather
    # than assumed, and `nil` for anything it does not name.
    {type, tif, quantity} = closing_configuration(response["order_configuration"])

    {:ok,
     %Types.Order{
       id: success["order_id"],
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
     }}
  end

  defp to_closing_order(%{"success" => false} = response, _symbol) do
    {:refused, {:close_rejected, failure_reason(response)}}
  end

  defp to_closing_order(_other, _symbol), do: {:error, :unexpected_response_shape}

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

  A `200` carrying `success: false` is a refusal, as everywhere else on this venue.
  """
  @spec replace_order(map(), String.t(), map(), keyword()) ::
          {:ok, Types.Order.t()} | {:error, term()} | {:refused, term()}
  def replace_order(credentials, order_id, changes, opts) do
    with :ok <- editable_changes(changes) do
      body =
        %{"order_id" => order_id}
        |> put_unless_nil("price", Map.get(changes, :price))
        |> put_unless_nil("size", Map.get(changes, :quantity))

      case post_json("/orders/edit", body, credentials, opts) do
        {:ok, %{body: response}} -> edit_result(response, order_id, credentials, opts)
        {:error, reason} -> classify(reason)
      end
    end
  end

  @editable [:price, :quantity]

  defp editable_changes(changes) do
    case Map.keys(changes) -- @editable do
      [] -> editable_present(changes)
      unsupported -> {:error, {:unsupported_order_edit, unsupported}}
    end
  end

  defp editable_present(changes) do
    if Enum.any?(@editable, &Map.has_key?(changes, &1)) do
      :ok
    else
      {:error, :no_order_changes}
    end
  end

  defp edit_result(%{"success" => true}, order_id, credentials, opts) do
    # The venue's edit response carries no order body — only that it worked. Building an
    # `Order` from the request would report what was *asked for* as though the venue had
    # confirmed it, which is a different thing and the one this family keeps getting wrong.
    #
    # So the order is read back. It costs a second call and returns the venue's own view,
    # including whatever it did with the edit that the caller did not ask for.
    get_order(credentials, order_id, opts)
  end

  defp edit_result(%{"success" => false} = response, _order_id, _credentials, _opts) do
    {:refused, {:edit_rejected, edit_failure(response)}}
  end

  defp edit_result(_other, _order_id, _credentials, _opts),
    do: {:error, :unexpected_response_shape}

  defp edit_failure(%{"errors" => [%{"edit_failure_reason" => reason} | _rest]})
       when is_binary(reason),
       do: reason

  defp edit_failure(_response), do: :unspecified
end

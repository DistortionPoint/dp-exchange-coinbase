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
        {:ok, %{body: body}} -> to_candles(body, symbol)
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
  Best bid and ask for `symbol` — the top of the book, not a traded price.

  Reads the same ticker payload as `get_price/2`, which carries `best_bid` and `best_ask`
  alongside the trades. Those used to ride on the `Quote`; `Core.Types.Quote` has no fields
  for them now, because a resting order is not an execution.

  The payload publishes no sizes at the top, so `bid_size` and `ask_size` stay `nil` — not
  published rather than zero.
  """
  @spec get_top_of_book(String.t(), keyword()) ::
          {:ok, Types.TopOfBook.t()} | {:error, term()} | {:refused, term()}
  def get_top_of_book(symbol, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    credentials = Keyword.get(opts, :credentials)

    path =
      if credentials,
        do: "/products/#{native}/ticker",
        else: "/market/products/#{native}/ticker"

    with {:ok, body} <- request(:get, path, credentials, opts, %{"limit" => "1"}) do
      {:ok,
       %Types.TopOfBook{
         symbol: SymbolFormat.to_canonical_symbol(native),
         bid: decimal(body["best_bid"]),
         ask: decimal(body["best_ask"]),
         bid_size: nil,
         ask_size: nil,
         venue_time: top_of_book_time(body),
         observed_at: DateTime.utc_now(),
         provider: :coinbase
       }}
    end
  end

  # The ticker stamps its trades, not its book. Where the newest trade carries a time it is
  # the closest thing the venue states to when this book was current; absent, `nil` rather
  # than the local clock, which `observed_at` already holds and says so.
  defp top_of_book_time(%{"trades" => [trade | _rest]}) do
    case parse_time(trade["time"]) do
      {:ok, at} -> at
      _unparsable -> nil
    end
  end

  defp top_of_book_time(_body), do: nil

  defp to_candles(%{"candles" => candles}, symbol) do
    {:ok,
     candles
     |> Enum.map(fn candle ->
       %Types.Quote{
         symbol: symbol,
         price: decimal(candle["close"]),
         volume: decimal(candle["volume"]),
         # The venue's own bucket start, used as-is. Not re-derived, not rounded.
         timestamp: candle["start"] |> String.to_integer() |> DateTime.from_unix!(),
         provider: :coinbase
       }
     end)
     |> Enum.sort_by(& &1.timestamp, DateTime)}
  end

  defp to_candles(_body, _symbol), do: {:error, :unexpected_response_shape}

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
end

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

    case request(:get, path, credentials, opts) do
      {:ok, %{body: body}} -> build_top_of_book(native, body)
      {:error, reason} -> classify(reason)
    end
  end

  defp build_top_of_book(native, body) do
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
end

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
  alias DpExchange.Core.{HttpClient, Instrument, Timeframe, Types}

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

      # The venue publishes the same candles twice: `/market/products/…` unauthenticated
      # and `/products/…` for a credential. Reading the public one while holding a
      # credential would silently forgo whatever the authenticated view adds.
      credentials = Keyword.get(opts, :credentials)

      path =
        if credentials,
          do: "/products/#{native}/candles",
          else: "/market/products/#{native}/candles"

      case request(:get, path, credentials, opts, params) do
        {:ok, %{body: body}} -> to_candles(body, symbol, timeframe)
        {:error, reason} -> classify(reason)
      end
    end
  end

  @doc "Every product Coinbase lists, as canonical symbols."
  @spec get_symbols(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def get_symbols(opts) do
    with {:ok, products} <- fetch_products(opts) do
      {:ok, Enum.map(products, &SymbolFormat.to_canonical_symbol(&1["product_id"]))}
    end
  end

  @doc """
  A bulk snapshot across every product Coinbase lists: price, 24h change, 24h volume, 24h
  high/low and status, one entry per canonical symbol.

  Reads the same bulk endpoint `get_symbols/1` does — the venue's per-product row already
  carries all of this, so there is no second request behind it.
  """
  @spec get_market_overview(keyword()) :: {:ok, map()} | {:error, term()}
  def get_market_overview(opts) do
    with {:ok, products} <- fetch_products(opts) do
      {:ok, Map.new(products, &market_overview_row/1)}
    end
  end

  @doc """
  Every product Coinbase lists, with the fields `get_symbols/1` discards: base, quote,
  instrument type and trading status.

  Reads the same bulk endpoint `get_symbols/1` does.
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

  ## `{:error, _}` is a real possibility, and callers must not guess through it

  This is a bulk catalogue read like `get_symbols/1`, subject to the same failures — see
  `Feed`'s moduledoc for what it does when this call fails: deliver under the venue's own
  id, same as before this map existed, plus a notice that attribution is degraded and
  why. Never a fabricated mapping.
  """
  @spec get_alias_map(keyword()) :: {:ok, %{String.t() => String.t()}} | {:error, term()}
  def get_alias_map(opts) do
    with {:ok, products} <- fetch_products(opts) do
      {:ok, Enum.reduce(products, %{}, &add_alias_pair/2)}
    end
  end

  defp add_alias_pair(%{"product_id" => product_id, "alias" => alias_id}, acc)
       when is_binary(alias_id) and alias_id != "" do
    canonical = SymbolFormat.to_canonical_symbol(product_id)
    aliased = SymbolFormat.to_canonical_symbol(alias_id)

    acc
    |> Map.put(canonical, aliased)
    |> Map.put(aliased, canonical)
  end

  defp add_alias_pair(_product, acc), do: acc

  # Public and private again: the venue publishes the catalogue at both paths, and a
  # caller holding a credential should see the authenticated view. Shared by
  # get_symbols/1, get_market_overview/1 and list_instruments/1 — one venue response,
  # three views of it, rather than one call per view of the same row.
  defp fetch_products(opts) do
    credentials = Keyword.get(opts, :credentials)
    path = if credentials, do: "/products", else: "/market/products"

    case request(:get, path, credentials, opts) do
      {:ok, %{body: %{"products" => products}}} -> {:ok, products}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
    end
  end

  defp market_overview_row(product) do
    symbol = SymbolFormat.to_canonical_symbol(product["product_id"])

    {symbol,
     %{
       price: decimal(product["price"]),
       price_change_24h_pct: decimal(product["price_percentage_change_24h"]),
       volume_24h: decimal(product["volume_24h"]),
       high_24h: decimal(product["high_24h"]),
       low_24h: decimal(product["low_24h"]),
       status: product["status"]
     }}
  end

  defp to_instrument(product) do
    Instrument.new(
      symbol: SymbolFormat.to_canonical_symbol(product["product_id"]),
      base: product["base_currency_id"],
      quote: product["quote_currency_id"],
      instrument: Instrument.instrument_from(product["product_type"]),
      status: Instrument.status_from(product["status"])
    )
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
      {:ok, %{body: %{"payment_methods" => methods}}} when is_list(methods) -> {:ok, methods}
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
  def get_payment_method(credentials, id, opts) when is_binary(id) do
    case request(:get, "/payment_methods/#{id}", credentials, opts) do
      {:ok, %{body: %{"payment_method" => method}}} when is_map(method) -> {:ok, method}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
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
  not a number this venue accepts.
  """
  @spec transfer_internal(map(), String.t(), Decimal.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def transfer_internal(credentials, asset, amount, opts) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    with :ok <- both_portfolios(from, to) do
      body = %{
        "funds" => %{"value" => Decimal.to_string(amount, :normal), "currency" => asset},
        "source_portfolio_uuid" => from,
        "target_portfolio_uuid" => to
      }

      case post_json("/portfolios/move_funds", body, credentials, opts) do
        {:ok, %{body: %{} = result}} -> {:ok, result}
        {:ok, _unexpected} -> {:error, :unexpected_response_shape}
        {:error, reason} -> classify(reason)
      end
    end
  end

  defp both_portfolios(from, to) when is_binary(from) and is_binary(to), do: :ok
  defp both_portfolios(_from, _to), do: {:error, :missing_portfolio}

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

  `goods_and_services_tax` is carried where the venue sends it: a rate quoted `INCLUSIVE` and
  the same rate quoted `EXCLUSIVE` are different amounts of money.
  """
  @spec get_fees(map(), keyword()) :: {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_fees(credentials, opts) do
    with {:ok, summary} <- transaction_summary(credentials, opts), do: {:ok, summary}
  end

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

      rows =
        summary
        |> Map.get("volume_breakdown", [])
        |> List.wrap()
        |> Enum.map(&Map.merge(&1, totals))

      {:ok, rows}
    end
  end

  defp transaction_summary(credentials, opts) do
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

  # --- portfolios ---------------------------------------------------------

  @doc """
  The portfolios this credential can address — `GET /portfolios`.

  **A portfolio is an address, not a value.** Balances, orders and positions are asked *of*
  one, and "the account's BTC balance" is not a well-formed question on a venue that has
  them.

  `opts[:portfolio_type]` filters by the venue's own enum where a caller gives one; nothing
  is sent otherwise, because a filter this package chose would hide portfolios the caller
  did not ask to hide.

  **`deleted` rides on the row and is not filtered out here.** A deleted portfolio is still
  returned by the venue and still holds history; dropping it would make an id that appears in
  an old order look like an id that never existed.
  """
  @spec list_portfolios(map(), keyword()) ::
          {:ok, [Types.Portfolio.t()]} | {:error, term()} | {:refused, term()}
  def list_portfolios(credentials, opts) do
    params = put_unless_nil(%{}, "portfolio_type", Keyword.get(opts, :portfolio_type))

    case request(:get, "/portfolios", credentials, opts, params) do
      {:ok, %{body: %{"portfolios" => portfolios}}} when is_list(portfolios) ->
        {:ok, Enum.map(portfolios, &to_portfolio/1)}

      {:ok, _unexpected} ->
        {:error, :unexpected_response_shape}

      {:error, reason} ->
        classify(reason)
    end
  end

  defp to_portfolio(row) do
    %Types.Portfolio{
      id: row["uuid"],
      name: row["name"],
      type: row["type"],
      deleted: row["deleted"],
      provider: :coinbase
    }
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
  def get_portfolio_breakdown(credentials, portfolio_uuid, opts)
      when is_binary(portfolio_uuid) do
    params = put_unless_nil(%{}, "currency", Keyword.get(opts, :currency))

    case request(:get, "/portfolios/#{portfolio_uuid}", credentials, opts, params) do
      {:ok, %{body: %{"breakdown" => breakdown}}} when is_map(breakdown) -> {:ok, breakdown}
      {:ok, %{body: %{} = body}} -> {:ok, body}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
    end
  end

  @doc """
  Creates a portfolio — `POST /portfolios`.

  `opts[:name]` is required and is not defaulted: an unnamed portfolio is one a caller cannot
  tell from another later, and the venue has no notion of a nameless one.
  """
  @spec create_portfolio(map(), keyword()) ::
          {:ok, Types.Portfolio.t()} | {:error, term()} | {:refused, term()}
  def create_portfolio(credentials, opts) do
    with {:ok, name} <- required_name(opts) do
      case post_json("/portfolios", %{"name" => name}, credentials, opts) do
        {:ok, %{body: %{"portfolio" => portfolio}}} when is_map(portfolio) ->
          {:ok, to_portfolio(portfolio)}

        {:ok, _unexpected} ->
          {:error, :unexpected_response_shape}

        {:error, reason} ->
          classify(reason)
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
  def rename_portfolio(credentials, portfolio_uuid, name, opts)
      when is_binary(portfolio_uuid) and is_binary(name) do
    case put_json("/portfolios/#{portfolio_uuid}", %{"name" => name}, credentials, opts) do
      {:ok, %{body: %{"portfolio" => portfolio}}} when is_map(portfolio) ->
        {:ok, to_portfolio(portfolio)}

      {:ok, _unexpected} ->
        {:error, :unexpected_response_shape}

      {:error, reason} ->
        classify(reason)
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
  def delete_portfolio(credentials, portfolio_uuid, opts) when is_binary(portfolio_uuid) do
    case request(:delete, "/portfolios/#{portfolio_uuid}", credentials, opts) do
      {:ok, %{body: %{} = result}} -> {:ok, result}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
    end
  end

  defp required_name(opts) do
    case Keyword.get(opts, :name) do
      name when is_binary(name) -> {:ok, name}
      _missing -> {:error, :name_required}
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
      {:ok, to_conversion(trade, from, to)}
    end
  end

  @doc """
  Commits a quoted conversion — `POST /convert/trade/{trade_id}`. **This moves funds.**

  **The venue re-asks for both accounts**, and this package does not fill them in from the
  quote: `opts[:from]` and `opts[:to]` are required and refused when missing. Committing
  against accounts the caller did not name is how a conversion happens between the wrong two
  balances.
  """
  @spec commit_conversion(map(), String.t(), keyword()) ::
          {:ok, Types.Conversion.t()} | {:error, term()} | {:refused, term()}
  def commit_conversion(credentials, trade_id, opts) when is_binary(trade_id) do
    with {:ok, from, to} <- convert_accounts(opts) do
      body = %{"from_account" => from, "to_account" => to}

      with {:ok, trade} <-
             convert_trade(post_json("/convert/trade/#{trade_id}", body, credentials, opts)) do
        {:ok, to_conversion(trade, from, to)}
      end
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
  def get_conversion(credentials, trade_id, opts) when is_binary(trade_id) do
    with {:ok, from, to} <- convert_accounts(opts) do
      params = %{"from_account" => from, "to_account" => to}

      with {:ok, trade} <-
             convert_trade(request(:get, "/convert/trade/#{trade_id}", credentials, opts, params)) do
        {:ok, to_conversion(trade, from, to)}
      end
    end
  end

  defp convert_accounts(opts) do
    case {Keyword.get(opts, :from), Keyword.get(opts, :to)} do
      {from, to} when is_binary(from) and is_binary(to) -> {:ok, from, to}
      _missing -> {:error, :from_and_to_required}
    end
  end

  defp convert_trade({:ok, %{body: %{"trade" => trade}}}) when is_map(trade), do: {:ok, trade}
  defp convert_trade({:ok, _unexpected}), do: {:error, :unexpected_response_shape}
  defp convert_trade({:error, reason}), do: classify(reason)

  # `from_asset` and `to_asset` come from what the caller asked for, not from the response:
  # the venue's amounts carry a currency each, but which is the source and which the
  # destination is the caller's question and the response does not label them.
  defp to_conversion(trade, from, to) do
    %Types.Conversion{
      id: trade["id"],
      status: conversion_status(trade["status"]),
      from_asset: from,
      to_asset: to,
      from_amount: amount_value(trade["user_entered_amount"]),
      to_amount: amount_value(trade["total"]),
      rate: nil,
      fee: amount_value(trade["fees"]),
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
  defp conversion_status("TRADE_STATUS_CANCELED"), do: :expired
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
    with {:ok, rows} <- list_futures_positions(credentials, opts) do
      {:ok, Enum.map(rows, &to_position/1)}
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
    case request(:get, "/cfm/positions", credentials, opts) do
      {:ok, %{body: %{"positions" => positions}}} when is_list(positions) -> {:ok, positions}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
    end
  end

  @doc """
  One futures position by product — `GET /cfm/positions/{product_id}`.

  The product id is the contract, expiry included — `BIT-28JUL23-CDE`, not `BIT`. A future
  is a different instrument each expiry, and a caller holding two months holds two positions.
  """
  @spec get_futures_position(map(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_futures_position(credentials, product_id, opts) when is_binary(product_id) do
    case request(:get, "/cfm/positions/#{product_id}", credentials, opts) do
      {:ok, %{body: %{"position" => position}}} when is_map(position) -> {:ok, position}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
    end
  end

  # "UNKNOWN" is the venue's own value and maps to nil rather than to a side. A position
  # filed the wrong way round is the most expensive mistake available in this mapping.
  defp to_position(row) do
    %Types.Position{
      symbol: row["product_id"],
      side: futures_side(row["side"]),
      quantity: amount_value(row["number_of_contracts"]),
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

  defp futures_side("LONG"), do: :long
  defp futures_side("SHORT"), do: :short
  defp futures_side(_other), do: nil

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
    case request(:get, "/cfm/balance_summary", credentials, opts) do
      {:ok, %{body: %{"balance_summary" => summary}}} when is_map(summary) -> {:ok, summary}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
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
    case request(:get, "/cfm/sweeps", credentials, opts) do
      {:ok, %{body: %{"sweeps" => sweeps}}} when is_list(sweeps) -> {:ok, sweeps}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
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
  because a caller that thought a missing amount meant "nothing" would move the lot.
  """
  @spec schedule_futures_sweep(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def schedule_futures_sweep(credentials, opts) do
    body = put_unless_nil(%{}, "usd_amount", sweep_amount(Keyword.get(opts, :usd_amount)))

    case post_json("/cfm/sweeps/schedule", body, credentials, opts) do
      {:ok, %{body: %{} = result}} -> {:ok, result}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
    end
  end

  # Full notation, never scientific — and a string, because that is what the venue's schema
  # says `usd_amount` is.
  defp sweep_amount(nil), do: nil
  defp sweep_amount(%Decimal{} = amount), do: Decimal.to_string(amount, :normal)
  defp sweep_amount(amount), do: to_string(amount)

  @doc """
  Cancels the pending sweep — `DELETE /cfm/sweeps`.

  **Singular.** The venue cancels *the* pending sweep and takes no id; a caller with a
  queue cannot choose which one this reaches. `list_futures_sweeps/2` before and after is
  the only way to see what happened.
  """
  @spec cancel_futures_sweep(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def cancel_futures_sweep(credentials, opts) do
    case request(:delete, "/cfm/sweeps", credentials, opts) do
      {:ok, %{body: %{} = result}} -> {:ok, result}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
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
    case request(:get, "/cfm/intraday/margin_setting", credentials, opts) do
      {:ok, %{body: %{"setting" => setting}}} when is_binary(setting) -> {:ok, setting}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
    end
  end

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
  def set_intraday_margin_setting(credentials, setting, opts) when is_binary(setting) do
    case post_json("/cfm/intraday/margin_setting", %{"setting" => setting}, credentials, opts) do
      {:ok, %{body: %{} = result}} -> {:ok, result}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
    end
  end

  @doc """
  Which margin window the account is in now — `GET /cfm/intraday/current_margin_window`.

  Carries `end_time`, which is when the current window closes, and two kill-switch flags.
  **A kill switch being enabled means the venue has turned intraday margin off**, and an
  account that believes it is on intraday margin while the switch is enabled has more
  leverage in its plan than in its account.

  `opts[:margin_profile_type]` is the venue's own enum and is sent only when given.
  """
  @spec get_current_margin_window(map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:refused, term()}
  def get_current_margin_window(credentials, opts) do
    params = put_unless_nil(%{}, "margin_profile_type", Keyword.get(opts, :margin_profile_type))

    case request(:get, "/cfm/intraday/current_margin_window", credentials, opts, params) do
      {:ok, %{body: %{} = result}} -> {:ok, result}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
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
         # The price's increment. NOT base_increment — rounding a price to that produces an
         # order the venue rejects on a field it did not name.
         price_increment: decimal(product["quote_increment"]),
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
    native = SymbolFormat.to_exchange_symbol(symbol)
    credentials = Keyword.get(opts, :credentials)

    path =
      if credentials, do: "/products/#{native}", else: "/market/products/#{native}"

    case request(:get, path, credentials, opts) do
      {:ok, %{body: %{"product_id" => _id} = product}} -> {:ok, product}
      {:ok, _unexpected} -> {:error, :unexpected_response_shape}
      {:error, reason} -> classify(reason)
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
    with {:ok, at} <- parse_time(trade["time"]),
         {:ok, price} <- required_decimal(trade["price"], :price) do
      {:ok,
       %Types.Quote{
         symbol: symbol,
         price: price,
         volume: decimal(trade["size"]),
         timestamp: at,
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

  `opts[:limit]` is the venue's own, passed through. **Coinbase publishes no bust flag on
  the ticker**, so `broken` is `false` on every print — a venue with nothing busted reports
  nothing busted, which is the same answer, and `opts[:include_broken]` therefore changes
  nothing here.
  """
  @spec get_trades(String.t(), keyword()) ::
          {:ok, [Types.Trade.t()]} | {:error, term()} | {:refused, term()}
  def get_trades(symbol, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    credentials = Keyword.get(opts, :credentials)

    path =
      if credentials,
        do: "/products/#{native}/ticker",
        else: "/market/products/#{native}/ticker"

    params = put_unless_nil(%{}, "limit", Keyword.get(opts, :limit))

    case request(:get, path, credentials, opts, params) do
      {:ok, %{body: %{"trades" => trades}}} when is_list(trades) ->
        decode_trades(trades, symbol)

      {:ok, _unexpected} ->
        {:error, :unexpected_response_shape}

      {:error, reason} ->
        classify(reason)
    end
  end

  defp decode_trades(trades, symbol) do
    trades
    |> Enum.reduce_while({:ok, []}, fn trade, {:ok, acc} ->
      case to_trade(trade, symbol) do
        {:ok, decoded} -> {:cont, {:ok, [decoded | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end
  end

  defp to_trade(trade, symbol) do
    with {:ok, at} <- parse_time(trade["time"]),
         {:ok, price} <- required_decimal(trade["price"], :price),
         {:ok, quantity} <- required_decimal(trade["size"], :quantity) do
      {:ok,
       %Types.Trade{
         id: trade["trade_id"],
         symbol: symbol,
         # The venue's `side` on a ticker trade is the taker's. `nil` for anything else
         # rather than the nearer of the two.
         side: side_atom(trade["side"]),
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

  Without credentials this returns `{:refused, :missing_credentials}` before sending
  anything. Sending the request anyway would come back as an opaque 401 that reads like a
  venue outage rather than what it is — a call that needed a credential it was not given.
  """
  @spec get_top_of_book(String.t(), keyword()) ::
          {:ok, Types.TopOfBook.t()} | {:error, term()} | {:refused, term()}
  def get_top_of_book(symbol, opts) do
    native = SymbolFormat.to_exchange_symbol(symbol)
    credentials = Keyword.get(opts, :credentials)

    if is_nil(credentials) do
      {:refused, :missing_credentials}
    else
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
    with {:ok, opened_at} <- candle_start(candle["start"]),
         {:ok, open} <- required_decimal(candle["open"], :open),
         {:ok, high} <- required_decimal(candle["high"], :high),
         {:ok, low} <- required_decimal(candle["low"], :low),
         {:ok, close} <- required_decimal(candle["close"], :close) do
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
  defp decimal(%Decimal{} = value), do: value
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_float(value), do: Decimal.from_float(value)

  # `Decimal.new/1` raises on a string that is not a number. Coinbase sends `""` for a
  # bid or ask it has no value for, which is the same case: absent, not zero — and
  # `Decimal.parse/1`, requiring the whole string be consumed (`{d, ""}`), covers both
  # `""` and any other unparsable string in one clause rather than special-casing empty.
  defp decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {parsed, ""} -> parsed
      _unparsable -> nil
    end
  end

  defp decimal(_other), do: nil

  # A garbage or missing value in a field this contract requires must not become a `nil`
  # carried into `@enforce_keys` — a struct's field list does not check that a value is
  # non-nil, only that the key was given. Refuse the record instead of leaking a `nil`
  # price into a `Quote`/`Trade`/`Candle`, which is the same substitution a raise would
  # have been, wearing a quieter shape.
  defp required_decimal(nil, field), do: {:error, {:missing_required_field, field}}

  defp required_decimal(value, field) do
    case decimal(value) do
      nil -> {:error, {:invalid_decimal, field, value}}
      parsed -> {:ok, parsed}
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
  # The venue's own object, sent as it was given. `put_unless_nil/3` stringifies, which turns
  # a nested map into its inspect form and the venue into a caller error.
  defp put_raw_unless_nil(map, _key, nil), do: map
  defp put_raw_unless_nil(map, key, value), do: Map.put(map, key, value)

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
  defp post_json(path, body, credentials, opts),
    do: json_request(:post, path, body, credentials, opts)

  defp put_json(path, body, credentials, opts),
    do: json_request(:put, path, body, credentials, opts)

  defp json_request(method, path, body, credentials, opts) do
    headers =
      HttpClient.build_auth_headers(
        method,
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
      method,
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
      # `filled_size` is what has filled, not what was asked for — reusing it here made a
      # partially-filled order's remaining size read as zero on every read after placement.
      # The venue echoes what was actually requested in `order_configuration`, the same
      # place `closing_configuration/1` below already reads it from for a closing order.
      quantity: quantity_from_configuration(order["order_configuration"]),
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

  # A quote-sized market order's leaf carries `quote_size`, not `base_size`, and there is
  # no rate here to convert one to the other — `nil`, not a guess, same as
  # `closing_configuration/1` below for the same shape.
  defp quantity_from_configuration(%{} = configuration) when map_size(configuration) == 1 do
    [{_name, leaf}] = Map.to_list(configuration)
    decimal(is_map(leaf) && leaf["base_size"])
  end

  defp quantity_from_configuration(_absent), do: nil

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

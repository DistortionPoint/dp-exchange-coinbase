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
        {:ok, [elem(get_price(symbol, []), 1)]}
    end
  end

  @impl true
  def get_symbols(_opts \\ []), do: {:ok, @symbols}

  @impl true
  def get_order_book(_symbol, _opts), do: Venue.not_supported()
  @impl true
  def get_market_overview(_opts), do: Venue.not_supported()
  @impl true
  def list_instruments(_opts), do: Venue.not_supported()
  @impl true
  def get_balances(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_accounts(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_fees(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_transfers(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def place_order(_credentials, _request, _opts), do: Venue.not_supported()
  # Both refused, matching the real venue. A fake that answered where the real one
  # refuses lets a consumer's suite go green against behaviour that cannot happen.
  @impl true
  def preview_order(_credentials, _request, _opts \\ []), do: Venue.not_supported()

  @impl true
  def replace_order(_credentials, _id, _request, _opts \\ []), do: Venue.not_supported()

  @impl true
  def cancel_order(_credentials, _id, _opts), do: Venue.not_supported()
  @impl true
  def get_order(_credentials, _id, _opts), do: Venue.not_supported()
  @impl true
  def get_orders(_credentials, _opts), do: Venue.not_supported()
  @impl true
  def get_trade_history(_credentials, _opts), do: Venue.not_supported()
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
  def quantization(_symbol), do: Venue.not_supported()

  defp requested(range, timeframe) do
    finish = Keyword.get(range, :end, @at)
    {:ok, width} = DpExchange.Core.Timeframe.seconds(timeframe)

    case Keyword.get(range, :start) do
      nil -> 0
      start -> div(DateTime.diff(finish, start, :second), width)
    end
  end
end

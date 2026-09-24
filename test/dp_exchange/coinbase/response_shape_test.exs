defmodule DpExchange.Coinbase.ResponseShapeTest do
  use ExUnit.Case, async: true

  alias DpExchange.Core.Config

  # **A response of the wrong JSON shape is an answer, never a raise.**
  #
  # `Core.Venue`'s error discipline is that a facade call answers — `{:ok, _}`,
  # `{:error, _}`, `{:refused, _}` — and does not raise in the caller's process. These are
  # the calls that did, found by feeding every active facade callback a set of plausible
  # but wrong bodies: `[]`, `null`, `{}`, an object whose list fields are all `null`, and
  # `{"data": {}}`. Each row below is one body that used to raise, and the exception it
  # raised. Driven through the FACADE, with the HTTP layer replaced by a `plug:`, so what
  # is measured is exactly the decode path a consumer reaches.
  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{
    api_key: "organizations/o/apiKeys/k",
    api_secret: Base.encode64(:crypto.strong_rand_bytes(64))
  }

  defp answering(body), do: fn conn -> Req.Test.json(conn, body) end

  defp base(body) do
    [
      plug: answering(body),
      retry_attempts: 0,
      credentials: @credentials,
      account_id: "acct",
      account_number: "acct",
      account_hash: "acct"
    ]
  end

  defp answers_without_raising(label, fun) do
    result =
      try do
        fun.()
      rescue
        error -> {:raised, error}
      end

    refute match?({:raised, _error}, result),
           "coinbase: #{label} raised #{inspect(result)} — a response shape it did not " <>
             "expect must be refused, not raised in the caller's process"

    result
  end

  # Every one of these read `%{"key" => list}` without `when is_list(list)`, so a
  # `null` list got past the match and raised `Protocol.UndefinedError` further down.
  # Each module already had an `{:error, :unexpected_response_shape}` fall-through; the
  # guard is what routes `null` to it.
  test "a list field that is null is refused, on every endpoint that reads one" do
    body = Map.new(~w(accounts products fills candles data results orders), &{&1, nil})
    v = DpExchange.Coinbase

    for {label, call} <- [
          {"get_accounts/2", fn -> v.get_accounts(@credentials, base(body)) end},
          {"get_balances/2", fn -> v.get_balances(@credentials, base(body)) end},
          {"get_trade_history/2", fn -> v.get_trade_history(@credentials, base(body)) end},
          {"get_symbols/1", fn -> v.get_symbols(base(body)) end},
          {"get_market_overview/1", fn -> v.get_market_overview(base(body)) end},
          {"list_instruments/1", fn -> v.list_instruments(base(body)) end},
          {"get_historical_prices/4",
           fn -> v.get_historical_prices("BTC-USD", "1h", [], base(body)) end}
        ] do
      assert {:error, _reason} = answers_without_raising(label, call)
    end
  end
end

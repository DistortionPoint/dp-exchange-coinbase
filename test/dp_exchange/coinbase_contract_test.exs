defmodule DpExchange.CoinbaseContractTest do
  @moduledoc """
  Core's conformance suite, run against this package. Shipped by `dp_exchange_core` and
  identical across every venue in the family — which is what stops six CLAUDE.md files
  drifting apart.
  """

  # Group 42 drives the real `Rest.place_order/3`, which asks the rate limiter before sending;
  # no limiter runs under the contract, so a process-scoped permissive one stands in.
  defmodule ContractLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  use DpExchange.Core.AdapterContract,
    venue: DpExchange.Coinbase,
    fake: DpExchange.Coinbase.Fake,
    symbol_format: DpExchange.Coinbase.SymbolFormat,
    sample_pairs: ~w(BTC-USD ETH-USD BTC-USDC),
    # Conformance group 41 (family reasons, 2026-10-14): a well-formed symbol the fake does
    # not list, and a credentials map whose first value carries a trailing newline.
    unlisted_symbol: "NOPE-USD",
    padded_credentials: %{
      api_key: "test-key\n",
      api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
    },
    # `lib/vendor/` is third-party code, a patched websockex fork (see
    # `DpExchange.Coinbase.Vendor.WebSockex`). The scanning assertions are written for this
    # family's own conventions, so they read `lib/dp_exchange` only, as Webull's do.
    package_root: "lib/dp_exchange",
    credentials: %{
      api_key: "test-key",
      api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
    },
    # This venue's edit needs both size and price (`Rest.editable_present/1`), so the suite's
    # generic price-only edit is refused for a reason that has nothing to do with the id
    # assertion 31 is checking.
    order_args: %{order_changes: %{quantity: Decimal.new("0.002"), price: Decimal.new("1")}},
    # Conformance group 42: the REAL `Rest.place_order/3` (not the Fake) with the venue
    # answering 503 to every attempt, i.e. a fault after the send, retried fast. The contract's
    # base request is passed through unmapped. A request without `:order_type` is refused
    # before anything is sent.
    ambiguous_place_order: fn request ->
      DpExchange.Core.Config.put_override(
        :rate_limit_module,
        DpExchange.CoinbaseContractTest.ContractLimiter
      )

      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, ~s({"message":"unavailable"}))
      end

      DpExchange.Coinbase.Rest.place_order(
        %{api_key: "test-key", api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="},
        request,
        plug: plug,
        retry_attempts: 2,
        retry_delay: 1
      )
    end
end

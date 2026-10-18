defmodule DpExchange.Coinbase.WriteOnceTest do
  @moduledoc """
  A write the venue cannot tell from its own repeat is sent once.

  `Core.HttpClient` retries a 5xx or a transport error, and neither says whether the venue
  acted before it answered. For `move_funds` and a futures sweep a retry moves the money
  again. For a conversion commit or an order edit that already took effect it comes back
  refused, telling the caller a success failed. For a portfolio create it leaves a
  duplicate. See `Rest`'s `post_once/4`.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Rest
  alias DpExchange.Core.Config

  @moduletag :capture_log

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
    api_key: "organizations/x/apiKeys/y",
    api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
  }

  # Every request is answered 502 and counted. These calls do not read `:retry_delay`, so a
  # retrying build would wait Core's default 1_000 ms before its second send; the drain
  # window in `requests/1` outlasts that, so a retry would be counted and fail the suite.
  defp failing(test_pid) do
    fn conn ->
      send(test_pid, {:request, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(502, Jason.encode!(%{"error" => "bad gateway"}))
    end
  end

  defp opts(extra), do: [plug: failing(self())] ++ extra

  defp requests(acc \\ []) do
    receive do
      {:request, path} -> requests([path | acc])
    after
      2_500 -> Enum.reverse(acc)
    end
  end

  test "move_funds is sent once" do
    Rest.transfer_internal(@credentials, "USD", Decimal.new("1"), opts(from: "a", to: "b"))
    assert [_one] = requests()
  end

  test "a futures sweep is sent once" do
    Rest.schedule_futures_sweep(@credentials, opts(usd_amount: Decimal.new("5")))
    assert [_one] = requests()
  end

  test "a conversion commit is sent once" do
    Rest.commit_conversion(@credentials, "trade-1", opts(from: "a", to: "b"))
    assert [_one] = requests()
  end

  test "a portfolio create is sent once" do
    Rest.create_portfolio(@credentials, opts(name: "p"))
    assert [_one] = requests()
  end

  test "an order edit is sent once" do
    # `EditOrderRequest` requires both price and size — a lone `price` is refused locally,
    # before any request is made, so this needs both to reach `post_once/4` at all.
    Rest.replace_order(
      @credentials,
      "order-1",
      %{price: Decimal.new("10"), quantity: Decimal.new("1")},
      opts([])
    )

    assert [_one] = requests()
  end

  # A cancel or delete that took effect before a lost answer, retried, comes back "not there"
  # — a refusal for something this call did. Found 2026-10-10.
  test "an order cancel is sent once" do
    Rest.cancel_order(@credentials, "order-1", opts([]))
    assert [_one] = requests()
  end

  test "a portfolio delete is sent once" do
    Rest.delete_portfolio(@credentials, "pf-1", opts([]))
    assert [_one] = requests()
  end

  test "a futures sweep cancel is sent once" do
    Rest.cancel_futures_sweep(@credentials, opts([]))
    assert [_one] = requests()
  end

  # "Sent once" is a guarantee: the calls do not read the retry keys, so a caller passing
  # either (any value, 0 and 1 included) is refused before anything is sent, rather than
  # accepted and overwritten.
  describe "retry keys are refused on a sent-once call" do
    test "transfer_internal, any value" do
      pairs = [retry_attempts: 3, retry_attempts: 1, retry_attempts: 0, retry_delay: 1]

      for {key, value} <- pairs do
        assert {:error, {:unknown_option, ^key}} =
                 Rest.transfer_internal(
                   @credentials,
                   "USD",
                   Decimal.new("1"),
                   opts([{:from, "a"}, {:to, "b"}, {key, value}])
                 )
      end

      refute_receive {:request, _path}, 500
    end

    test "cancel_order and delete_portfolio" do
      assert {:error, {:unknown_option, :retry_attempts}} =
               Rest.cancel_order(@credentials, "order-1", opts(retry_attempts: 3))

      assert {:error, {:unknown_option, :retry_delay}} =
               Rest.delete_portfolio(@credentials, "pf-1", opts(retry_delay: 1))

      refute_receive {:request, _path}, 500
    end

    test "the other sent-once writes" do
      changes = %{price: Decimal.new("10"), quantity: Decimal.new("1")}

      assert {:error, {:unknown_option, :retry_attempts}} =
               Rest.replace_order(@credentials, "order-1", changes, opts(retry_attempts: 1))

      assert {:error, {:unknown_option, :retry_attempts}} =
               Rest.create_portfolio(@credentials, opts(name: "p", retry_attempts: 1))

      assert {:error, {:unknown_option, :retry_delay}} =
               Rest.commit_conversion(
                 @credentials,
                 "trade-1",
                 opts(from: "a", to: "b", retry_delay: 1)
               )

      assert {:error, {:unknown_option, :retry_attempts}} =
               Rest.schedule_futures_sweep(
                 @credentials,
                 opts(usd_amount: Decimal.new("5"), retry_attempts: 1)
               )

      assert {:error, {:unknown_option, :retry_attempts}} =
               Rest.cancel_futures_sweep(@credentials, opts(retry_attempts: 1))

      refute_receive {:request, _path}, 500
    end

    test "the shared key table (the Fake's too) refuses them, and keeps them for keyed writes" do
      assert {:error, {:unknown_option, :retry_attempts}} =
               DpExchange.Coinbase.OptionKeys.check(:cancel_order, retry_attempts: 1)

      assert :ok = DpExchange.Coinbase.OptionKeys.check(:place_order, retry_attempts: 1)
      assert :ok = DpExchange.Coinbase.OptionKeys.check(:place_order, retry_delay: 1)
    end
  end
end

defmodule DpExchange.Coinbase.NonOrderWritesTest do
  @moduledoc """
  The family's non-order write rules (W1) and the portfolio scope on the reads (W7), for the
  Advanced Trade writes that are not orders: futures sweeps, the intraday margin setting and
  the portfolio rename, and `portfolio:` on the list reads.

  A write whose request MAY have reached the venue and whose success is not proven is
  `{:error, {:write_unconfirmed, key_or_nil, reason}}`; a failure decided before anything was
  sent stays a plain error, and a venue `4xx` stays a refusal. A read option the read cannot
  honour is honoured or refused, never ignored.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Fake, Rest}
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

  # Refuses every request the way a full bucket does: nothing leaves the process.
  defmodule ThrottlingLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: {:error, :rate_limit_timeout}
    @impl true
    def check(_provider, _weight, _opts), do: {:rate_limited, 2_000}
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  # Lets the first request through and refuses every later one, per calling process.
  defmodule RefuseAfterFirstLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts) do
      if Process.get(:now_first_acquire_done, false) do
        {:error, :rate_limit_timeout}
      else
        Process.put(:now_first_acquire_done, true)
        :ok
      end
    end

    @impl true
    def check(_provider, _weight, _opts), do: {:rate_limited, 2_000}
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

  defp status(code, body \\ %{"message" => "nope"}) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(code, Jason.encode!(body))
    end
  end

  # Reports every request's query string, answers 200 with `body`.
  defp querying(body, test_pid) do
    fn conn ->
      send(test_pid, {:query, conn.request_path, URI.decode_query(conn.query_string)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  # Counts the requests it receives, always answering `code`.
  defp counted_status(code, test_pid) do
    fn conn ->
      send(test_pid, :attempt_sent)
      status(code).(conn)
    end
  end

  describe "futures sweeps" do
    test "a 5xx after the send is unconfirmed, with no key to carry" do
      assert {:error, {:write_unconfirmed, nil, {:exchange_error, :coinbase, text}}} =
               Rest.schedule_futures_sweep(@credentials,
                 usd_amount: Decimal.new("5"),
                 plug: status(503)
               )

      assert text =~ "503"

      assert {:error, {:write_unconfirmed, nil, {:exchange_error, :coinbase, _text}}} =
               Rest.cancel_futures_sweep(@credentials, plug: status(500))
    end

    test "a 2xx that is not an object is unconfirmed" do
      list = status(200, ["not", "an", "object"])

      assert {:error, {:write_unconfirmed, nil, :unexpected_response_shape}} =
               Rest.schedule_futures_sweep(@credentials, plug: list)

      assert {:error, {:write_unconfirmed, nil, :unexpected_response_shape}} =
               Rest.cancel_futures_sweep(@credentials, plug: list)
    end

    test "a venue 4xx is a refusal and success: false stays a refusal" do
      assert {:refused, _reason} =
               Rest.schedule_futures_sweep(@credentials, plug: status(403))

      assert {:refused, :sweep_not_scheduled} =
               Rest.schedule_futures_sweep(@credentials,
                 plug: status(200, %{"success" => false})
               )

      assert {:refused, :sweep_not_cancelled} =
               Rest.cancel_futures_sweep(@credentials,
                 plug: status(200, %{"success" => false})
               )
    end

    test "our own limiter refusing, and a refused amount, are decided before sending: plain" do
      Config.put_override(:rate_limit_module, ThrottlingLimiter)
      me = self()

      assert {:error, {:exchange_error, :coinbase, "Throttled by our own rate limiter" <> _r}} =
               Rest.schedule_futures_sweep(@credentials, plug: counted_status(200, me))

      assert {:error, {:exchange_error, :coinbase, "Throttled by our own rate limiter" <> _r}} =
               Rest.cancel_futures_sweep(@credentials, plug: counted_status(200, me))

      assert {:error, {:invalid_amount, 1.5}} =
               Rest.schedule_futures_sweep(@credentials,
                 usd_amount: 1.5,
                 plug: counted_status(200, me)
               )

      refute_received :attempt_sent
    end
  end

  describe "idempotent writes that keep their retries" do
    test "the intraday margin setting: a 5xx is unconfirmed, a refusal of a retry too" do
      setting = "INTRADAY_MARGIN_SETTING_STANDARD"

      assert {:error, {:write_unconfirmed, nil, {:exchange_error, :coinbase, _text}}} =
               Rest.set_intraday_margin_setting(@credentials, setting,
                 plug: status(500),
                 retry_attempts: 0
               )

      assert {:error, {:write_unconfirmed, nil, :unexpected_response_shape}} =
               Rest.set_intraday_margin_setting(@credentials, setting,
                 plug: status(200, [1]),
                 retry_attempts: 0
               )

      Config.put_override(:rate_limit_module, RefuseAfterFirstLimiter)
      me = self()

      assert {:error, {:write_unconfirmed, nil, {:exchange_error, :coinbase, text}}} =
               Rest.set_intraday_margin_setting(@credentials, setting,
                 plug: counted_status(503, me),
                 retry_attempts: 3,
                 retry_delay: 1
               )

      assert text =~ "Throttled by our own rate limiter"
      assert_receive :attempt_sent, 5_000
      refute_received :attempt_sent
    end

    test "the portfolio rename: the same rules, and a first-attempt limiter refusal is plain" do
      assert {:error, {:write_unconfirmed, nil, {:exchange_error, :coinbase, _text}}} =
               Rest.rename_portfolio(@credentials, "pf-1", "New",
                 plug: status(502),
                 retry_attempts: 0
               )

      Config.put_override(:rate_limit_module, RefuseAfterFirstLimiter)
      me = self()

      assert {:error, {:write_unconfirmed, nil, {:exchange_error, :coinbase, text}}} =
               Rest.rename_portfolio(@credentials, "pf-1", "New",
                 plug: counted_status(503, me),
                 retry_attempts: 3,
                 retry_delay: 1
               )

      assert text =~ "Throttled by our own rate limiter"
      assert_receive :attempt_sent, 5_000
      refute_received :attempt_sent

      Config.put_override(:rate_limit_module, ThrottlingLimiter)

      assert {:error, {:exchange_error, :coinbase, "Throttled by our own rate limiter" <> _r}} =
               Rest.rename_portfolio(@credentials, "pf-1", "New",
                 plug: counted_status(200, me),
                 retry_attempts: 3,
                 retry_delay: 1
               )

      refute_received :attempt_sent
    end
  end

  describe "opts[:portfolio] is honoured on the list reads (retail_portfolio_id)" do
    test "it reaches the venue as retail_portfolio_id on all four reads, on every page" do
      me = self()

      assert {:ok, []} =
               Rest.get_balances(@credentials,
                 portfolio: "pf-9",
                 plug: querying(%{"accounts" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:query, path, %{"retail_portfolio_id" => "pf-9"}}, 5_000
      assert String.ends_with?(path, "/accounts")

      assert {:ok, []} =
               Rest.get_accounts(@credentials,
                 portfolio: "pf-9",
                 plug: querying(%{"accounts" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:query, _path, %{"retail_portfolio_id" => "pf-9"}}, 5_000

      assert {:ok, []} =
               Rest.get_orders(@credentials,
                 portfolio: "pf-9",
                 plug: querying(%{"orders" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:query, orders_path, %{"retail_portfolio_id" => "pf-9"}}, 5_000
      assert String.ends_with?(orders_path, "/orders/historical/batch")

      assert {:ok, []} =
               Rest.get_trade_history(@credentials,
                 portfolio: "pf-9",
                 plug: querying(%{"fills" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:query, fills_path, %{"retail_portfolio_id" => "pf-9"}}, 5_000
      assert String.ends_with?(fills_path, "/orders/historical/fills")
    end

    test "without the option no retail_portfolio_id is sent" do
      me = self()

      assert {:ok, []} =
               Rest.get_balances(@credentials,
                 plug: querying(%{"accounts" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:query, _path, query}, 5_000
      refute Map.has_key?(query, "retail_portfolio_id")
    end

    test "a blank or non-string portfolio is refused before a request, by Rest and the Fake" do
      me = self()
      plug = querying(%{"accounts" => [], "orders" => [], "fills" => []}, me)

      for bad <- ["", "  ", :pf, 7, ["pf"]] do
        expected = {:error, {:invalid_option, :portfolio, bad}}
        real = [portfolio: bad, plug: plug, retry_attempts: 0]

        assert expected == Rest.get_balances(@credentials, real)
        assert expected == Rest.get_accounts(@credentials, real)
        assert expected == Rest.get_orders(@credentials, real)
        assert expected == Rest.get_trade_history(@credentials, real)

        assert expected == Fake.get_balances(@credentials, portfolio: bad)
        assert expected == Fake.get_accounts(@credentials, portfolio: bad)
        assert expected == Fake.get_orders(@credentials, portfolio: bad)
        assert expected == Fake.get_trade_history(@credentials, portfolio: bad)
      end

      refute_received {:query, _path, _query}
    end

    test "a single-account read cannot be scoped to a portfolio: refused, not ignored" do
      expected = {:error, {:unsupported_option, :portfolio}}

      assert expected ==
               Rest.get_accounts(@credentials, uuid: "acct-1", portfolio: "pf-9")

      assert expected ==
               Fake.get_accounts(@credentials,
                 uuid: "8bfc20d7-f7c6-4422-bf07-8243ca4169fe",
                 portfolio: "pf-9"
               )
    end

    test "the Fake scopes by it: another portfolio holds nothing, the default holds its data" do
      {:ok, [default | _rest]} = Fake.list_portfolios(credentials: @credentials)

      assert {:ok, [_btc, _usd]} = Fake.get_balances(@credentials, portfolio: default.id)
      assert {:ok, []} = Fake.get_balances(@credentials, portfolio: "not-the-default")

      assert {:ok, [_account]} = Fake.get_accounts(@credentials, portfolio: default.id)
      assert {:ok, []} = Fake.get_accounts(@credentials, portfolio: "not-the-default")

      assert {:ok, [_order]} = Fake.get_orders(@credentials, portfolio: default.id)
      assert {:ok, []} = Fake.get_orders(@credentials, portfolio: "not-the-default")

      assert {:ok, [_fill]} = Fake.get_trade_history(@credentials, portfolio: default.id)
      assert {:ok, []} = Fake.get_trade_history(@credentials, portfolio: "not-the-default")
    end

    test "the futures reads take no portfolio, in Rest and in the Fake" do
      expected = {:error, {:unsupported_option, :portfolio}}

      assert expected == Fake.get_positions(credentials: @credentials, portfolio: "pf-9")

      assert expected ==
               Rest.get_positions(@credentials,
                 portfolio: "pf-9",
                 plug: querying(%{"positions" => []}, self()),
                 retry_attempts: 0
               )

      refute_received {:query, _path, _query}
    end
  end
end

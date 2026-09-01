defmodule DpExchange.Coinbase.AccountsTest do
  @moduledoc """
  Balances and accounts.

  Two assertions carry most of the weight here. **The venue reports no total** — only
  `available_balance` and `hold` — so the total is their sum, and is `nil` when either is
  missing rather than the other one alone. And **the endpoint pages**, at 49 by default, so
  a caller reading one page holds some of its balances with nothing to say which are gone.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Rest
  alias DpExchange.Core.{Config, Types}

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
    api_secret: "-----BEGIN EC PRIVATE KEY-----"
  }

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp account(overrides \\ %{}) do
    Map.merge(
      %{
        "uuid" => "8bfc20d7-f7c6-4422-bf07-8243ca4169fe",
        "name" => "BTC Wallet",
        "currency" => "BTC",
        "available_balance" => %{"value" => "1.25", "currency" => "BTC"},
        "hold" => %{"value" => "0.25", "currency" => "BTC"},
        "active" => true,
        "ready" => true,
        "platform" => "ACCOUNT_PLATFORM_CONSUMER"
      },
      overrides
    )
  end

  describe "get_balances/2 — the total the venue does not send" do
    test "the total is available plus hold" do
      # Not a guess: 1.25 available with 0.25 held IS 1.5, and both numbers are the
      # venue's. This is arithmetic, not a substitution.
      body = %{"accounts" => [account()], "has_next" => false}

      assert {:ok, [balance]} =
               Rest.get_balances(@credentials, plug: responding(body), retry_attempts: 0)

      assert %Types.Balance{} = balance
      assert balance.currency == "BTC"
      assert Decimal.equal?(balance.balance, Decimal.new("1.50"))
      assert Decimal.equal?(balance.available_balance, Decimal.new("1.25"))
      assert Decimal.equal?(balance.hold, Decimal.new("0.25"))
      assert balance.provider == :coinbase
    end

    test "a missing hold leaves the total nil, not equal to available" do
      # "Available 1.25, total unknown" and "total equals available" are different claims,
      # and a consumer sizing against the second when the first is true trades against
      # money that is held.
      body = %{"accounts" => [account(%{"hold" => nil})], "has_next" => false}

      assert {:ok, [balance]} =
               Rest.get_balances(@credentials, plug: responding(body), retry_attempts: 0)

      assert balance.balance == nil
      assert Decimal.equal?(balance.available_balance, Decimal.new("1.25"))
    end

    test "a missing available leaves the total nil too" do
      body = %{"accounts" => [account(%{"available_balance" => nil})], "has_next" => false}

      assert {:ok, [balance]} =
               Rest.get_balances(@credentials, plug: responding(body), retry_attempts: 0)

      assert balance.balance == nil
      assert balance.available_balance == nil
    end

    test "the timestamp is when we asked, because a balance has no venue event time" do
      before = DateTime.utc_now()
      body = %{"accounts" => [account()], "has_next" => false}

      assert {:ok, [balance]} =
               Rest.get_balances(@credentials, plug: responding(body), retry_attempts: 0)

      assert DateTime.compare(balance.timestamp, before) != :lt
      assert DateTime.compare(balance.timestamp, DateTime.utc_now()) != :gt
    end

    test "an empty account list is an empty list, not an error" do
      assert {:ok, []} =
               Rest.get_balances(@credentials,
                 plug: responding(%{"accounts" => [], "has_next" => false}),
                 retry_attempts: 0
               )
    end

    test "a body with no accounts key is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_balances(@credentials, plug: responding(%{}), retry_attempts: 0)
    end
  end

  describe "pagination — a truncated balance list is the dangerous shape" do
    test "it follows the cursor until has_next is false" do
      # Every number on page one is real, which is exactly why stopping there is worse than
      # failing: nothing looks wrong and the missing balances are simply never seen.
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        body =
          if conn.query_string =~ "cursor=page2" do
            %{"accounts" => [account(%{"currency" => "ETH"})], "has_next" => false}
          else
            %{"accounts" => [account()], "has_next" => true, "cursor" => "page2"}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end

      assert {:ok, balances} =
               Rest.get_balances(@credentials, plug: plug, retry_attempts: 0)

      assert Enum.map(balances, & &1.currency) == ["BTC", "ETH"]
      assert_receive {:query, _first}
      assert_receive {:query, second}
      assert second =~ "cursor=page2"
    end

    test "has_next true with no cursor stops rather than repeating the same page" do
      body = %{"accounts" => [account()], "has_next" => true}

      assert {:ok, [_only]} =
               Rest.get_balances(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "a server that always says has_next is bounded, not an infinite loop" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{"accounts" => [account()], "has_next" => true, "cursor" => "always"})
        )
      end

      assert {:error, :too_many_account_pages} =
               Rest.get_balances(@credentials, plug: plug, retry_attempts: 0)
    end

    test "a limit is passed to the venue" do
      me = self()

      plug = fn conn ->
        send(me, {:query, conn.query_string})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"accounts" => [], "has_next" => false}))
      end

      assert {:ok, []} =
               Rest.get_balances(@credentials, limit: 250, plug: plug, retry_attempts: 0)

      assert_receive {:query, query}
      assert query =~ "limit=250"
    end
  end

  describe "get_accounts/2 — what a balance cannot say" do
    test "the venue's own record comes back whole" do
      # A caller routing an order needs the uuid and the platform; a caller sizing one needs
      # the balance. Collapsing the two would lose the first.
      body = %{"accounts" => [account()], "has_next" => false}

      assert {:ok, [record]} =
               Rest.get_accounts(@credentials, plug: responding(body), retry_attempts: 0)

      assert record["uuid"] == "8bfc20d7-f7c6-4422-bf07-8243ca4169fe"
      assert record["platform"] == "ACCOUNT_PLATFORM_CONSUMER"
      assert record["ready"] == true
    end

    test "a uuid reads the single-account endpoint" do
      me = self()

      plug = fn conn ->
        send(me, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"account" => account()}))
      end

      assert {:ok, [_record]} =
               Rest.get_accounts(@credentials, uuid: "abc", plug: plug, retry_attempts: 0)

      assert_receive {:path, path}
      assert path =~ "/accounts/abc"
    end

    test "a single-account body with no account key is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_accounts(@credentials,
                 uuid: "abc",
                 plug: responding(%{}),
                 retry_attempts: 0
               )
    end
  end
end

defmodule DpExchange.Coinbase.MoneySurfaceTest do
  @moduledoc """
  Payment methods and the internal move.

  Two things here are worth more than the rest. **A payment method's flags disagree with
  each other**: `verified` is not `allow_withdraw`, and a caller filtering on the first
  picks a method the venue refuses for the second. And **`move_funds` defaults nothing** —
  a move missing either portfolio uuid is refused before a request is made, because the
  alternative is shifting funds between portfolios the caller never named.
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

  defp capturing(body, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  describe "list_payment_methods/2" do
    test "returns the venue's own rows, flags and all" do
      body = %{
        "payment_methods" => [
          %{
            "id" => "pm-1",
            "verified" => true,
            "allow_deposit" => true,
            "allow_withdraw" => false
          }
        ]
      }

      assert {:ok, [method]} =
               Rest.list_payment_methods(@credentials, plug: responding(body), retry_attempts: 0)

      # The flags disagree, and both survive. Collapsing them into one "usable" boolean is
      # what would make a caller move fiat through a method the venue refuses.
      assert method["verified"] == true
      assert method["allow_withdraw"] == false
    end

    test "an empty set is an empty list, not an error" do
      assert {:ok, []} =
               Rest.list_payment_methods(@credentials,
                 plug: responding(%{"payment_methods" => []}),
                 retry_attempts: 0
               )
    end

    test "a body without the key is unreadable rather than empty" do
      # "The venue answered something else" and "this account has no methods" are different
      # answers, and only the second is worth acting on.
      assert {:error, :unexpected_response_shape} =
               Rest.list_payment_methods(@credentials, plug: responding(%{}), retry_attempts: 0)
    end
  end

  describe "get_payment_method/3" do
    test "reads one method by id" do
      body = %{"payment_method" => %{"id" => "pm-9", "verified" => false}}

      assert {:ok, method} =
               Rest.get_payment_method(@credentials, "pm-9",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert method["id"] == "pm-9"
      assert method["verified"] == false
    end

    test "the id goes in the path" do
      me = self()

      assert {:ok, _method} =
               Rest.get_payment_method(@credentials, "pm-9",
                 plug: capturing(%{"payment_method" => %{}}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, _body}
      assert String.ends_with?(path, "/payment_methods/pm-9")
    end

    test "a body without the key is unreadable, never an empty map" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_payment_method(@credentials, "pm-9",
                 plug: responding(%{}),
                 retry_attempts: 0
               )
    end
  end

  describe "transfer_internal/4 — nothing leaves the venue" do
    test "both uuids and the funds object reach the venue" do
      me = self()

      assert {:ok, _result} =
               Rest.transfer_internal(@credentials, "USD", Decimal.new("25.5"),
                 from: "src-uuid",
                 to: "dst-uuid",
                 plug: capturing(%{"source_portfolio_uuid" => "src-uuid"}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, raw}
      assert String.ends_with?(path, "/portfolios/move_funds")

      decoded = Jason.decode!(raw)
      assert decoded["source_portfolio_uuid"] == "src-uuid"
      assert decoded["target_portfolio_uuid"] == "dst-uuid"
      assert decoded["funds"] == %{"value" => "25.5", "currency" => "USD"}
    end

    test "a missing source is refused before a request is made" do
      # No plug at all: if this reached HTTP the test would fail on the connection rather
      # than the guard, which is the point.
      assert {:error, :missing_portfolio} =
               Rest.transfer_internal(@credentials, "USD", Decimal.new("1"), to: "dst-uuid")
    end

    test "a missing destination is refused too" do
      assert {:error, :missing_portfolio} =
               Rest.transfer_internal(@credentials, "USD", Decimal.new("1"), from: "src-uuid")
    end

    test "a small amount is sent in full notation, not scientific" do
      # `Decimal.to_string/1` would render this as 1E-8, which the venue does not read as a
      # number. The amount would be wrong by eight orders of magnitude or rejected outright.
      me = self()

      assert {:ok, _result} =
               Rest.transfer_internal(@credentials, "BTC", Decimal.new("0.00000001"),
                 from: "a",
                 to: "b",
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, raw}
      assert Jason.decode!(raw)["funds"]["value"] == "0.00000001"
    end
  end

  describe "the fake agrees with the package" do
    test "a listed method can be verified for deposit and not withdrawal" do
      assert {:ok, methods} = Fake.list_payment_methods(@credentials)
      assert Enum.any?(methods, &(&1["verified"] == true and &1["allow_withdraw"] == false))
    end

    test "one method reads back by id" do
      assert {:ok, method} = Fake.get_payment_method(@credentials, "pm-1")
      assert method["id"] == "pm-1"
    end

    test "the fake refuses a move with either end missing" do
      assert {:error, :missing_portfolio} =
               Fake.transfer_internal("USD", Decimal.new("1"), [to: "b"], [])

      assert {:error, :missing_portfolio} =
               Fake.transfer_internal("USD", Decimal.new("1"), [from: "a"], [])
    end

    test "the fake moves when both ends are named" do
      assert {:ok, result} =
               Fake.transfer_internal("USD", Decimal.new("1"), [from: "a", to: "b"], [])

      assert result["source_portfolio_uuid"] == "a"
      assert result["target_portfolio_uuid"] == "b"
    end

    test "the endpoints this venue does not publish refuse in the fake too" do
      assert {:error, :not_supported} = Fake.add_payment_method(%{})
      assert {:error, :not_supported} = Fake.get_transactions(@credentials)
      assert {:error, :not_supported} = Fake.list_custody_fees(@credentials)
      assert {:error, :not_supported} = Fake.get_notional_balances(@credentials, "usd")
      assert {:error, :not_supported} = Fake.list_networks("BTC")
      assert {:error, :not_supported} = Fake.list_fee_promos()
      assert {:error, :not_supported} = Fake.get_fx_rate("AUDUSD", ~U[2026-09-01 00:00:00Z])
      assert {:error, :not_supported} = Fake.remove_approved_address("bitcoin", "addr")

      assert {:error, :not_supported} =
               Fake.request_approved_address("BTC", "bitcoin", "addr")
    end
  end

  describe "the facade reaches the venue" do
    test "list_payment_methods/2 delegates" do
      body = %{"payment_methods" => [%{"id" => "pm-1"}]}

      assert {:ok, [_method]} =
               DpExchange.Coinbase.list_payment_methods(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )
    end

    test "get_payment_method/3 delegates" do
      body = %{"payment_method" => %{"id" => "pm-1"}}

      assert {:ok, method} =
               DpExchange.Coinbase.get_payment_method(@credentials, "pm-1",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert method["id"] == "pm-1"
    end

    test "transfer_internal/4 threads credentials out of the request options" do
      # The callback takes no credentials argument; the facade is what finds them. Wired
      # wrong this compiles and then signs with an empty map.
      me = self()

      assert {:ok, _result} =
               DpExchange.Coinbase.transfer_internal(
                 "USD",
                 Decimal.new("1"),
                 [from: "a", to: "b"],
                 credentials: @credentials,
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, _raw}
      assert String.ends_with?(path, "/portfolios/move_funds")
    end
  end

  describe "the venue saying no" do
    defp failing(status) do
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(status, Jason.encode!(%{"error" => "nope"}))
      end
    end

    test "a 404 on a payment method is a refusal, not an error" do
      # The account asked about a method the venue does not hold. Retrying cannot help,
      # which is what separates a refusal from an error here.
      assert {:refused, :not_listed} =
               Rest.get_payment_method(@credentials, "pm-gone",
                 plug: failing(404),
                 retry_attempts: 0
               )
    end

    test "a 500 on the listing is an error, because retrying can help" do
      assert {:error, _reason} =
               Rest.list_payment_methods(@credentials, plug: failing(500), retry_attempts: 0)
    end

    test "a 500 on a move is an error and moves nothing" do
      assert {:error, _reason} =
               Rest.transfer_internal(@credentials, "USD", Decimal.new("1"),
                 from: "a",
                 to: "b",
                 plug: failing(500),
                 retry_attempts: 0
               )
    end

    test "a move answering with something other than a map is unreadable" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(["not", "a", "map"]))
      end

      assert {:error, :unexpected_response_shape} =
               Rest.transfer_internal(@credentials, "USD", Decimal.new("1"),
                 from: "a",
                 to: "b",
                 plug: plug,
                 retry_attempts: 0
               )
    end
  end
end

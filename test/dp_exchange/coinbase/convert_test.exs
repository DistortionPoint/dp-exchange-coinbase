defmodule DpExchange.Coinbase.ConvertTest do
  @moduledoc """
  Convert — the facade's only two-step operation on this venue.

  **The gap between quote and commit is the risk**, and Advanced Trade makes it worse by
  stating no expiry at all: `expires_at` is `nil`, which means "not stated" and not
  "open-ended". A caller committing a lapsed quote can be filled at the *current* rate rather
  than refused, which is the dangerous outcome because the operation looks like it succeeded
  and every number in it is real.

  The second thing this file guards is that **both accounts are re-asked on every step** —
  commit and even the read — and this package fills neither in. A conversion committed
  against accounts the caller did not name happens between the wrong two balances.
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

  defp capturing(body, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_string, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp trade(overrides \\ %{}) do
    %{
      "trade" =>
        Map.merge(
          %{
            "id" => "t-1",
            "status" => "TRADE_STATUS_CREATED",
            "user_entered_amount" => %{"value" => "100", "currency" => "USD"},
            "total" => %{"value" => "99.9", "currency" => "USDC"},
            "fees" => %{"value" => "0.1", "currency" => "USD"}
          },
          overrides
        )
    }
  end

  describe "quote_conversion/5 — nothing moves" do
    test "a quote comes back quoted, with the caller's own asset pair" do
      # The response's amounts carry a currency each, but which is source and which is
      # destination is the caller's question and the response does not label them.
      assert {:ok, conversion} =
               Rest.quote_conversion(@credentials, "USD", "USDC", Decimal.new("100"),
                 plug: responding(trade()),
                 retry_attempts: 0
               )

      assert %Types.Conversion{} = conversion
      assert conversion.status == :quoted
      assert conversion.from_asset == "USD"
      assert conversion.to_asset == "USDC"
      assert Decimal.equal?(conversion.from_amount, Decimal.new("100"))
      assert Decimal.equal?(conversion.to_amount, Decimal.new("99.9"))
    end

    test "expires_at is nil, and nil is not open-ended" do
      assert {:ok, conversion} =
               Rest.quote_conversion(@credentials, "USD", "USDC", Decimal.new("1"),
                 plug: responding(trade()),
                 retry_attempts: 0
               )

      assert conversion.expires_at == nil
    end

    test "the accounts are currencies, and the amount is full notation" do
      me = self()

      assert {:ok, _conversion} =
               Rest.quote_conversion(@credentials, "USD", "USDC", Decimal.new("0.00000001"),
                 plug: capturing(trade(), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, _query, raw}
      assert String.ends_with?(path, "/convert/quote")
      body = Jason.decode!(raw)
      assert body["from_account"] == "USD"
      assert body["to_account"] == "USDC"
      assert body["amount"] == "0.00000001"
      refute Map.has_key?(body, "trade_incentive_metadata")
    end

    test "an incentive is passed through only when the caller has one" do
      me = self()

      assert {:ok, _conversion} =
               Rest.quote_conversion(@credentials, "USD", "USDC", Decimal.new("1"),
                 trade_incentive_metadata: %{"user_incentive_id" => "i-1"},
                 plug: capturing(trade(), me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw}
      assert Jason.decode!(raw)["trade_incentive_metadata"] == %{"user_incentive_id" => "i-1"}
    end
  end

  describe "the status vocabulary" do
    for {venue, expected} <- [
          {"TRADE_STATUS_CREATED", :quoted},
          {"TRADE_STATUS_STARTED", :committed},
          {"TRADE_STATUS_COMPLETED", :settled},
          {"TRADE_STATUS_CANCELED", :expired},
          {"TRADE_STATUS_EXPIRED", :expired},
          {"TRADE_STATUS_FAILED", :failed}
        ] do
      test "#{venue} maps to #{expected}" do
        body = trade(%{"status" => unquote(venue)})

        assert {:ok, conversion} =
                 Rest.quote_conversion(@credentials, "USD", "USDC", Decimal.new("1"),
                   plug: responding(body),
                   retry_attempts: 0
                 )

        assert conversion.status == unquote(expected)
      end
    end

    test "a status this package does not know is nil, never the nearest one" do
      # Reporting a quote as settled is the failure this field exists to prevent, and
      # reporting a failure as a quote is the same mistake backwards.
      body = trade(%{"status" => "TRADE_STATUS_SOMETHING_NEW"})

      assert {:ok, conversion} =
               Rest.quote_conversion(@credentials, "USD", "USDC", Decimal.new("1"),
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert conversion.status == nil
    end
  end

  describe "commit and read both re-ask for the accounts" do
    test "a commit without both accounts is refused before a request is made" do
      assert {:error, :from_and_to_required} =
               Rest.commit_conversion(@credentials, "t-1", from: "USD")

      assert {:error, :from_and_to_required} = Rest.commit_conversion(@credentials, "t-1", [])
    end

    test "a commit sends both accounts in the body and the id in the path" do
      me = self()

      assert {:ok, conversion} =
               Rest.commit_conversion(@credentials, "t-1",
                 from: "USD",
                 to: "USDC",
                 plug: capturing(trade(%{"status" => "TRADE_STATUS_STARTED"}), me),
                 retry_attempts: 0
               )

      assert conversion.status == :committed
      assert_receive {:request, "POST", path, _query, raw}
      assert String.ends_with?(path, "/convert/trade/t-1")
      assert Jason.decode!(raw) == %{"from_account" => "USD", "to_account" => "USDC"}
    end

    test "a read without both accounts is refused, unusual as that is for a read" do
      assert {:error, :from_and_to_required} =
               Rest.get_conversion(@credentials, "t-1", to: "USDC")
    end

    test "a read sends both accounts as query parameters" do
      me = self()

      assert {:ok, conversion} =
               Rest.get_conversion(@credentials, "t-1",
                 from: "USD",
                 to: "USDC",
                 plug: capturing(trade(%{"status" => "TRADE_STATUS_COMPLETED"}), me),
                 retry_attempts: 0
               )

      assert conversion.status == :settled
      assert_receive {:request, "GET", path, query, _raw}
      assert String.ends_with?(path, "/convert/trade/t-1")
      assert query =~ "from_account=USD"
      assert query =~ "to_account=USDC"
    end
  end

  describe "the venue answering something else" do
    test "a body without a trade key is unreadable on each of the three" do
      opts = [plug: responding(%{}), retry_attempts: 0]

      assert {:error, :unexpected_response_shape} =
               Rest.quote_conversion(@credentials, "USD", "USDC", Decimal.new("1"), opts)

      assert {:error, :unexpected_response_shape} =
               Rest.commit_conversion(@credentials, "t-1", [from: "USD", to: "USDC"] ++ opts)

      assert {:error, :unexpected_response_shape} =
               Rest.get_conversion(@credentials, "t-1", [from: "USD", to: "USDC"] ++ opts)
    end

    test "a 500 is an error" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "nope"}))
      end

      assert {:error, _reason} =
               Rest.quote_conversion(@credentials, "USD", "USDC", Decimal.new("1"),
                 plug: plug,
                 retry_attempts: 0
               )
    end
  end

  describe "the fake and the facade" do
    test "the fake quotes without an expiry and refuses a commit missing an account" do
      alias DpExchange.Coinbase.Fake

      assert {:ok, %{status: :quoted, expires_at: nil}} =
               Fake.quote_conversion("USD", "USDC", Decimal.new("1"))

      assert {:error, :from_and_to_required} = Fake.commit_conversion("t-1")
      assert {:error, :from_and_to_required} = Fake.get_conversion("t-1")

      assert {:ok, %{status: :committed}} =
               Fake.commit_conversion("t-1", from: "USD", to: "USDC")

      assert {:ok, %{status: :settled}} = Fake.get_conversion("t-1", from: "USD", to: "USDC")
    end

    test "the facade delegates all three" do
      base = [credentials: @credentials, retry_attempts: 0]

      assert {:ok, _quote} =
               DpExchange.Coinbase.quote_conversion(
                 "USD",
                 "USDC",
                 Decimal.new("1"),
                 base ++ [plug: responding(trade())]
               )

      assert {:ok, _commit} =
               DpExchange.Coinbase.commit_conversion(
                 "t-1",
                 base ++ [from: "USD", to: "USDC", plug: responding(trade())]
               )

      assert {:ok, _read} =
               DpExchange.Coinbase.get_conversion(
                 "t-1",
                 base ++ [from: "USD", to: "USDC", plug: responding(trade())]
               )
    end
  end
end

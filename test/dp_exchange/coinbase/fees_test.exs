defmodule DpExchange.Coinbase.FeesTest do
  @moduledoc """
  The transaction summary — one endpoint answering two different questions.

  **This package claimed until 2026-09-01 that Advanced Trade does not aggregate the
  account's own volume.** It does, on the same endpoint that carries the fee schedule. The
  claim had been made from the *market* volume endpoint's absence, which is a different
  question: `get_market_overview/1` asks what everyone traded.

  The other thing worth asserting is that **two fee tiers travel**. `fee_tier` is what
  applies now and `fee_tier_without_promotion` is what would apply without a promotion; they
  differ while one is running, and it can end between two calls.
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

  defp summary(overrides \\ %{}) do
    Map.merge(
      %{
        "total_fees" => 25,
        "fee_tier" => %{"taker_fee_rate" => "0.0010", "maker_fee_rate" => "0.0020"},
        "fee_tier_without_promotion" => %{
          "current_tier" => %{"taker_fee_rate" => "0.0060"}
        },
        "goods_and_services_tax" => %{"rate" => "0.1", "type" => "INCLUSIVE"},
        "advanced_trade_only_volume" => 1000,
        "coinbase_pro_volume" => 250,
        "volume_breakdown" => [
          %{"volume_type" => "VOLUME_TYPE_SPOT", "volume" => 1000},
          %{"volume_type" => "VOLUME_TYPE_US_DERIVATIVES", "volume" => 500}
        ]
      },
      overrides
    )
  end

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp capturing(body, test_pid) do
    fn conn ->
      send(test_pid, {:query, conn.query_string})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  describe "get_fees/2" do
    test "both tiers travel, because a promotion can end between two calls" do
      assert {:ok, fees} =
               Rest.get_fees(@credentials, plug: responding(summary()), retry_attempts: 0)

      assert fees["fee_tier"]["taker_fee_rate"] == "0.0010"
      assert fees["fee_tier_without_promotion"]["current_tier"]["taker_fee_rate"] == "0.0060"
      refute fees["fee_tier"] == fees["fee_tier_without_promotion"]
    end

    test "the tax's inclusivity survives, because it changes the amount" do
      assert {:ok, fees} =
               Rest.get_fees(@credentials, plug: responding(summary()), retry_attempts: 0)

      assert fees["goods_and_services_tax"]["type"] == "INCLUSIVE"
    end

    test "no product filter is sent unless the caller asked for one" do
      me = self()

      assert {:ok, _fees} =
               Rest.get_fees(@credentials, plug: capturing(summary(), me), retry_attempts: 0)

      assert_receive {:query, query}
      assert query == ""

      assert {:ok, _fees} =
               Rest.get_fees(@credentials,
                 product_type: "FUTURE",
                 contract_expiry_type: "EXPIRING",
                 product_venue: "FCM",
                 plug: capturing(summary(), me),
                 retry_attempts: 0
               )

      assert_receive {:query, query2}
      assert query2 =~ "product_type=FUTURE"
      assert query2 =~ "contract_expiry_type=EXPIRING"
      assert query2 =~ "product_venue=FCM"
    end

    test "a body without a fee tier is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_fees(@credentials, plug: responding(%{}), retry_attempts: 0)
    end
  end

  describe "get_trade_volume/2 — the claim that was wrong" do
    test "the venue's own breakdown comes back, one row per volume type" do
      assert {:ok, rows} =
               Rest.get_trade_volume(@credentials, plug: responding(summary()), retry_attempts: 0)

      assert length(rows) == 2

      assert Enum.map(rows, & &1["volume_type"]) |> Enum.sort() ==
               ["VOLUME_TYPE_SPOT", "VOLUME_TYPE_US_DERIVATIVES"]
    end

    test "the two account totals ride alongside rather than being folded in" do
      # Advanced Trade volume is documented as non-inclusive of Pro, so adding them is right
      # and adding either to the breakdown double counts.
      assert {:ok, [row | _rest]} =
               Rest.get_trade_volume(@credentials, plug: responding(summary()), retry_attempts: 0)

      assert row["volume"] == 1000
      assert row["advanced_trade_only_volume"] == 1000
      assert row["coinbase_pro_volume"] == 250
      refute row["volume"] == row["advanced_trade_only_volume"] + row["coinbase_pro_volume"]
    end

    test "an empty breakdown is an account that traded nothing, not a venue that cannot say" do
      body = summary(%{"volume_breakdown" => []})

      assert {:ok, []} =
               Rest.get_trade_volume(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "a body with no breakdown key is an empty list, not a crash" do
      body = Map.delete(summary(), "volume_breakdown")

      assert {:ok, []} =
               Rest.get_trade_volume(@credentials, plug: responding(body), retry_attempts: 0)
    end

    test "a 500 is an error on both readers" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "nope"}))
      end

      assert {:error, _reason} = Rest.get_fees(@credentials, plug: plug, retry_attempts: 0)

      assert {:error, _reason} =
               Rest.get_trade_volume(@credentials, plug: plug, retry_attempts: 0)
    end
  end

  describe "the fake and the facade" do
    test "the fake's two tiers differ, as the venue's do under a promotion" do
      assert {:ok, fees} = Fake.get_fees(%{}, [])
      assert fees["fee_tier"]["taker_fee_rate"] != "0.0060"
      assert fees["fee_tier_without_promotion"]["current_tier"]["taker_fee_rate"] == "0.0060"
    end

    test "the fake's volume row carries the totals beside the breakdown" do
      assert {:ok, [row]} = Fake.get_trade_volume(%{})
      assert row["volume"] == 1000
      assert row["coinbase_pro_volume"] == 250
    end

    test "the facade delegates both" do
      base = [plug: responding(summary()), retry_attempts: 0]

      assert {:ok, _fees} = DpExchange.Coinbase.get_fees(@credentials, base)
      assert {:ok, [_row | _rest]} = DpExchange.Coinbase.get_trade_volume(@credentials, base)
    end
  end
end

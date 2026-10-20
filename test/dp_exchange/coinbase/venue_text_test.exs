defmodule DpExchange.Coinbase.VenueTextTest do
  @moduledoc """
  A value the venue sent is bounded, marked with its full size and copied out of the document
  before it is quoted into an error tuple. Decided against a plug; nothing leaves the process.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Rest, VenueText}
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

  # A megabyte, far past any bound.
  @huge String.duplicate("é", 500_000)

  defp answering(body) do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end

    [plug: plug, retry_attempts: 0]
  end

  describe "bound/1" do
    test "keeps a short text as it is" do
      assert VenueText.bound("NaN") == "NaN"
    end

    test "cuts a long text at a stated size and marks the full size" do
      bounded = VenueText.bound(@huge)

      assert byte_size(bounded) < 1_200
      assert String.valid?(bounded)
      assert String.ends_with?(bounded, "… (#{byte_size(@huge)} bytes)")
    end

    test "copies a text out of the document it was cut from" do
      document = String.duplicate("x", 100_000)
      # Over 64 bytes: a shorter slice is copied by the runtime itself on OTP 27+.
      <<head::binary-size(100), _rest::binary>> = document

      assert :binary.referenced_byte_size(head) == 100_000
      assert :binary.referenced_byte_size(VenueText.bound(head)) == 100
    end

    test "keeps a small term and replaces a large one with a bounded, marked rendering" do
      small = [%{"code" => "E1"}]
      assert VenueText.bound(small) == small
      assert VenueText.bound(:atom) == :atom
      assert VenueText.bound(nil) == nil

      large = [%{"detail" => @huge}]
      bounded = VenueText.bound(large)

      assert is_binary(bounded)
      assert byte_size(bounded) < 1_200
      assert bounded =~ ~r/\(\d+ bytes\)\z/
    end
  end

  describe "an echo from the venue in an error" do
    test "{:preview_rejected, errs} is bounded" do
      request = %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        price: Decimal.new("40000"),
        order_type: :limit,
        time_in_force: :gtc
      }

      body = %{"errs" => [%{"message" => @huge}]}

      assert {:refused, {:preview_rejected, errs}} =
               Rest.preview_order(@credentials, request, answering(body))

      assert is_binary(errs)
      assert byte_size(errs) < 1_200
    end

    test "{:invalid_decimal, field, value} is bounded" do
      body = %{"trades" => [%{"time" => "2026-08-28T12:00:00Z", "price" => @huge}]}

      assert {:error, {:invalid_decimal, :price, value}} =
               Rest.get_price("BTC-USD", answering(body))

      assert byte_size(value) < 1_200
      assert String.ends_with?(value, "… (#{byte_size(@huge)} bytes)")
    end

    test "a short echo is unchanged" do
      body = %{"trades" => [%{"time" => "2026-08-28T12:00:00Z", "price" => "abc"}]}

      assert {:error, {:invalid_decimal, :price, "abc"}} =
               Rest.get_price("BTC-USD", answering(body))
    end
  end
end

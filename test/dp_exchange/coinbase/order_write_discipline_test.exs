defmodule DpExchange.Coinbase.OrderWriteDisciplineTest do
  @moduledoc """
  Core conformance group 50 for this venue: a replace that changes nothing, or whose changes
  are not a map, is `{:error, {:invalid_order_request, value}}`, and `preview_order/3` answers
  a malformed request with the tuple `place_order/3` answers for it. Real path and Fake alike.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Fake, Rest}
  alias DpExchange.Core.AdapterContract

  @moduletag :capture_log

  @credentials %{
    api_key: "organizations/x/apiKeys/y",
    api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
  }

  defp never_sent do
    [plug: fn _conn -> raise "a refused call must not reach the venue" end, retry_attempts: 0]
  end

  @base %{
    symbol: "BTC-USD",
    side: :buy,
    order_type: :limit,
    time_in_force: :gtc,
    quantity: "1",
    price: "100"
  }

  test "replace_order and preview_replace answer the family tag for an empty or non-map change" do
    for bad <- [%{}, nil, "price", [price: "1"]] do
      expected = {:error, {:invalid_order_request, bad}}

      assert expected == Rest.replace_order(@credentials, "abc", bad, never_sent())
      assert expected == Rest.preview_replace(@credentials, "abc", bad, never_sent())
      assert expected == Fake.replace_order(@credentials, "abc", bad, [])
      assert expected == Fake.preview_replace(@credentials, "abc", bad, [])
    end
  end

  test "the first unread key of a change is the unsupported order field, on both paths" do
    unread = [%{side: :sell}, %{side: :sell, price: "x"}, %{price: "1", time_in_force: :ioc}]

    for changes <- unread do
      key = changes |> Map.keys() |> Enum.find(&(&1 not in [:price, :quantity]))
      expected = {:error, {:unsupported_order_field, key}}

      assert expected == Rest.replace_order(@credentials, "abc", changes, never_sent())
      assert expected == Rest.preview_replace(@credentials, "abc", changes, never_sent())
      assert expected == Fake.replace_order(@credentials, "abc", changes, [])
      assert expected == Fake.preview_replace(@credentials, "abc", changes, [])
    end
  end

  test "the fake edits one field and keeps the order's own other one" do
    assert {:ok, order} =
             Fake.replace_order(@credentials, "fake-order-1", %{price: Decimal.new("41000")}, [])

    assert Decimal.equal?(order.price, Decimal.new("41000"))
    assert Decimal.equal?(order.quantity, Decimal.new("0.5"))

    assert {:refused, :not_found} =
             Fake.replace_order(@credentials, "never-issued", %{price: "1"}, [])
  end

  test "preview_order answers what place_order answers for each malformed request" do
    for {request, reason} <- AdapterContract.order_request_cases(@base) do
      placed = Rest.place_order(@credentials, request, never_sent())
      assert {:error, ^reason} = placed

      assert placed == Rest.preview_order(@credentials, request, never_sent())
      assert placed == Fake.place_order(@credentials, request, [])
      assert placed == Fake.preview_order(@credentials, request, [])
    end
  end
end

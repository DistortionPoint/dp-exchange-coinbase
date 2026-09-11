defmodule DpExchange.Coinbase.NaNGuardTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Socket
  alias DpExchange.Core.Types

  # `Decimal.parse/1` requiring the whole string be consumed is not a sufficient guard on its
  # own: "NaN", "Inf" and "-Inf" all parse fully and case-insensitively, so each arrived as a
  # well-formed `Decimal` and flowed onward as a real price.
  #
  # That is worse than a raise, and it fails a long way from the cause. `Decimal.add(nan, 1)`
  # is NaN, so it poisons a consumer's arithmetic silently; `Decimal.compare(nan, _)` RAISES
  # `invalid_operation: operation on NaN`, in the consumer's own process, naming Decimal
  # rather than the venue that sent it. An Infinity is quieter still — it compares greater
  # than everything and never raises.
  #
  # `dp_exchange_webull` found this and guarded both of its copies. This package guarded
  # neither of its two.

  # Lowercase and mixed forms included deliberately: `Decimal.parse/1` is case-insensitive
  # here, so a guard matching only the canonical spelling would let `"inf"` straight through.
  @poison ["NaN", "nan", "-NaN", "Inf", "inf", "-Inf", "Infinity", "-Infinity"]

  defp state, do: %{subscriber: self(), credentials: nil, delivering: MapSet.new()}

  defp ticker(price) do
    %{
      "channel" => "ticker",
      "timestamp" => "2026-08-28T14:53:45.649112Z",
      "events" => [
        %{
          "tickers" => [%{"product_id" => "BTC-USD", "price" => price, "volume_24_h" => "1234.5"}]
        }
      ]
    }
  end

  defp frame(payload), do: Socket.handle_frame({:text, Jason.encode!(payload)}, state())

  describe "a NaN or Infinity from the venue is dropped, never admitted as a number" do
    for value <- @poison do
      test "#{value} as a ticker price does not reach a subscriber as a Quote" do
        assert {:ok, _state} = frame(ticker(unquote(value)))

        refute_receive {:dp_exchange, :coinbase, %Types.Quote{}}, 50
      end
    end

    test "a real price still arrives, so the guard has not eaten the happy path" do
      assert {:ok, _state} = frame(ticker("79478.7"))

      assert_receive {:dp_exchange, :coinbase, %Types.Quote{} = quote_struct}
      assert Decimal.equal?(quote_struct.price, Decimal.new("79478.7"))
    end

    test "what a NaN would have done downstream, stated rather than assumed" do
      # The reason this guard exists rather than a comment saying "should not happen".
      {nan, ""} = Decimal.parse("NaN")

      assert Decimal.nan?(nan)
      # Silently poisons arithmetic...
      assert nan |> Decimal.add(Decimal.new(1)) |> Decimal.nan?()
      # ...and raises on the comparison a consumer is most likely to reach for.
      assert_raise Decimal.Error, fn -> Decimal.compare(nan, Decimal.new(1)) end
    end
  end
end

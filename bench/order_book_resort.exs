# Benchmark backing dp_exchange_core's
# docs/design/2026-09-06_order-book-resort-cost.md.
#
# Run: mix run bench/order_book_resort.exs
#
# `DpExchange.Coinbase.Socket.deliver_book/3` used to rebuild BOTH sides of the
# maintained book with `Enum.sort_by/3` on EVERY `l2_data` frame, including an
# `update` that changes a single price level. This measures that cost against the
# `:gb_trees` replacement, at the book size DpCryptoManagement reported live for
# BTC-USD (issue #22): ~22,800 bid levels, ~21,100 ask levels.
#
# Both approaches are exercised here directly (map + `Enum.sort_by/3` vs `:gb_trees`
# traversal) rather than through `Socket.handle_frame/2`, because the pre-fix
# behaviour no longer exists in `lib/` to call — `Bench.OldApproach` below is a
# deliberately-kept COPY of it, frozen for comparison, and is not production code.
# What each approach does with one frame is otherwise identical: patch the changed
# row into the maintained structure, then produce the ordered `{price, qty}` list
# `deliver_book/3` sends a consumer.

defmodule Bench.OldApproach do
  @moduledoc """
  The map-keyed-by-`Decimal`, full-`Enum.sort_by/3` approach
  `DpExchange.Coinbase.Socket.deliver_book/3` used before the design linked above.
  Kept ONLY as a benchmark comparison oracle — never reintroduce this in `lib/`.
  """

  @spec sorted_levels(%{Decimal.t() => Decimal.t()}, :asc | :desc) :: [
          {Decimal.t(), Decimal.t()}
        ]
  def sorted_levels(levels, :desc),
    do: Enum.sort_by(levels, fn {price, _qty} -> price end, {:desc, Decimal})

  def sorted_levels(levels, :asc),
    do: Enum.sort_by(levels, fn {price, _qty} -> price end, {:asc, Decimal})
end

defmodule Bench.Builder do
  @moduledoc false

  # `price_key/1` in `lib/dp_exchange/coinbase/socket.ex` — duplicated here rather
  # than exposed from the module, since that function is deliberately private.
  @price_scale_factor 100_000_000

  def levels_map(n, base_cents) do
    for i <- 1..n, into: %{} do
      price = Decimal.new(base_cents - i) |> Decimal.mult(Decimal.new("0.01"))
      qty = Decimal.new(i) |> Decimal.mult(Decimal.new("0.001"))
      {price, qty}
    end
  end

  def gb_tree(levels) do
    Enum.reduce(levels, :gb_trees.empty(), fn {price, qty}, tree ->
      key = price |> Decimal.mult(@price_scale_factor) |> Decimal.to_integer()
      :gb_trees.enter(key, {price, qty}, tree)
    end)
  end

  def key(price), do: price |> Decimal.mult(@price_scale_factor) |> Decimal.to_integer()
end

bid_count = 22_800
ask_count = 21_100

bids_map = Bench.Builder.levels_map(bid_count, 10_000_000)
asks_map = Bench.Builder.levels_map(ask_count, 10_500_000)
bids_tree = Bench.Builder.gb_tree(bids_map)
asks_tree = Bench.Builder.gb_tree(asks_map)

changed_price = Decimal.new("9999.99")
changed_qty = Decimal.new("5.0")

# --- isolated cost: bids only, one side's worth of the per-frame work -------------

{old_bids_us, _} = :timer.tc(fn -> Bench.OldApproach.sorted_levels(bids_map, :desc) end)

{new_bids_us, _} = :timer.tc(fn -> :gb_trees.to_list(bids_tree) |> Enum.reverse() end)

# --- one full update frame: patch one row into the maintained state, then deliver -

{old_frame_us, _} =
  :timer.tc(fn ->
    patched = Map.put(bids_map, changed_price, changed_qty)
    Bench.OldApproach.sorted_levels(patched, :desc)
    Bench.OldApproach.sorted_levels(asks_map, :asc)
  end)

{new_frame_us, _} =
  :timer.tc(fn ->
    key = Bench.Builder.key(changed_price)
    patched = :gb_trees.enter(key, {changed_price, changed_qty}, bids_tree)
    :gb_trees.to_list(patched) |> Enum.reverse()
    :gb_trees.to_list(asks_tree)
  end)

ms = fn us -> Float.round(us / 1000, 1) end
speedup = fn old, new -> Float.round(old / new, 1) end
per_sec = fn frame_us -> Float.round(1_000_000 / frame_us, 1) end

IO.puts("""
Book size: #{bid_count} bid levels, #{ask_count} ask levels — the live figures
DpCryptoManagement reported for BTC-USD (issue #22).

bids only, current full Enum.sort_by/Decimal : #{ms.(old_bids_us)} ms
bids only, ordered gb_trees traversal        : #{ms.(new_bids_us)} ms
speedup                                      : #{speedup.(old_bids_us, new_bids_us)}x

one update frame, full re-sort of both sides : #{ms.(old_frame_us)} ms  (#{per_sec.(old_frame_us)} updates/sec max)
one update frame, gb_trees patch + traverse  : #{ms.(new_frame_us)} ms  (#{per_sec.(new_frame_us)} updates/sec max)
speedup                                      : #{speedup.(old_frame_us, new_frame_us)}x
""")

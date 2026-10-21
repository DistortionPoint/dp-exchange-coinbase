defmodule DpExchange.Coinbase.VenueNumber do
  @moduledoc """
  The one bound on a number this package accepts from a venue or from a caller. Internal.

  A string such as `"1e999999999"` parses fully and is finite, but comparing, adding or
  rendering it builds a `10 ** 999_999_999` integer (about 415 MB) inside the caller's or the
  socket's process. A string of a million digits is the same hazard on the other axis: it
  parses to one huge coefficient that every later `Decimal` operation walks. No price, size,
  balance or increment this venue quotes needs more than 34 significant digits (the width of
  an IEEE decimal128) or more than 64 places either side of the point (the finest increment in
  the committed specs is `1e-8`), so anything wider is refused as unreadable rather than
  admitted as a number. The bounds are this package's judgement, not a venue measurement.

  Three modules parsed venue numbers with their own copy of the exponent half of this rule
  (`Rest`, `Socket`, `Prime`) and none had the digit half. They share this one definition now,
  so the two halves cannot drift apart again.
  """

  # Places either side of the point.
  @max_exponent 64

  # Significant digits.
  @max_digits 34
  @coefficient_limit Integer.pow(10, @max_digits)

  @doc """
  Whether `number` is finite, has at most 34 significant digits and an exponent within 64 of
  zero. NaN and the infinities are not bounded numbers.
  """
  @spec bounded?(Decimal.t()) :: boolean()
  def bounded?(%Decimal{coef: coef, exp: exp}) when is_integer(coef),
    do: exp <= @max_exponent and exp >= -@max_exponent and coef < @coefficient_limit

  def bounded?(%Decimal{}), do: false
end

defmodule DpExchange.Coinbase.IdempotencyKey do
  @moduledoc """
  A v4 UUID for the two fields this venue dedupes retried writes on. Internal.

  Coinbase names the same idea twice, on two different APIs, and this package has to send
  both: **`client_order_id`** on Advanced Trade orders, and **`idempotency_key`** on Prime
  staking. Either one, resent, returns the original result instead of performing the action
  a second time — which is the whole reason `Core.HttpClient` is allowed to retry a write at
  all.

  ## Why it is generated here rather than left to the caller

  A key the caller may omit is a key that is usually absent, and a write with no key is a
  write `HttpClient` will happily send three times. `DpExchange.Coinbase.Rest.place_order/3`
  already generated one; `DpExchange.Coinbase.Prime`'s staking calls sent the field **only
  when the caller passed one** and retried three times when they had not.

  ## One generator, not two

  The order path had this function; the staking path needed it. Five identical private
  `fan_out/2` functions across five packages are recorded in `Core.Fanout`'s moduledoc as
  the shape that lets a fix land in one copy and not the others, and two copies inside one
  package is the same shape smaller. A colliding id would silently return someone else's
  order, so there is exactly one implementation to get right.

  Built from the VM's own CSPRNG rather than a dependency — sixteen bytes is not worth one.
  """

  import Bitwise

  @doc "A random v4 UUID, as a lowercase hyphenated string."
  @spec generate() :: String.t()
  def generate do
    <<a::32, b::16, _version::4, c::12, _variant::2, d::62>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-4~3.16.0b-a~3.16.0b-~12.16.0b", [
      a,
      b,
      c,
      bsr(d, 50),
      band(d, 0xFFFFFFFFFFFF)
    ])
    |> IO.iodata_to_binary()
  end
end

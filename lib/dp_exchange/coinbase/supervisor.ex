defmodule DpExchange.Coinbase.Supervisor do
  @moduledoc """
  This venue's process tree — internal. A consumer starts `DpExchange.Coinbase` and gets
  this; it never names or reaches into the children.

  ## The venue starts its own rate limiter, and that is the point

  Rate limiting is venue-internal under the facade contract, and this is what that means
  in practice: **the ceilings `capabilities/0` declares are the ceilings the limiter is
  configured with.** The declaration is not decoration that happens to sit beside the
  mechanism — it *is* the mechanism's configuration, so the two cannot drift apart.

  ## The ceiling follows whether this instance was given credentials

  `capabilities/0` declares two ceilings and says outright that credentials buy the
  higher one: *"Pass credentials and this package uses the authenticated path, which has
  the higher ceiling; pass none and it uses the public one."* That is a claim about
  `Rest`'s request paths, and the limiter has to agree with it — a limiter fixed at
  `public_ceiling` regardless of `opts[:credentials]` would throttle a credentialed
  consumer's authenticated calls to a third of what the venue actually allows them,
  while the moduledoc kept promising the higher number. `limits/1` reads the same
  `opts` this supervisor was started with (the same map `Feed` reads `:credentials`
  out of) and configures the bucket from `authenticated_ceiling` when one was given,
  `public_ceiling` otherwise — so the mechanism agrees with the declaration for
  whichever path this instance is actually going to take, not only for the
  unauthenticated one.

  It also fixes a real usability trap. `Core.HttpClient` fails closed when no limiter is
  running, which is correct — an unmetered package is how a venue answers with HTTP 429
  while a budget panel reads comfortable. But it means a venue package that expected
  someone else to start a limiter answers `{:error, "Rate limiter unavailable"}` to every
  call, and the error does not say what is missing. Measured while writing this package's
  tier-2 tests, which is exactly the tier that catches integration gaps a fake cannot.

  A consumer may still supply its own limiter through `Core.Config`'s
  `:rate_limit_module`, per process — this is a working default, not a lock.

  ## What is deliberately not here

  No aggregate supervisor over multiple venues, and no auto-start. A consumer puts
  `DpExchange.Coinbase` in its own tree and chooses restart strategy, shutdown order and
  naming. A consumer that has not asked for this venue never finds a socket open.
  """

  use Supervisor

  alias DpExchange.Coinbase.Feed
  alias DpExchange.Core.DefaultRateLimiter

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    # Both children take their names from `opts`, so a consumer running two of this venue
    # — two credentials, two scopes — keeps them apart. Hardcoding either name means the
    # second instance collides with the first, which is a failure at start rather than in
    # production but is still a failure a consumer should not have to discover.
    children = [
      {DefaultRateLimiter, name: limiter_name(opts), limits: limits(opts)},
      {Feed, Keyword.put(opts, :name, feed_name(opts))}
    ]

    # `:one_for_one` — the feed losing its socket is not a reason to reset the rate
    # limiter, and resetting it would hand back budget the venue has already been spent.
    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc "The limiter this venue meters against, for `Core.HttpClient`'s `:limiter` option."
  @spec limiter_name(keyword()) :: atom()
  def limiter_name(opts), do: Keyword.get(opts, :limiter, DpExchange.Coinbase.RateLimiter)

  @doc "This venue's feed process."
  @spec feed_name(keyword()) :: atom()
  def feed_name(opts), do: Keyword.get(opts, :feed, Feed)

  # Straight from the declaration. If a ceiling changes, it changes in one place.
  #
  # `opts[:credentials]` decides which of the two declared ceilings applies — see the
  # moduledoc's "The ceiling follows whether this instance was given credentials"
  # section. An empty map is treated the same as none: `Rest`'s own request paths key
  # off `Keyword.get(opts, :credentials)` being truthy, and `%{}` is truthy but carries
  # no actual credential, so a caller passing one through by accident must not silently
  # buy a higher ceiling than it can use.
  defp limits(opts) do
    caps = DpExchange.Coinbase.capabilities()
    ceiling = if authenticated?(opts), do: caps.authenticated_ceiling, else: caps.public_ceiling

    %{
      coinbase: to_limit(ceiling),
      default: to_limit(ceiling)
    }
  end

  defp authenticated?(opts) do
    case Keyword.get(opts, :credentials) do
      %{} = credentials -> map_size(credentials) > 0
      _absent -> false
    end
  end

  # Burst equal to the per-second allowance: the venue's published limit is a rate, and a
  # one-second bucket is the smallest burst that does not turn a legitimate batch into a
  # queue.
  defp to_limit(%{limit: limit, per_ms: per_ms}),
    do: %{limit: limit, per_ms: per_ms, burst: limit}
end

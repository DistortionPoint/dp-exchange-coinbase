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
  someone else to start a limiter answers `{:error, {:exchange_error, :coinbase,
  "Rate limiter unavailable"}}` to every call, and the error does not say what is missing. Measured while writing this package's
  tier-2 tests, which is exactly the tier that catches integration gaps a fake cannot.

  A consumer may still supply its own limiter through `Core.Config`'s
  `:rate_limit_module`, per process — this is a working default, not a lock.

  ## Children, and what a restart keeps

  A `FeedLedger`, the rate limiter and the `Feed`, started in that order under
  `:rest_for_one`. The ledger holds what consumers asked the feed for (symbols and
  subscribers), so a feed that crashes is restarted with that intent and tells each
  subscriber so with a `:coverage_change` notice (`details.reason: :feed_restarted`).

  Their names are `opts[:feed]`, `opts[:limiter]` and `opts[:ledger]`, else derived from a
  non-default atom `opts[:name]` (`Module.concat(name, Feed)`, `RateLimiter`, `FeedLedger`),
  else the defaults: two trees started with only distinct names do not collide.

  ## What is deliberately not here

  No aggregate supervisor over multiple venues, and no auto-start. A consumer puts
  `DpExchange.Coinbase` in its own tree and chooses restart strategy, shutdown order and
  naming. A consumer that has not asked for this venue never finds a socket open.
  """

  use Supervisor

  alias DpExchange.Coinbase.{Credentials, Feed, FeedLedger}
  alias DpExchange.Core.{Config, DefaultRateLimiter}

  @doc """
  Starts the venue supervisor, registered under `opts[:name]` (default
  `DpExchange.Coinbase.Supervisor`), with a rate limiter and a feed as children.

  A raw `:credentials` map is wrapped (see `DpExchange.Coinbase.Credentials`) before the
  supervisor stores it, so a caller that starts this module directly rather than through
  `DpExchange.Coinbase.child_spec/1` still does not leave the key pair in this supervisor's
  state, or in the `Start Call:` line of its `Feed` child, which OTP prints on a crash.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    opts = Credentials.wrap_opt(opts)
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    # Idempotent after `start_link/1`; it covers an `init/1` reached any other way, because
    # the `Feed` child spec below is stored by this supervisor with `opts` in its start call.
    opts = Credentials.wrap_opt(opts)

    # Both children take their names from `opts`, so a consumer running two of this venue
    # — two credentials, two scopes — keeps them apart. Hardcoding either name means the
    # second instance collides with the first, which is a failure at start rather than in
    # production but is still a failure a consumer should not have to discover.
    #
    # The feed is handed the limiter's and the ledger's names explicitly: its own `:name` is
    # the feed's, and names derived from that would be the wrong ones.
    feed_opts =
      opts
      |> Keyword.put(:name, feed_name(opts))
      |> Keyword.put(:limiter, limiter_name(opts))
      |> Keyword.put(:ledger, ledger_name(opts))

    children = [
      {FeedLedger, name: ledger_name(opts)},
      {DefaultRateLimiter, name: limiter_name(opts), limits: limits(opts)},
      {Feed, feed_opts}
    ]

    # `:rest_for_one`, in that order. The ledger holds what consumers asked the feed for, so
    # it starts first and a crash of the feed restarts only the feed, which reads the ledger
    # back and subscribes again. A crash of the limiter restarts the feed behind it (the feed
    # restores itself the same way), never the ledger before it; a crash of the ledger
    # restarts both, and the feed then starts from nothing rather than from a stale picture.
    # The rate limiter is not reset by a feed that lost its socket, and resetting it would hand
    # back budget the venue has already been spent.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc """
  The limiter this venue meters against, for `Core.HttpClient`'s `:limiter` option.

  `opts[:limiter]` when given; else `Module.concat(name, RateLimiter)` when the tree is
  started with a non-default atom `opts[:name]`; else `DpExchange.Coinbase.RateLimiter`.
  """
  @spec limiter_name(keyword()) :: atom()
  def limiter_name(opts),
    do: Config.opt(opts, :limiter, derived(opts, "RateLimiter", default_limiter()))

  @doc """
  This venue's feed process: `opts[:feed]`, else `Module.concat(name, Feed)` for a
  non-default atom `opts[:name]`, else `DpExchange.Coinbase.Feed`.
  """
  @spec feed_name(keyword()) :: GenServer.server()
  def feed_name(opts), do: Config.opt(opts, :feed, derived(opts, "Feed", Feed))

  @doc """
  This venue's ledger of what the feed was asked for: `opts[:ledger]`, else
  `Module.concat(name, FeedLedger)` for a non-default atom `opts[:name]`, else
  `DpExchange.Coinbase.FeedLedger`.
  """
  @spec ledger_name(keyword()) :: atom()
  def ledger_name(opts), do: Config.opt(opts, :ledger, derived(opts, "FeedLedger", FeedLedger))

  defp default_limiter, do: DpExchange.Coinbase.RateLimiter

  # Atoms that name no tree: absent, and the two names the default tree already has.
  @default_names [nil, true, false, __MODULE__, DpExchange.Coinbase]

  # Two trees in one VM started with only distinct names must not collide on the feed, the
  # limiter or the ledger. The default tree (no name, or the module's own) keeps the names
  # it always had, and an explicit option wins over a derived name. Only an atom derives:
  # `{:global, _}`, `{:via, ...}` and the portfolio name `create_account/1` reads from `:name`
  # (a string) do not.
  defp derived(opts, suffix, default) do
    case Config.opt(opts, :name, nil) do
      name when is_atom(name) and name not in @default_names ->
        Module.concat(name, suffix)

      _default_or_not_an_atom ->
        default
    end
  end

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
    # The same test `Auth.jwt/2` applies before signing. A wrapped `%{}`, a map with a typo'd
    # key, or a blank or padded value cannot sign, so it must not buy the higher ceiling.
    DpExchange.Coinbase.Auth.check_credentials(Keyword.get(opts, :credentials)) == :ok
  end

  # Burst equal to the per-second allowance: the venue's published limit is a rate, and a
  # one-second bucket is the smallest burst that does not turn a legitimate batch into a
  # queue.
  defp to_limit(%{limit: limit, per_ms: per_ms}),
    do: %{limit: limit, per_ms: per_ms, burst: limit}
end

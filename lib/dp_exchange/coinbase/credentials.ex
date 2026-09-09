defmodule DpExchange.Coinbase.Credentials do
  @moduledoc """
  Wraps the CDP `api_key`/`api_secret` pair so it can sit in a `GenServer`'s state
  without printing in full the moment that process crashes.

  ## The incident this closes

  `Feed` and `Socket` both hold `:credentials` for their entire lifetime — `Feed` to
  keep re-signing subscribes across reconnects and resubscribe sweeps, `Socket` to sign
  the JWT for every authenticated `subscribe/4`. Neither is optional: both need the raw
  secret to keep working. But OTP's default crash report prints a `GenServer`'s state in
  full, and a **plain map** field prints every key including the secret ones — verified
  against a real crash of an equivalent process holding `%{api_key: "...", api_secret:
  "..."}` as a bare state field: the log line came back with both values in cleartext.

  A `Process.flag(:sensitive, true)` was tried too, on the theory that it suppresses
  state in crash reports. It does not — the same crash, with the flag set, printed the
  same cleartext state. It disables tracing (`:sys.get_state/1`, `:dbg`), which is a
  different guarantee and not this one.

  What DOES work, verified the same way: a struct whose `Inspect` implementation is
  derived with `except:` naming every secret field. `Kernel.inspect/1` — which is what
  both the crash-report formatter AND a `FunctionClauseError`'s printed argument list
  go through — honours a struct's `Inspect` protocol even when the struct is nested
  inside an otherwise-plain state map, or is itself the argument a failed function
  clause is being reported against. Wrapping the credential pair in this struct, once,
  at the point it enters a long-lived process, and letting the struct itself (never an
  unwrapped copy) flow into every downstream call closes both leaks:

    * a crash of `Feed` or `Socket` prints `credentials: #DpExchange.Coinbase.Credentials<...>`
      rather than the key pair;
    * `DpExchange.Coinbase.Auth.jwt/2` and every function that only forwards this value
      opaquely (`Socket.subscribe/4`, the resubscribe/reconcile `handle_info` messages
      that carry it, `default_alias_map_source/2`) keep working unchanged, because a
      struct is a map — `%{api_key: k, api_secret: s} = credentials` still binds `k` and
      `s` to the real values inside `Auth.jwt/2`, which is the one place they need to be
      raw, and that binding is never itself stored or logged.

  ## Why `nil` stays `nil`

  `Feed.init/1`'s `active_channels/1` and `Socket`'s `subscription_message/3` both branch
  on "no credentials were supplied" by matching literal `nil` — Coinbase's credential-less
  callers pass no `:credentials` option at all, and `Keyword.get/2` answers `nil` rather
  than `%{}`. `wrap/1` preserves that: only a map gets struct-ified, so the "authenticated
  channels are unreachable" branch still fires exactly when it always did.
  """

  @derive {Inspect, except: [:api_key, :api_secret]}
  defstruct [:api_key, :api_secret]

  @type t :: %__MODULE__{api_key: String.t() | nil, api_secret: String.t() | nil}

  @doc """
  Wraps a raw credentials map for storage in process state.

  `nil` passes through unchanged — see the moduledoc's "Why `nil` stays `nil`". Any other
  map is struct-ified with `Kernel.struct/2`, which — like this, deliberately — ignores
  keys the struct does not declare rather than raising, matching how every existing
  consumer of this map already reads it: `Auth.jwt/2` pattern-matches only `:api_key` and
  `:api_secret` and has never cared what else the map carried.
  """
  @spec wrap(map() | nil) :: t() | nil
  def wrap(nil), do: nil
  def wrap(%__MODULE__{} = credentials), do: credentials
  def wrap(credentials) when is_map(credentials), do: struct(__MODULE__, credentials)

  @doc """
  Wraps the `:credentials` entry of an options keyword list, IN PLACE and only when that
  key is actually present.

  This is what keeps a raw secret out of a **supervisor's stored child spec**, and it has
  to be applied in `child_spec/1` — nowhere later is early enough. A supervisor holds the
  `{module, :start_link, [opts]}` MFA it was handed, and OTP writes that argument list
  through `inspect/1` into the `Start Call:` line of the report it logs whenever the child
  terminates. Wrapping inside `start_link/1` or `init/1` does nothing for it: by then the
  raw list has already been captured by the supervisor above.

  dp-exchange-core issue #29 — a consumer found live API keys in cleartext in ordinary
  application logs, produced by any child crash at all, and nearly pasted them into a
  GitHub issue while reporting a different bug.
  """
  @spec wrap_opt(keyword()) :: keyword()
  def wrap_opt(opts) do
    case Keyword.fetch(opts, :credentials) do
      {:ok, credentials} when is_map(credentials) ->
        Keyword.put(opts, :credentials, wrap(credentials))

      _absent_or_not_a_map ->
        opts
    end
  end
end

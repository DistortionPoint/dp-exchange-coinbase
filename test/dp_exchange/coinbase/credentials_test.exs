defmodule DpExchange.Coinbase.CredentialsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias DpExchange.Coinbase.Credentials

  @api_key "LEAK_PROOF_API_KEY_abc123"
  @api_secret "LEAK_PROOF_API_SECRET_xyz789"

  describe "wrap/1" do
    test "nil passes through unchanged — the credential-less case `active_channels/1` and " <>
           "`subscription_message/3` both match on" do
      assert Credentials.wrap(nil) == nil
    end

    test "a plain credentials map is struct-ified" do
      wrapped = Credentials.wrap(%{api_key: @api_key, api_secret: @api_secret})

      assert %Credentials{api_key: @api_key, api_secret: @api_secret} = wrapped
    end

    test "already-wrapped credentials pass through unchanged" do
      wrapped = Credentials.wrap(%{api_key: @api_key, api_secret: @api_secret})

      assert Credentials.wrap(wrapped) == wrapped
    end

    test "an unrelated extra key is ignored, matching every existing reader of this map " <>
           "(Auth.jwt/2 pattern-matches only :api_key and :api_secret)" do
      wrapped = Credentials.wrap(%{api_key: @api_key, api_secret: @api_secret, extra: "x"})

      assert wrapped.api_key == @api_key
      assert wrapped.api_secret == @api_secret
    end
  end

  describe "Inspect redaction" do
    test "neither secret field appears in the struct's own inspected output" do
      wrapped = Credentials.wrap(%{api_key: @api_key, api_secret: @api_secret})
      rendered = inspect(wrapped)

      refute rendered =~ @api_key
      refute rendered =~ @api_secret
      assert rendered =~ "DpExchange.Coinbase.Credentials<...>"
    end

    test "the secret stays redacted even nested inside an ordinary map — the exact shape " <>
           "a GenServer's state takes" do
      state = %{credentials: Credentials.wrap(%{api_key: @api_key, api_secret: @api_secret})}
      rendered = inspect(state)

      refute rendered =~ @api_key
      refute rendered =~ @api_secret
    end
  end

  describe "crash-report proof" do
    # This mirrors, deliberately, the exact state-construction idiom `Feed.init/1`
    # (feed.ex) and `Socket.start_link/1` (socket.ex) use: `credentials` wrapped via
    # `Credentials.wrap/1` and stored as a top-level field of a GenServer's state. What
    # this proves is the MECHANISM those two call sites rely on — that wrapping survives
    # OTP's own crash-report formatter — rather than re-deriving it from a full `Feed`
    # crash, which has no externally-triggerable failure (both `handle_call/3` and
    # `handle_info/2` end in a catch-all clause that cannot be reached from outside).
    #
    # Before this fix, the equivalent state shape (`%{credentials: %{api_key: ...,
    # api_secret: ...}}` with a PLAIN map, not `Credentials.wrap/1`'s struct) printed the
    # secret in full in this exact scenario — verified in the audit that produced this
    # test. `async: false`: a `CaptureLog`-content assertion under `async: true` was
    # already found non-concurrency-safe once in this family.
    defmodule LeakyProbe do
      use GenServer

      @spec start_link(map()) :: GenServer.on_start()
      def start_link(credentials), do: GenServer.start_link(__MODULE__, credentials)

      @spec init(map()) :: {:ok, map()}
      def init(credentials) do
        {:ok, %{credentials: DpExchange.Coinbase.Credentials.wrap(credentials), symbols: []}}
      end

      @spec boom(pid()) :: any()
      def boom(pid), do: GenServer.call(pid, :boom)

      @spec handle_call(:boom, GenServer.from(), map()) :: no_return()
      def handle_call(:boom, _from, _state), do: raise("simulated crash for leak-proof test")
    end

    test "a crash of a process holding wrapped credentials never prints the secret" do
      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          {:ok, pid} = LeakyProbe.start_link(%{api_key: @api_key, api_secret: @api_secret})
          ref = Process.monitor(pid)

          try do
            LeakyProbe.boom(pid)
          catch
            :exit, _reason -> :ok
          end

          # Waits for the actual process death (a real message, no sleep) rather than
          # assuming the crash report was already flushed the instant `boom/1` returned.
          assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
        end)

      assert log =~ "simulated crash for leak-proof test"
      refute log =~ @api_key
      refute log =~ @api_secret
      assert log =~ "DpExchange.Coinbase.Credentials<...>"
    end
  end
end

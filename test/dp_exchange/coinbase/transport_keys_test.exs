defmodule DpExchange.Coinbase.TransportKeysTest do
  @moduledoc """
  A shared transport key is accepted only where the call reads it (tick AK).

    * a call that sends no request takes its own keys and `:credentials`, nothing else;
    * `:environment` and `:base_url` are read by no call and are refused on all of them;
    * every other shared key reaches `Core.HttpClient`: `:weight` reaches the limiter and
      `:max_body_bytes` bounds the body.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase
  alias DpExchange.Coinbase.{Fake, OptionKeys}
  alias DpExchange.Core.{Config, Options}

  @moduletag :capture_log

  @credentials %{
    api_key: "organizations/x/apiKeys/y",
    api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
  }

  defmodule WeightLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    # The limiter is asked in the calling process, so the test process sees the weight.
    @impl true
    def acquire(_provider, weight, _opts) do
      send(self(), {:acquired, weight})
      :ok
    end

    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  @time_body %{"iso" => "2026-10-18T00:00:00Z", "epochSeconds" => "1"}

  defp time_plug(test_pid) do
    fn conn ->
      send(test_pid, {:sent, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(@time_body))
    end
  end

  defp no_request_calls do
    [
      subscribe: fn m, o -> m.subscribe(["BTC-USD"], [to: self()] ++ o) end,
      subscribe_notices: fn m, o -> m.subscribe_notices([to: self()] ++ o) end,
      unsubscribe: fn m, o -> m.unsubscribe(["BTC-USD"], o) end,
      update_symbols: fn m, o -> m.update_symbols(["BTC-USD"], o) end,
      market_status: fn m, o -> m.market_status(o) end
    ]
  end

  defp raising_calls do
    [
      coverage: fn m, o -> m.coverage(o) end,
      wanted: fn m, o -> m.wanted(o) end,
      coverage_by_kind: fn m, o -> m.coverage_by_kind(o) end
    ]
  end

  describe "the table" do
    test "a no-request call allows its own keys and :credentials, no other transport key" do
      for function <- Keyword.keys(no_request_calls()) ++ Keyword.keys(raising_calls()) do
        allowed = OptionKeys.allowed(function)

        assert :credentials in allowed

        assert Options.transport_options() -- allowed ==
                 Options.transport_options() -- [:credentials],
               "#{function} allows a transport key it never reads"
      end
    end

    test "a request call allows every shared key but :environment and :base_url" do
      allowed = OptionKeys.allowed(:get_server_time)

      assert Options.transport_options() -- allowed == [:environment, :base_url]
    end

    test "a sent-once call additionally refuses the retry keys it never reads" do
      sent_once = [:cancel_order, :replace_order, :transfer_internal, :cancel_futures_sweep]

      for function <- sent_once do
        allowed = OptionKeys.allowed(function)

        refused = Enum.sort(Options.transport_options() -- allowed)

        assert refused == Enum.sort([:environment, :base_url, :retry_attempts, :retry_delay]),
               "#{function} should not allow the retry keys"
      end

      keyed = OptionKeys.allowed(:place_order)
      assert :retry_attempts in keyed
      assert :retry_delay in keyed
    end
  end

  for module <- [Coinbase, Fake] do
    describe "#{inspect(module)}: a no-request call" do
      test "refuses a transport key it cannot read, such as timeout: 5_000" do
        module = unquote(module)

        for {name, call} <- no_request_calls(), key <- [:timeout, :plug, :weight, :environment] do
          assert call.(module, [{key, 5_000}]) == {:error, {:unknown_option, key}},
                 "#{name} given #{key}: 5_000 did not answer unknown_option"
        end
      end

      test "the plain-value reads raise on a transport key" do
        module = unquote(module)

        for {name, call} <- raising_calls() do
          assert_raise ArgumentError, ~r/#{name}/, fn -> call.(module, timeout: 5_000) end
        end
      end

      test "still takes :credentials, which changes no answer" do
        module = unquote(module)

        assert module.market_status(credentials: @credentials) == {:ok, :open}
      end
    end

    describe "#{inspect(module)}: a request call" do
      test "refuses :environment and :base_url, and sends nothing" do
        module = unquote(module)
        plug = time_plug(self())

        assert module.get_server_time(plug: plug, environment: :sandbox) ==
                 {:error, {:unknown_option, :environment}}

        assert module.get_server_time(plug: plug, base_url: "http://localhost:1") ==
                 {:error, {:unknown_option, :base_url}}

        assert module.get_orders(@credentials, plug: plug, environment: :production) ==
                 {:error, {:unknown_option, :environment}}

        refute_receive {:sent, _path}, 500
      end
    end
  end

  describe "a forwarded key reaches Core.HttpClient" do
    test "weight: 7 is the weight the limiter is asked for" do
      Config.put_override(:rate_limit_module, WeightLimiter)

      assert {:ok, %{"iso" => _iso}} =
               Coinbase.get_server_time(plug: time_plug(self()), weight: 7, retry_attempts: 0)

      assert_receive {:acquired, 7}, 5_000
    end

    test "max_body_bytes: refuses a body larger than the cap, and the default does not" do
      Config.put_override(:rate_limit_module, WeightLimiter)
      plug = time_plug(self())

      assert {:error, {:exchange_error, :coinbase, {:response_too_large, 10}}} =
               Coinbase.get_server_time(plug: plug, max_body_bytes: 10, retry_attempts: 0)

      assert {:ok, %{"iso" => _iso}} = Coinbase.get_server_time(plug: plug, retry_attempts: 0)
    end
  end
end

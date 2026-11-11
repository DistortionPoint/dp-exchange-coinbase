defmodule DpExchange.Coinbase.DeclaredOptionsTest do
  # DistortionPoint/dp-exchange-core#43: the facade and the fake declare the option keys they
  # accept, so a consumer can `Keyword.take/2` instead of guessing. No test here makes a
  # network call: every one reads a declaration.
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase
  alias DpExchange.Coinbase.{Fake, OptionKeys}
  alias DpExchange.Core.{Capabilities, Venue}

  @probe :dp_contract_unknown_option

  # Facade functions that take no options at all.
  @no_options [
    :provider_name,
    :runtime_id,
    :asset_classes,
    :capabilities,
    :quantization,
    :venue_does_not_serve,
    :start_options,
    :call_options
  ]

  @start_functions [:child_spec, :start_link]

  setup_all do
    Code.ensure_loaded!(Coinbase)
    Code.ensure_loaded!(Fake)
    :ok
  end

  defp function_names(module) do
    module.__info__(:functions) |> Keyword.keys() |> Enum.uniq()
  end

  defp nil_opts(keys), do: Enum.map(keys, &{&1, nil})

  defp unique_atoms?(keys) do
    is_list(keys) and Enum.all?(keys, &is_atom/1) and keys == Enum.uniq(keys)
  end

  # The Venue callbacks `module` defines that the venue declares unsupported.
  defp inactive_callbacks(module) do
    declaration = Coinbase.capabilities()

    for {name, arity} <- Venue.behaviour_info(:callbacks),
        function_exported?(module, name, arity),
        not Capabilities.active?(declaration, {name, arity}),
        uniq: true,
        do: name
  end

  describe "start_options/0" do
    test "is the list the start-time check refuses against" do
      keys = Coinbase.start_options()

      assert unique_atoms?(keys)
      assert keys == OptionKeys.start_keys()
      assert OptionKeys.check_start(nil_opts(keys)) == :ok
    end

    test "every key it lists is accepted at start, one at a time" do
      for key <- Coinbase.start_options() do
        assert OptionKeys.check_start([{key, nil}]) == :ok, "#{inspect(key)} refused at start"
      end
    end

    test "the probe key is refused and is not listed" do
      refute @probe in Coinbase.start_options()
      assert OptionKeys.check_start([{@probe, nil}]) == {:error, {:unknown_option, @probe}}
    end

    test "what it says about :subscriber and :priority_symbols is what the check says" do
      # Coinbase reads neither at start: it refuses both, and does not list them.
      for key <- [:subscriber, :priority_symbols] do
        refute key in Coinbase.start_options()
        assert OptionKeys.check_start([{key, nil}]) == {:error, {:unknown_option, key}}

        listed? = key in Coinbase.start_options()
        accepted? = OptionKeys.check_start([{key, nil}]) == :ok
        assert listed? == accepted?
      end
    end

    test "the fake lists the facade's keys" do
      assert Fake.start_options() == Coinbase.start_options()
    end
  end

  describe "call_options/1 on the facade" do
    test "every public function answers {:ok, keys} or {:error, :not_supported}" do
      inactive = inactive_callbacks(Coinbase)

      for name <- function_names(Coinbase) do
        answer = Coinbase.call_options(name)

        if name in inactive do
          assert answer == {:error, :not_supported}, "#{name}: #{inspect(answer)}"
        else
          assert {:ok, keys} = answer, "#{name}: #{inspect(answer)}"
          assert unique_atoms?(keys), "#{name} declares #{inspect(keys)}"
        end
      end
    end

    test "every active endpoint's keys pass the check that call site uses" do
      inactive = inactive_callbacks(Coinbase)

      for name <- function_names(Coinbase), name not in inactive do
        {:ok, keys} = Coinbase.call_options(name)
        assert_accepted(name, keys)
      end
    end

    test "a request call's keys are exactly the keys it allows" do
      inactive = inactive_callbacks(Coinbase)
      plain = function_names(Coinbase) -- (@no_options ++ @start_functions ++ inactive)

      for name <- plain do
        {:ok, keys} = Coinbase.call_options(name)

        assert Enum.sort(keys) == Enum.sort(Enum.uniq(OptionKeys.allowed(name))),
               "#{name} declares #{inspect(keys)}"
      end
    end

    test "a function that takes no options answers an empty list" do
      for name <- @no_options do
        assert Coinbase.call_options(name) == {:ok, []}, "#{name}"
      end
    end

    test "child_spec and start_link answer the start options" do
      for name <- @start_functions do
        assert Coinbase.call_options(name) == {:ok, Coinbase.start_options()}
      end
    end

    test "an endpoint the venue does not serve is :not_supported whatever the options" do
      for name <- [:get_funding, :convert, :place_orders, :get_staking_rates, :withdraw] do
        assert Coinbase.call_options(name) == {:error, :not_supported}, "#{name}"
      end
    end

    test "keys the package cannot honour are never declared" do
      for name <- function_names(Coinbase), {:ok, keys} <- [Coinbase.call_options(name)] do
        refute :environment in keys, "#{name} declares :environment"
        refute :base_url in keys, "#{name} declares :base_url"
      end
    end

    test "a call sent exactly once declares no retry keys; a read keeps them" do
      {:ok, once} = Coinbase.call_options(:cancel_order)
      {:ok, read} = Coinbase.call_options(:get_order)
      {:ok, keyed_write} = Coinbase.call_options(:place_order)

      refute :retry_attempts in once
      refute :retry_delay in once
      assert :retry_attempts in read
      assert :retry_attempts in keyed_write
    end

    test "a call that sends no request declares its own keys and :credentials, no transport" do
      {:ok, keys} = Coinbase.call_options(:coverage)

      assert :feed in keys
      assert :credentials in keys
      refute :timeout in keys
    end

    test "own keys are declared" do
      assert {:ok, trades} = Coinbase.call_options(:get_trades)
      assert :limit in trades and :since in trades and :include_broken in trades

      assert {:ok, create} = Coinbase.call_options(:create_account)
      assert :name in create

      assert {:ok, stake} = Coinbase.call_options(:stake)
      assert :portfolio_id in stake and :idempotency_key in stake
    end

    test "a name that is not a facade function is {:error, {:unknown_function, name}}" do
      for name <- [:nope, :dp_contract_no_such_function, :get_alias_map, nil, "x", 1, {:a, 1}] do
        assert Coinbase.call_options(name) == {:error, {:unknown_function, name}}
      end
    end

    test "an unknown name is never {:ok, []}" do
      refute match?({:ok, _}, Coinbase.call_options(:nope))
    end
  end

  describe "call_options/1 on the fake" do
    test "every public function answers {:ok, keys} or {:error, :not_supported}" do
      inactive = inactive_callbacks(Fake)

      for name <- function_names(Fake) do
        answer = Fake.call_options(name)

        if name in inactive do
          assert answer == {:error, :not_supported}, "#{name}: #{inspect(answer)}"
        else
          assert {:ok, keys} = answer, "#{name}: #{inspect(answer)}"
          assert unique_atoms?(keys), "#{name} declares #{inspect(keys)}"
        end
      end
    end

    test "the fake exports every function the facade does, so both answer for the same names" do
      assert function_names(Coinbase) -- function_names(Fake) == []
    end

    test "the facade's keys are a subset of the fake's for every active endpoint" do
      inactive = inactive_callbacks(Coinbase)

      for name <- function_names(Coinbase), name not in inactive do
        {:ok, facade_keys} = Coinbase.call_options(name)
        {:ok, fake_keys} = Fake.call_options(name)

        missing = facade_keys -- fake_keys
        assert missing == [], "#{name}: the fake lacks #{inspect(missing)}"
      end
    end

    test "the fake's own seam is declared: :channels on subscribe/2" do
      {:ok, facade} = Coinbase.call_options(:subscribe)
      {:ok, fake} = Fake.call_options(:subscribe)

      refute :channels in facade
      assert :channels in fake
    end

    test "an unknown name is {:error, {:unknown_function, name}}" do
      for name <- [:nope, :dp_contract_no_such_function, "x", 1] do
        assert Fake.call_options(name) == {:error, {:unknown_function, name}}
      end
    end

    test "the keys the fake declares pass the check the fake itself runs" do
      inactive = inactive_callbacks(Fake)

      for name <- function_names(Fake), name not in inactive do
        {:ok, keys} = Fake.call_options(name)
        assert_accepted(name, keys -- [:channels])
      end
    end
  end

  # Whether `keys` pass the option check the call site for `name` runs, with every value nil.
  defp assert_accepted(name, keys) do
    cond do
      name in @start_functions ->
        assert OptionKeys.check_start(nil_opts(keys)) == :ok

      name in @no_options ->
        assert keys == []

      true ->
        assert OptionKeys.check(name, nil_opts(keys)) == :ok, "#{name} refuses #{inspect(keys)}"
    end
  end
end

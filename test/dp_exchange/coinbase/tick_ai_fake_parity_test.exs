defmodule DpExchange.Coinbase.TickAiFakeParityTest do
  @moduledoc """
  Fake export parity: every public function on the facade exists on the Fake with the same
  name and arity, and the ones the Fake gained answer in the real path's order (injected
  outcome, argument checks, credential, answer) with the vendor spec's shapes.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase
  alias DpExchange.Coinbase.{Fake, Prime}
  alias DpExchange.Core.FakeInjection

  @credentials %{
    api_key: "organizations/x/apiKeys/y",
    api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
  }
  @prime_credentials %{
    access_key: "prime-key",
    passphrase: "prime-passphrase",
    signing_key: "prime-signing-key"
  }
  @missing {:error, {:missing_credentials, :coinbase}}
  @missing_prime {:error, :missing_prime_credentials}
  @portfolio "3f2a9c1e-7b64-4d08-9e15-a0c2b7d4f681"
  @wallet "wallet-1"

  test "the Fake exports everything the facade does" do
    assert Coinbase.__info__(:functions) -- Fake.__info__(:functions) == []
  end

  test "the arities reached by leaving options out exist on both" do
    for {name, arity} <- [
          {:get_market_overview, 0},
          {:list_instruments, 0},
          {:get_server_time, 0},
          {:get_server_time, 1},
          {:venue_does_not_serve, 0}
        ] do
      assert function_exported?(Coinbase, name, arity)
      assert function_exported?(Fake, name, arity)
    end
  end

  describe "the public reads without options" do
    test "answer the same as with an empty list" do
      assert Fake.get_market_overview() == Fake.get_market_overview([])
      assert Fake.list_instruments() == Fake.list_instruments([])
    end

    test "venue_does_not_serve is the facade's list" do
      assert Fake.venue_does_not_serve() == Coinbase.venue_does_not_serve()
    end

    test "get_server_time is a fixed clock with the venue's three keys" do
      assert {:ok, %{"iso" => iso, "epochSeconds" => secs, "epochMillis" => millis}} =
               Fake.get_server_time()

      assert iso == "2026-08-28T12:00:00Z"
      assert String.to_integer(millis) == String.to_integer(secs) * 1000
      assert Fake.get_server_time() == Fake.get_server_time([])
    end

    test "an injected outcome wins" do
      FakeInjection.queue_failures(:coinbase, [{:error, :boom}])
      assert Fake.get_server_time() == {:error, :boom}
    end
  end

  describe "futures reads" do
    test "list_futures_positions refuses a portfolio scope before the credential" do
      assert {:error, {:unsupported_option, :portfolio}} =
               Fake.list_futures_positions(portfolio: "p")

      assert {:error, {:unsupported_option, :portfolio}} =
               Fake.list_futures_positions(credentials: @credentials, portfolio: "p")
    end

    test "list_futures_positions needs a credential, then answers the venue's own row" do
      assert Fake.list_futures_positions([]) == @missing

      assert {:ok, [%{"product_id" => "BIT-28JUL23-CDE", "side" => "SHORT"} = row]} =
               Fake.list_futures_positions(credentials: @credentials)

      assert row["daily_realized_pnl"] == "0"
      assert row["expiration_time"] == "2023-07-28T15:00:00Z"
    end

    test "get_futures_position checks the id, then the portfolio, then the credential" do
      assert {:error, {:invalid_id, :product_id, ""}} =
               Fake.get_futures_position(nil, "", portfolio: "p")

      assert {:error, {:unsupported_option, :portfolio}} =
               Fake.get_futures_position(nil, "BIT-28JUL23-CDE", portfolio: "p")

      assert Fake.get_futures_position(nil, "BIT-28JUL23-CDE", []) == @missing
    end

    test "get_futures_position answers the carried product and refuses another" do
      assert {:ok, %{"product_id" => "BIT-28JUL23-CDE"}} =
               Fake.get_futures_position(@credentials, "BIT-28JUL23-CDE", [])

      assert Fake.get_futures_position(@credentials, "ETH-29SEP23-CDE", []) ==
               {:refused, :not_listed}
    end

    test "get_futures_balance_summary needs a credential and keeps the currency on amounts" do
      assert Fake.get_futures_balance_summary(nil, []) == @missing

      assert {:ok,
              %{"cfm_usd_balance" => %{"value" => _value, "currency" => "USD", "cbrn" => _cbrn}}} =
               Fake.get_futures_balance_summary(@credentials, [])
    end

    test "get_current_margin_window checks the enum, then the credential" do
      assert {:error, {:invalid_option, :margin_profile_type, "NOPE"}} =
               Fake.get_current_margin_window(nil, margin_profile_type: "NOPE")

      assert Fake.get_current_margin_window(nil, []) == @missing

      assert {:ok, %{"margin_window" => %{"margin_window_type" => type}} = window} =
               Fake.get_current_margin_window(
                 @credentials,
                 margin_profile_type: "MARGIN_PROFILE_TYPE_RETAIL_REGULAR"
               )

      assert type == "MARGIN_WINDOW_TYPE_OVERNIGHT"
      assert window["is_intraday_margin_killswitch_enabled"] == false
    end
  end

  describe "futures sweeps" do
    test "an empty queue, then a scheduled sweep shows, then a cancel clears it" do
      assert Fake.list_futures_sweeps(nil, []) == @missing
      assert Fake.list_futures_sweeps(@credentials, []) == {:ok, []}

      assert Fake.schedule_futures_sweep(@credentials, []) == {:ok, %{"success" => true}}

      assert {:ok, [%{"status" => "PENDING", "should_sweep_all" => true} = sweep]} =
               Fake.list_futures_sweeps(@credentials, [])

      refute Map.has_key?(sweep, "requested_amount")

      assert Fake.cancel_futures_sweep(@credentials, []) == {:ok, %{"success" => true}}
      assert Fake.list_futures_sweeps(@credentials, []) == {:ok, []}
    end

    test "cancelling with nothing pending is the refusal the real path gives success false" do
      assert Fake.cancel_futures_sweep(nil, []) == @missing

      assert Fake.cancel_futures_sweep(@credentials, []) ==
               {:refused, :sweep_not_cancelled}
    end

    test "schedule_futures_sweep checks the amount before the credential" do
      assert {:error, {:invalid_amount, 1.5}} =
               Fake.schedule_futures_sweep(nil, usd_amount: 1.5)

      assert {:error, {:invalid_amount, "0"}} =
               Fake.schedule_futures_sweep(@credentials, usd_amount: "0")

      assert Fake.schedule_futures_sweep(nil, usd_amount: "25") == @missing
    end

    test "a present amount rides on the row in the spec's amount shape" do
      assert {:ok, _result} =
               Fake.schedule_futures_sweep(@credentials, usd_amount: Decimal.new("25.5"))

      assert {:ok, [%{"should_sweep_all" => false, "requested_amount" => amount}]} =
               Fake.list_futures_sweeps(@credentials, [])

      assert amount == %{"value" => "25.5", "currency" => "USD", "cbrn" => ""}
    end
  end

  describe "intraday margin setting" do
    test "defaults to STANDARD and remembers what was set" do
      assert Fake.get_intraday_margin_setting(nil, []) == @missing

      assert Fake.get_intraday_margin_setting(@credentials, []) ==
               {:ok, "INTRADAY_MARGIN_SETTING_STANDARD"}

      assert Fake.set_intraday_margin_setting(
               @credentials,
               "INTRADAY_MARGIN_SETTING_INTRADAY",
               []
             ) == {:ok, %{}}

      assert Fake.get_intraday_margin_setting(@credentials, []) ==
               {:ok, "INTRADAY_MARGIN_SETTING_INTRADAY"}
    end

    test "set refuses a setting outside the enum before the credential" do
      assert {:error, {:invalid_margin_setting, "MAX"}} =
               Fake.set_intraday_margin_setting(nil, "MAX", [])

      assert Fake.set_intraday_margin_setting(nil, "INTRADAY_MARGIN_SETTING_STANDARD", []) ==
               @missing
    end

    test "the real path refuses the same setting the same way" do
      assert Coinbase.set_intraday_margin_setting(@credentials, "MAX", []) ==
               Fake.set_intraday_margin_setting(@credentials, "MAX", [])
    end
  end

  describe "portfolio breakdown and delete" do
    test "get_breakdown checks the id and currency, then the credential" do
      assert {:error, {:invalid_id, :portfolio_uuid, ""}} =
               Fake.get_portfolio_breakdown(nil, "", currency: 5)

      assert {:error, {:invalid_option, :currency, 5}} =
               Fake.get_portfolio_breakdown(nil, @portfolio, currency: 5)

      assert Fake.get_portfolio_breakdown(nil, @portfolio, []) == @missing
    end

    test "get_breakdown answers the carried portfolios and refuses another" do
      assert {:ok, %{"portfolio" => %{"uuid" => @portfolio, "deleted" => false}} = breakdown} =
               Fake.get_portfolio_breakdown(@credentials, @portfolio, currency: "USD")

      assert %{"total_balance" => %{"currency" => "USD"}} = breakdown["portfolio_balances"]

      assert Fake.get_portfolio_breakdown(@credentials, "no-such-portfolio", []) ==
               {:refused, :not_found}
    end

    test "delete checks the id, then the credential, then the portfolio" do
      assert {:error, {:invalid_id, :portfolio_uuid, nil}} =
               Fake.delete_portfolio(nil, nil, [])

      assert Fake.delete_portfolio(nil, @portfolio, []) == @missing
      assert Fake.delete_portfolio(@credentials, @portfolio, []) == {:ok, %{}}

      assert Fake.delete_portfolio(@credentials, "no-such-portfolio", []) ==
               {:refused, :not_found}
    end
  end

  describe "Prime reads" do
    test "query_transaction_validators checks in the real order" do
      assert {:error, {:invalid_portfolio_id, ""}} =
               Fake.query_transaction_validators(nil, "", extra: :bad)

      assert {:error, {:invalid_extra, :bad}} =
               Fake.query_transaction_validators(nil, @portfolio, extra: :bad)

      assert Fake.query_transaction_validators(nil, @portfolio, []) ==
               {:error, :missing_transaction_ids}

      assert {:error, {:invalid_transaction_ids, [""]}} =
               Fake.query_transaction_validators(nil, @portfolio, transaction_ids: [""])

      assert Fake.query_transaction_validators(@credentials, @portfolio, transaction_ids: ["t"]) ==
               @missing_prime
    end

    test "query_transaction_validators answers one association per id" do
      assert {:ok, %{"transaction_validators" => rows, "pagination" => pagination}} =
               Fake.query_transaction_validators(@prime_credentials, @portfolio,
                 transaction_ids: ["t1", "t2"]
               )

      assert Enum.map(rows, & &1["transaction_id"]) == ["t1", "t2"]
      assert Enum.all?(rows, &(&1["validator_status"] == "VALIDATOR_STATUS_ACTIVE"))
      assert pagination["has_next"] == false
    end

    test "staking_status and unstake_status need both ids, then Prime credentials" do
      for fun <- [:staking_status, :unstake_status] do
        assert {:error, {:invalid_portfolio_id, nil}} = apply(Fake, fun, [nil, nil, @wallet])
        assert {:error, {:invalid_wallet_id, nil}} = apply(Fake, fun, [nil, @portfolio, nil])
        assert apply(Fake, fun, [@credentials, @portfolio, @wallet]) == @missing_prime

        assert {:ok, %{"wallet_id" => @wallet, "validators" => [_validator]}} =
                 apply(Fake, fun, [@prime_credentials, @portfolio, @wallet, []])
      end
    end

    test "unstake_status reports a redemption that is not finished" do
      assert {:ok, %{"validators" => [%{"statuses" => [status]}]}} =
               Fake.unstake_status(@prime_credentials, @portfolio, @wallet)

      assert status["remaining_hours"] > 0
      assert status["estimate_type"] in ["LIVE", "INTERIM"]
    end
  end

  describe "Prime writes" do
    test "claim_rewards checks ids, amount, key and body, then Prime credentials" do
      assert {:error, {:invalid_wallet_id, nil}} =
               Fake.claim_rewards(nil, @portfolio, nil, amount: 1)

      assert {:error, {:invalid_amount, 1}} =
               Fake.claim_rewards(nil, @portfolio, @wallet, amount: 1)

      assert {:error, {:invalid_idempotency_key, "k"}} =
               Fake.claim_rewards(nil, @portfolio, @wallet, idempotency_key: "k")

      assert {:error, {:invalid_body, :bad}} =
               Fake.claim_rewards(nil, @portfolio, @wallet, body: :bad)

      assert Fake.claim_rewards(@credentials, @portfolio, @wallet) == @missing_prime
    end

    test "claim_rewards derives its ids from the idempotency key" do
      key = "0e6b8d25-9c3a-4f71-b2d8-5a41c7e90f36"

      assert {:ok, %{"wallet_id" => @wallet, "transaction_id" => txn, "activity_id" => act}} =
               Fake.claim_rewards(@prime_credentials, @portfolio, @wallet, idempotency_key: key)

      assert txn == "fake-claim-" <> key
      assert act == "fake-activity-" <> key
    end

    test "preview_unstake_wallet checks ids and amount but not the asset" do
      assert {:error, {:invalid_portfolio_id, nil}} =
               Fake.preview_unstake_wallet(nil, nil, @wallet, "ETH", Decimal.new("1"))

      assert {:error, {:invalid_wallet_id, ""}} =
               Fake.preview_unstake_wallet(nil, @portfolio, "", "ETH", Decimal.new("1"))

      assert {:error, {:invalid_amount, 1}} =
               Fake.preview_unstake_wallet(nil, @portfolio, @wallet, "ETH", 1)

      assert Fake.preview_unstake_wallet(nil, @portfolio, @wallet, nil, Decimal.new("1")) ==
               @missing_prime
    end

    test "preview_unstake_wallet carries the requested amount and reserves nothing" do
      assert {:ok, %{"estimated_amount" => "0.5", "validators" => [validator]}} =
               Fake.preview_unstake_wallet(
                 @prime_credentials,
                 @portfolio,
                 @wallet,
                 "ETH",
                 Decimal.new("0.5")
               )

      assert validator["estimated_unstaking_amount"] == "0.5"
    end
  end

  describe "the real validators the Fake calls" do
    test "Prime.validate_wallet_scope treats a nil wallet as invalid, unlike validate_scope" do
      assert Prime.validate_scope(@portfolio, nil) == :ok
      assert Prime.validate_wallet_scope(@portfolio, nil) == {:error, {:invalid_wallet_id, nil}}
    end
  end
end

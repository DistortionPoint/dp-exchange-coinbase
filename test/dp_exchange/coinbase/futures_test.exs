defmodule DpExchange.Coinbase.FuturesTest do
  @moduledoc """
  US derivatives — the CFM surface.

  **Two accounts, and the difference is the whole file.** Futures margin from an account
  held with Coinbase Financial Markets; spot sits in one held with Coinbase Inc. A caller
  sizing against `total_usd_balance` is sizing against money that is not margining anything.

  The mapping's sharp edge is `daily_realized_pnl`: it is what a position realised **today**,
  and `Types.Position`'s `:realised_pnl` means what the position has realised. Putting one in
  the other answers a different question under the same field name, so the struct leaves it
  `nil` and `list_futures_positions/2` returns the row where the venue's own name survives.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Rest
  alias DpExchange.Core.Config

  @moduletag :capture_log

  defmodule PermissiveLimiter do
    @moduledoc false
    @behaviour DpExchange.Core.RateLimitBehaviour

    @impl true
    def acquire(_provider, _weight, _opts), do: :ok
    @impl true
    def check(_provider, _weight, _opts), do: :ok
    @impl true
    def record(_provider, _weight, _opts), do: :ok
  end

  setup do
    Config.put_override(:rate_limit_module, PermissiveLimiter)
    :ok
  end

  @credentials %{
    api_key: "organizations/x/apiKeys/y",
    api_secret: "-----BEGIN EC PRIVATE KEY-----"
  }

  defp responding(body) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp capturing(body, test_pid) do
    fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request, conn.method, conn.request_path, conn.query_string, raw})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  defp position_row(overrides \\ %{}) do
    Map.merge(
      %{
        "product_id" => "BIT-28JUL23-CDE",
        "expiration_time" => "2026-07-28T00:00:00Z",
        "side" => "SHORT",
        "number_of_contracts" => "3",
        "current_price" => "29500",
        "avg_entry_price" => "30000",
        "unrealized_pnl" => "1500",
        "daily_realized_pnl" => "42"
      },
      overrides
    )
  end

  describe "get_positions/2 — what maps and what does not" do
    test "a short maps to an explicit side and a positive size" do
      body = %{"positions" => [position_row()]}

      assert {:ok, [position]} =
               Rest.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert position.side == :short
      assert Decimal.equal?(position.quantity, Decimal.new("3"))
      assert position.symbol == "BIT-28JUL23-CDE"
      assert position.instrument_type == :future
    end

    test "the venue's UNKNOWN is nil, not a side" do
      # A position filed the wrong way round is the most expensive mistake in this mapping.
      body = %{"positions" => [position_row(%{"side" => "UNKNOWN"})]}

      assert {:ok, [position]} =
               Rest.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert position.side == nil
    end

    test "realised P&L is nil, because the venue publishes only a daily figure" do
      # Putting a daily number in a lifetime field answers a different question under the
      # same name: a caller summing across reads would count one day repeatedly.
      body = %{"positions" => [position_row()]}

      assert {:ok, [position]} =
               Rest.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert position.realised_pnl == nil
      assert Decimal.equal?(position.unrealised_pnl, Decimal.new("1500"))
    end

    test "the daily figure survives on the venue's own row" do
      body = %{"positions" => [position_row()]}

      assert {:ok, [row]} =
               Rest.list_futures_positions(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert row["daily_realized_pnl"] == "42"
      assert row["expiration_time"] == "2026-07-28T00:00:00Z"
    end

    test "liquidation price is nil here, and the balance summary is where room is judged" do
      body = %{"positions" => [position_row()]}

      assert {:ok, [position]} =
               Rest.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert position.liquidation_price == nil
    end

    test "no positions is an empty list" do
      assert {:ok, []} =
               Rest.get_positions(@credentials,
                 plug: responding(%{"positions" => []}),
                 retry_attempts: 0
               )
    end

    test "a body without the key is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_positions(@credentials, plug: responding(%{}), retry_attempts: 0)
    end

    test "one position is fetched by product id, expiry included" do
      me = self()

      assert {:ok, position} =
               Rest.get_futures_position(@credentials, "BIT-28JUL23-CDE",
                 plug: capturing(%{"position" => position_row()}, me),
                 retry_attempts: 0
               )

      assert position["product_id"] == "BIT-28JUL23-CDE"
      assert_receive {:request, "GET", path, _query, _raw}
      assert String.ends_with?(path, "/cfm/positions/BIT-28JUL23-CDE")
    end
  end

  describe "the balance summary names two accounts" do
    test "the CFM and CBI balances stay apart, with their currencies attached" do
      body = %{
        "balance_summary" => %{
          "total_usd_balance" => %{"value" => "10000", "currency" => "USD"},
          "cbi_usd_balance" => %{"value" => "7000", "currency" => "USD"},
          "cfm_usd_balance" => %{"value" => "3000", "currency" => "USD"},
          "liquidation_threshold" => %{"value" => "500", "currency" => "USD"}
        }
      }

      assert {:ok, summary} =
               Rest.get_futures_balance_summary(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert summary["cfm_usd_balance"]["value"] == "3000"
      assert summary["cbi_usd_balance"]["value"] == "7000"
      # Only the CFM balance margins a position; the total is not it.
      refute summary["cfm_usd_balance"] == summary["total_usd_balance"]
      assert summary["liquidation_threshold"]["currency"] == "USD"
    end

    test "a body without the key is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_futures_balance_summary(@credentials,
                 plug: responding(%{}),
                 retry_attempts: 0
               )
    end
  end

  describe "sweeps move money out of the futures account" do
    test "a listed sweep carries its status and has not happened yet" do
      body = %{
        "sweeps" => [
          %{
            "id" => "s-1",
            "requested_amount" => %{"value" => "500", "currency" => "USD"},
            "should_sweep_all" => false,
            "status" => "PENDING",
            "scheduled_time" => "2026-09-02T12:00:00Z"
          }
        ]
      }

      assert {:ok, [sweep]} =
               Rest.list_futures_sweeps(@credentials, plug: responding(body), retry_attempts: 0)

      assert sweep["status"] == "PENDING"
      assert sweep["scheduled_time"]
    end

    test "an empty queue is an empty list, not an absence of history" do
      assert {:ok, []} =
               Rest.list_futures_sweeps(@credentials,
                 plug: responding(%{"sweeps" => []}),
                 retry_attempts: 0
               )
    end

    test "an amount is sent in full notation" do
      me = self()

      assert {:ok, _result} =
               Rest.schedule_futures_sweep(@credentials,
                 usd_amount: Decimal.new("0.00000001"),
                 plug: capturing(%{"success" => true}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, _query, raw}
      assert String.ends_with?(path, "/cfm/sweeps/schedule")
      assert Jason.decode!(raw)["usd_amount"] == "0.00000001"
    end

    test "no amount sends no amount, which is the venue sweeping everything" do
      # Stated because a caller that thought a missing amount meant "nothing" would move
      # the lot.
      me = self()

      assert {:ok, _result} =
               Rest.schedule_futures_sweep(@credentials,
                 plug: capturing(%{"success" => true}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw}
      assert Jason.decode!(raw) == %{}
    end

    test "cancelling is a DELETE that takes no id" do
      me = self()

      assert {:ok, %{"success" => true}} =
               Rest.cancel_futures_sweep(@credentials,
                 plug: capturing(%{"success" => true}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "DELETE", path, query, _raw}
      assert String.ends_with?(path, "/cfm/sweeps")
      assert query == ""
    end
  end

  describe "intraday margin" do
    test "the setting comes back as the venue's own string" do
      assert {:ok, "INTRADAY_MARGIN_SETTING_INTRADAY"} =
               Rest.get_intraday_margin_setting(@credentials,
                 plug: responding(%{"setting" => "INTRADAY_MARGIN_SETTING_INTRADAY"}),
                 retry_attempts: 0
               )
    end

    test "UNSPECIFIED is returned as itself, not mapped to STANDARD" do
      # UNSPECIFIED is the venue declining to say. Mapping it to the safer-sounding value
      # would assert a setting the account may not have.
      assert {:ok, "INTRADAY_MARGIN_SETTING_UNSPECIFIED"} =
               Rest.get_intraday_margin_setting(@credentials,
                 plug: responding(%{"setting" => "INTRADAY_MARGIN_SETTING_UNSPECIFIED"}),
                 retry_attempts: 0
               )
    end

    test "setting it sends the venue's own string and nothing else" do
      me = self()

      assert {:ok, _result} =
               Rest.set_intraday_margin_setting(
                 @credentials,
                 "INTRADAY_MARGIN_SETTING_STANDARD",
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", path, _query, raw}
      assert String.ends_with?(path, "/cfm/intraday/margin_setting")
      assert Jason.decode!(raw) == %{"setting" => "INTRADAY_MARGIN_SETTING_STANDARD"}
    end

    test "the margin window carries its end time and both kill switches" do
      body = %{
        "margin_window" => %{
          "margin_window_type" => "MARGIN_WINDOW_TYPE_INTRADAY",
          "end_time" => "2026-09-01T20:00:00Z"
        },
        "is_intraday_margin_killswitch_enabled" => true,
        "is_intraday_margin_enrollment_killswitch_enabled" => false
      }

      assert {:ok, window} =
               Rest.get_current_margin_window(@credentials,
                 plug: responding(body),
                 retry_attempts: 0
               )

      # An account that believes it is on intraday margin while the switch is enabled has
      # more leverage in its plan than in its account.
      assert window["is_intraday_margin_killswitch_enabled"] == true
      assert window["margin_window"]["end_time"]
    end

    test "the profile type is sent only when given" do
      me = self()

      assert {:ok, _window} =
               Rest.get_current_margin_window(@credentials,
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query, _raw}
      refute query =~ "margin_profile_type"

      assert {:ok, _window} =
               Rest.get_current_margin_window(@credentials,
                 margin_profile_type: "MARGIN_PROFILE_TYPE_RETAIL_INTRADAY_MARGIN_1",
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query2, _raw}
      assert query2 =~ "margin_profile_type=MARGIN_PROFILE_TYPE_RETAIL_INTRADAY_MARGIN_1"
    end
  end

  describe "the facade reaches all of it" do
    test "each CFM function delegates" do
      assert {:ok, [_position]} =
               DpExchange.Coinbase.get_positions(
                 credentials: @credentials,
                 plug: responding(%{"positions" => [position_row()]}),
                 retry_attempts: 0
               )

      assert {:ok, [_row]} =
               DpExchange.Coinbase.list_futures_positions(
                 credentials: @credentials,
                 plug: responding(%{"positions" => [position_row()]}),
                 retry_attempts: 0
               )

      assert {:ok, _position} =
               DpExchange.Coinbase.get_futures_position(@credentials, "BIT-28JUL23-CDE",
                 plug: responding(%{"position" => position_row()}),
                 retry_attempts: 0
               )

      assert {:ok, _summary} =
               DpExchange.Coinbase.get_futures_balance_summary(@credentials,
                 plug: responding(%{"balance_summary" => %{}}),
                 retry_attempts: 0
               )

      assert {:ok, []} =
               DpExchange.Coinbase.list_futures_sweeps(@credentials,
                 plug: responding(%{"sweeps" => []}),
                 retry_attempts: 0
               )

      assert {:ok, _result} =
               DpExchange.Coinbase.schedule_futures_sweep(@credentials,
                 plug: responding(%{"success" => true}),
                 retry_attempts: 0
               )

      assert {:ok, _result} =
               DpExchange.Coinbase.cancel_futures_sweep(@credentials,
                 plug: responding(%{"success" => true}),
                 retry_attempts: 0
               )

      assert {:ok, "X"} =
               DpExchange.Coinbase.get_intraday_margin_setting(@credentials,
                 plug: responding(%{"setting" => "X"}),
                 retry_attempts: 0
               )

      assert {:ok, _result} =
               DpExchange.Coinbase.set_intraday_margin_setting(@credentials, "X",
                 plug: responding(%{}),
                 retry_attempts: 0
               )

      assert {:ok, _window} =
               DpExchange.Coinbase.get_current_margin_window(@credentials,
                 plug: responding(%{}),
                 retry_attempts: 0
               )
    end
  end

  describe "the venue answering something else, on every CFM endpoint" do
    defp unreadable, do: responding(%{"something" => "else"})

    defp failing(status) do
      fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(status, Jason.encode!(%{"error" => "nope"}))
      end
    end

    test "each read refuses an unreadable body rather than answering empty" do
      # "The venue answered something else" and "there is nothing" are different answers,
      # and only the second is worth acting on.
      opts = [plug: unreadable(), retry_attempts: 0]

      assert {:error, :unexpected_response_shape} =
               Rest.list_futures_positions(@credentials, opts)

      assert {:error, :unexpected_response_shape} =
               Rest.get_futures_position(@credentials, "BIT-28JUL23-CDE", opts)

      assert {:error, :unexpected_response_shape} =
               Rest.get_futures_balance_summary(@credentials, opts)

      assert {:error, :unexpected_response_shape} = Rest.list_futures_sweeps(@credentials, opts)

      assert {:error, :unexpected_response_shape} =
               Rest.get_intraday_margin_setting(@credentials, opts)
    end

    test "a 404 on one position is a refusal, not an error" do
      assert {:refused, :not_listed} =
               Rest.get_futures_position(@credentials, "BIT-GONE-CDE",
                 plug: failing(404),
                 retry_attempts: 0
               )
    end

    test "a 500 is an error on each of them, because retrying can help" do
      opts = [plug: failing(500), retry_attempts: 0]

      assert {:error, _reason} = Rest.list_futures_positions(@credentials, opts)
      assert {:error, _reason} = Rest.get_futures_balance_summary(@credentials, opts)
      assert {:error, _reason} = Rest.list_futures_sweeps(@credentials, opts)
      assert {:error, _reason} = Rest.schedule_futures_sweep(@credentials, opts)
      assert {:error, _reason} = Rest.cancel_futures_sweep(@credentials, opts)
      assert {:error, _reason} = Rest.get_intraday_margin_setting(@credentials, opts)
      assert {:error, _reason} = Rest.set_intraday_margin_setting(@credentials, "X", opts)
      assert {:error, _reason} = Rest.get_current_margin_window(@credentials, opts)
    end

    test "a sweep amount given as a plain string is passed through" do
      # A caller holding the venue's own string should not have it re-formatted.
      me = self()

      assert {:ok, _result} =
               Rest.schedule_futures_sweep(@credentials,
                 usd_amount: "500",
                 plug: capturing(%{"success" => true}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "POST", _path, _query, raw}
      assert Jason.decode!(raw)["usd_amount"] == "500"
    end

    test "a long maps to :long, completing the side table" do
      body = %{"positions" => [position_row(%{"side" => "LONG"})]}

      assert {:ok, [position]} =
               Rest.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert position.side == :long
    end

    test "an amount arriving as the venue's nested object is read from its value" do
      # The balance summary nests every amount; the position rows do not. Both shapes reach
      # the same reader.
      body = %{
        "positions" => [
          position_row(%{"number_of_contracts" => %{"value" => "3", "currency" => "USD"}})
        ]
      }

      assert {:ok, [position]} =
               Rest.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert Decimal.equal?(position.quantity, Decimal.new("3"))
    end

    test "a missing amount is nil rather than zero" do
      body = %{"positions" => [Map.delete(position_row(), "number_of_contracts")]}

      assert {:ok, [position]} =
               Rest.get_positions(@credentials, plug: responding(body), retry_attempts: 0)

      assert position.quantity == nil
    end
  end
end

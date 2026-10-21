defmodule DpExchange.Coinbase.TickAqTest do
  @moduledoc """
  Tick AQ: numbers and identifiers from venue text (S), configuration, startup and option
  validation (T), and unbounded state and resource cleanup (U).

  Every test here decides against a plug, a hand-built state or an in-process feed; nothing
  reaches a venue.
  """

  use DpExchange.Coinbase.FeedCase, async: true

  alias DpExchange.Coinbase.{Fake, Feed, OptionKeys, Prime, Rest, Socket, VenueNumber}
  alias DpExchange.Coinbase.Supervisor, as: VenueSupervisor
  alias DpExchange.Core.{Config, Notice, Types}

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
    api_secret: "dGVzdC1zZWNyZXQtdGhpcnR5LXR3by1ieXRlcyEhISE="
  }

  defp responding(body, status) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end
  end

  defp answering(body, status \\ 200), do: [plug: responding(body, status), retry_attempts: 0]

  defp limit_request(overrides) do
    Map.merge(
      %{
        symbol: "BTC-USD",
        side: :buy,
        quantity: Decimal.new("0.5"),
        price: Decimal.new("40000"),
        order_type: :limit,
        time_in_force: :gtc
      },
      overrides
    )
  end

  defp unique_name(prefix), do: :"#{prefix}_#{System.unique_integer([:positive])}"

  defp drain(acc \\ []) do
    receive do
      {:dp_exchange, :coinbase, message} -> drain([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ---------------------------------------------------------------------------------------
  # S. Numbers, precision and identifiers from venue text
  # ---------------------------------------------------------------------------------------

  # A whole number of `count` digits, built from the struct so that no text is parsed:
  # `Decimal.new/1` on a 35-digit string raises on decimal 3.2.0. The struct fields are the
  # same on decimal 2.0 and 3.x.
  defp ones(count), do: %Decimal{sign: 1, coef: div(Integer.pow(10, count) - 1, 9), exp: 0}
  defp nines(count), do: %Decimal{sign: 1, coef: Integer.pow(10, count) - 1, exp: 0}

  describe "VenueNumber.bounded?/1" do
    test "admits 34 digits and 64 places either side of the point" do
      assert VenueNumber.bounded?(nines(34))
      assert VenueNumber.bounded?(Decimal.new("1E64"))
      assert VenueNumber.bounded?(Decimal.new("1E-64"))
      assert VenueNumber.bounded?(Decimal.new("0.00000001"))
    end

    test "refuses a 35th digit, a wider exponent, NaN and the infinities" do
      refute VenueNumber.bounded?(nines(35))
      refute VenueNumber.bounded?(Decimal.new("1E65"))
      refute VenueNumber.bounded?(Decimal.new("1E-65"))
      refute VenueNumber.bounded?(%Decimal{sign: 1, coef: :NaN, exp: 0})
      refute VenueNumber.bounded?(%Decimal{sign: 1, coef: :inf, exp: 0})
      refute VenueNumber.bounded?(%Decimal{sign: -1, coef: :inf, exp: 0})
    end
  end

  describe "a number from the venue is bounded to 34 digits" do
    defp ticker(price) do
      %{"trades" => [%{"time" => "2026-08-28T12:00:00Z", "price" => price}]}
    end

    test "a price of 34 digits is read and one of 35 is unreadable, not a huge Decimal" do
      readable = String.duplicate("1", 34)
      wide = String.duplicate("1", 35)

      assert {:ok, %{price: price}} = Rest.get_price("BTC-USD", answering(ticker(readable)))
      assert Decimal.equal?(price, ones(34))

      assert {:error, {:invalid_decimal, :price, ^wide}} =
               Rest.get_price("BTC-USD", answering(ticker(wide)))
    end

    test "a bare integer of 40 digits in a venue field is unreadable too" do
      assert {:error, {:invalid_decimal, :price, _value}} =
               Rest.get_price("BTC-USD", answering(ticker(Integer.pow(10, 40))))
    end
  end

  describe "an amount a caller passes is bounded to 34 digits" do
    test "a wider Decimal, integer or string is refused by name, a 34-digit one is kept" do
      wide = ones(35)
      readable = ones(34)

      assert {:error, {:invalid_quantity, ^wide}} =
               Rest.order_plan(limit_request(%{quantity: wide}), :place)

      assert {:error, {:invalid_quantity, _value}} =
               Rest.order_plan(limit_request(%{quantity: Integer.pow(10, 40)}), :place)

      assert {:error, {:invalid_price, _value}} =
               Rest.order_plan(limit_request(%{price: String.duplicate("1", 40)}), :place)

      assert {:ok, %{quantity: ^readable}} =
               Rest.order_plan(limit_request(%{quantity: readable}), :place)
    end

    test "a staking amount is held to the same bound" do
      assert :ok = Prime.validate_positional("ETH", ones(34))

      assert {:error, {:invalid_amount, _amount}} =
               Prime.validate_positional("ETH", ones(35))
    end

    test "a 35-digit amount passed as TEXT is a named refusal, never a raise" do
      wide = String.duplicate("1", 35)

      assert {:error, {:invalid_quantity, ^wide}} =
               Rest.order_plan(limit_request(%{quantity: wide}), :place)

      assert {:error, {:invalid_price, ^wide}} =
               Rest.order_plan(limit_request(%{price: wide}), :place)

      assert {:error, {:invalid_amount, ^wide}} = Prime.validate_positional("ETH", wide)
    end
  end

  describe "an order off the venue's increment is sent as given, never rounded" do
    test "the price and size reach the venue exactly, and its refusal is the answer" do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        reply = %{
          "success" => false,
          "error_response" => %{"new_order_failure_reason" => "INVALID_PRICE_PRECISION"}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(reply))
      end

      request =
        limit_request(%{
          price: Decimal.new("40000.123456789"),
          quantity: Decimal.new("0.123456789012")
        })

      assert {:refused, {:order_rejected, "INVALID_PRICE_PRECISION"}} =
               Rest.place_order(@credentials, request, plug: plug, retry_attempts: 0)

      assert_receive {:sent, %{"order_configuration" => %{"limit_limit_gtc" => leaf}}}, 5_000
      assert leaf["limit_price"] == "40000.123456789"
      assert leaf["base_size"] == "0.123456789012"
    end

    test "a size below a millionth is sent in plain notation, never as 1E-8" do
      me = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(me, {:sent, Jason.decode!(body)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"errs" => [], "warning" => []}))
      end

      request = limit_request(%{quantity: Decimal.new("1E-8"), price: Decimal.new("1.5E+2")})

      assert {:ok, _preview} =
               Rest.preview_order(@credentials, request, plug: plug, retry_attempts: 0)

      assert_receive {:sent, %{"order_configuration" => %{"limit_limit_gtc" => leaf}}}, 5_000
      assert leaf["base_size"] == "0.00000001"
      assert leaf["limit_price"] == "150"
    end
  end

  describe "quantization/2 reads the product's figures as Decimals, or not at all" do
    test "an increment or maximum at or below zero, or unreadable, is not stated" do
      product = %{
        "product_id" => "BTC-USD",
        "price_increment" => "0",
        "base_increment" => "-0.00000001",
        "base_min_size" => "-1",
        "quote_min_size" => "0",
        "base_max_size" => "NaN",
        "quote_max_size" => "1e999",
        "status" => 5
      }

      assert {:ok, q} = Rest.quantization("BTC-USD", answering(product))

      assert q.price_increment == nil
      assert q.quantity_increment == nil
      assert q.min_quantity == nil
      assert q.max_quantity == nil
      assert q.max_quote_size == nil
      assert q.status == nil
      # Zero is a minimum of nothing, which a venue may state.
      assert Decimal.equal?(q.min_quote_size, 0)
    end

    test "a product's stated figures are Decimals, never floats" do
      product = %{
        "product_id" => "BTC-USD",
        "price_increment" => "0.01",
        "base_increment" => "0.00000001",
        "base_min_size" => "0.000016",
        "quote_min_size" => "1",
        "base_max_size" => "3500",
        "quote_max_size" => "150000000",
        "status" => "online"
      }

      assert {:ok, q} = Rest.quantization("BTC-USD", answering(product))

      for field <- ~w(price_increment quantity_increment min_quantity min_quote_size
                      max_quantity max_quote_size)a do
        assert %Decimal{} = Map.fetch!(q, field)
      end

      assert q.status == "online"
    end
  end

  describe "a price or an amount at or below zero is not stated" do
    test "a futures position's prices" do
      row = %{
        "product_id" => "BIT-28JUL23-CDE",
        "side" => "LONG",
        "number_of_contracts" => "3",
        "avg_entry_price" => "-1",
        "current_price" => "0"
      }

      assert {:ok, [position]} =
               Rest.get_positions(@credentials, answering(%{"positions" => [row]}))

      assert position.average_cost == nil
      assert position.mark_price == nil
      assert Decimal.equal?(position.quantity, 3)
    end

    test "a conversion's amounts" do
      trade = %{
        "id" => "trade-1",
        "status" => "TRADE_STATUS_CREATED",
        "user_entered_amount" => %{"value" => "-5", "currency" => "USD"},
        "total" => %{"value" => "7.5", "currency" => "BTC"}
      }

      assert {:ok, conversion} =
               Rest.quote_conversion(
                 @credentials,
                 "USD",
                 "BTC",
                 Decimal.new("5"),
                 answering(%{"trade" => trade})
               )

      assert conversion.from_amount == nil
      assert Decimal.equal?(conversion.to_amount, Decimal.new("7.5"))
    end
  end

  describe "a blank asset names nothing" do
    test "a staking write refuses it, in the real path and the fake alike" do
      amount = Decimal.new("1")

      assert {:error, {:invalid_asset, "  "}} = Prime.validate_positional("  ", amount)
      assert {:error, {:invalid_asset, "  "}} = Fake.stake("  ", amount, portfolio_id: "pf-1")
      assert {:error, {:invalid_asset, "  "}} = Fake.unstake("  ", amount, portfolio_id: "pf-1")
    end

    test "an internal transfer refuses it, in the real path and the fake alike" do
      amount = Decimal.new("1")
      transfer = [from: "a", to: "b"]

      assert {:error, {:invalid_asset, "  "}} =
               Rest.transfer_internal(@credentials, "  ", amount, transfer ++ answering(%{}))

      assert {:error, {:invalid_asset, "  "}} =
               Fake.transfer_internal("  ", amount, transfer, credentials: @credentials)
    end
  end

  describe "text the venue sent does not keep its response alive" do
    test "a refusal's words are copied out of the document they were read from" do
      words = String.duplicate("a", 1_500)
      body = %{"message" => words, "padding" => String.duplicate("x", 200_000)}

      assert {:refused, {:venue_error, 401, quoted}} =
               Rest.get_server_time(answering(body, 401))

      assert quoted == words
      assert :binary.referenced_byte_size(quoted) < 3_000
    end
  end

  # ---------------------------------------------------------------------------------------
  # T. Configuration, startup and option validation
  # ---------------------------------------------------------------------------------------

  describe "the options the tree is started with" do
    test "check_start/1 accepts every key the tree reads" do
      opts = [
        name: :a,
        feed: :b,
        limiter: :c,
        ledger: :d,
        credentials: nil,
        channels: [:quotes],
        level2_pairs_per_socket: 30,
        shard_spacing_ms: 1_000,
        resubscribe_interval_ms: 60_000,
        subscribe_retry_delay_ms: 8_000,
        max_queue_len: 100,
        alias_map_source: fn -> {:ok, %{}} end,
        alias_map_retry_delay_ms: 2_000,
        alias_map_fetch_timeout_ms: 30_000,
        alias_map_refresh_ms: 3_600_000,
        url: "ws://127.0.0.1:1/",
        socket: nil,
        plug: nil,
        timeout: 1_000,
        retry_attempts: 1,
        retry_delay: 1,
        weight: 1
      ]

      assert :ok = OptionKeys.check_start(opts)
      assert :ok = OptionKeys.check_start([])
    end

    test "check_start/1 names a key it does not read, and refuses non-keyword options" do
      assert {:error, {:unknown_option, :shard_spacing}} =
               OptionKeys.check_start(name: :a, shard_spacing: 1)

      assert {:error, {:invalid_options, %{name: :a}}} = OptionKeys.check_start(%{name: :a})
    end

    test "the tree refuses a misspelt option at start instead of running with the default" do
      name = unique_name("tick_aq_tree")

      assert {:error, {:unknown_option, :shard_spacing}} =
               VenueSupervisor.start_link(name: name, shard_spacing: 1)

      assert {:error, {:unknown_option, :level2_pairs_per_sockt}} =
               DpExchange.Coinbase.start_link(name: name, level2_pairs_per_sockt: 25)

      assert Process.whereis(name) == nil
    end

    test "a refusal does not echo credentials from options that are not a keyword list" do
      secret = "tick-aq-canary-secret"

      assert {:error, {:invalid_options, echoed}} =
               VenueSupervisor.start_link(%{credentials: %{api_key: "k", api_secret: secret}})

      refute inspect(echoed) =~ secret
    end
  end

  describe "the feed's start options that cannot work are refused at start" do
    defp refused_message(extra) do
      Process.flag(:trap_exit, true)

      base = [name: unique_name("tick_aq_feed"), alias_map_source: fn -> {:ok, %{}} end]

      assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
               Feed.start_link(Keyword.merge(base, extra))

      message
    end

    test "a url that is neither a string nor a URI, without echoing it" do
      assert refused_message(url: 5) =~ "url must be a string or a %URI{}, got a number"

      message = refused_message(url: ~c"ws://user:tick-aq-secret@127.0.0.1:1/")
      assert message =~ "got a list"
      refute message =~ "tick-aq-secret"
    end

    test "an alias_map_source that is not a function of no arguments" do
      assert refused_message(alias_map_source: :nope) =~
               "alias_map_source must be a function of no arguments, got a atom"

      assert refused_message(alias_map_source: fn _catalogue -> {:ok, %{}} end) =~
               "got a function of another arity"
    end

    test "a socket that is not a pid" do
      assert refused_message(socket: :named_socket) =~ "socket must be a pid, got a atom"
    end

    test "a string url, a URI and a pid socket are accepted" do
      source = fn -> {:ok, %{}} end
      url = "ws://127.0.0.1:1/nowhere"

      for {id, extra} <- [
            {:string_url, [url: url]},
            {:uri_url, [url: URI.parse(url)]},
            {:pid_socket, [socket: fake_socket()]}
          ] do
        opts = [name: unique_name("tick_aq_feed"), alias_map_source: source] ++ extra
        assert Process.alive?(start_supervised!({Feed, opts}, id: id))
      end
    end
  end

  # ---------------------------------------------------------------------------------------
  # U. Unbounded state and resource cleanup
  # ---------------------------------------------------------------------------------------

  describe "Socket remembers a bounded set of delivering products" do
    defp socket_state do
      %{
        subscriber: self(),
        credentials: nil,
        delivering: MapSet.new(),
        connected_once?: false,
        last_seq: nil,
        stale_run: nil,
        last_frame_at: nil,
        silence_check: nil,
        connected_at: System.monotonic_time(:millisecond) - 60_000,
        short_sessions: 0
      }
    end

    defp ticker_frame(index) do
      Jason.encode!(%{
        "channel" => "ticker",
        "events" => [
          %{
            "type" => "update",
            "tickers" => [
              %{"product_id" => "P#{index}-USD", "price" => "1.5", "volume_24_h" => "2"}
            ]
          }
        ]
      })
    end

    defp deliver_products(state, indexes) do
      Enum.reduce(indexes, state, fn index, acc ->
        {:ok, next} = Socket.handle_frame({:text, ticker_frame(index)}, acc)
        next
      end)
    end

    test "a venue naming endless products stops growing the set, still delivers, and says so once" do
      state = deliver_products(socket_state(), 1..1_100)

      assert MapSet.size(state.delivering) == 1_024

      messages = drain()
      assert Enum.count(messages, &match?(%Types.Quote{}, &1)) == 1_100

      assert [%Notice{details: %{reason: :delivering_set_full, limit: 1_024}}] =
               Enum.filter(messages, &match?(%Notice{kind: :data_quality}, &1))
    end

    test "an unsubscribe removes its products, and the set grows again below the bound" do
      state = deliver_products(socket_state(), 1..1_100)
      removed = for index <- 1..24, do: "P#{index}-USD"

      assert {:ok, state} = Socket.handle_info({:track_subscription, :remove, removed}, state)
      assert MapSet.size(state.delivering) == 1_000

      state = deliver_products(state, 2_000..2_002)
      assert MapSet.size(state.delivering) == 1_003
    end

    test "the add and remove cycle returns the set to its starting size" do
      state = deliver_products(socket_state(), 1..5)
      assert MapSet.size(state.delivering) == 5

      symbols = for index <- 1..5, do: "P#{index}-USD"
      assert {:ok, state} = Socket.handle_info({:track_subscription, :remove, symbols}, state)
      assert MapSet.size(state.delivering) == 0
    end
  end

  describe "Feed records a bounded number of names nobody asked for" do
    test "an unwanted flood is delivered but not recorded past the bound, with one notice" do
      feed = start_feed()
      assert :ok = Feed.subscribe_notices(feed, to: self())

      for index <- 1..1_100,
          do: send(feed, {:dp_exchange, :coinbase, quote_for("U#{index}-USD")})

      state = :sys.get_state(feed)
      assert map_size(state.delivering) == 1_024
      assert map_size(Feed.coverage(feed)) == 1_024

      assert_receive {:dp_exchange, :coinbase,
                      %Notice{
                        kind: :data_quality,
                        details: %{reason: :unwanted_delivery_unrecorded, limit: 1_024}
                      }},
                     5_000

      refute_receive {:dp_exchange, :coinbase,
                      %Notice{details: %{reason: :unwanted_delivery_unrecorded}}},
                     500
    end

    test "a wanted name is always recorded, and narrowing the wanted set empties the record" do
      feed = start_feed()
      assert :ok = Feed.subscribe_notices(feed, to: self())

      for index <- 1..1_100,
          do: send(feed, {:dp_exchange, :coinbase, quote_for("U#{index}-USD")})

      :sys.replace_state(feed, fn state -> %{state | wanted: MapSet.new(["BTC-USD"])} end)
      send(feed, {:dp_exchange, :coinbase, quote_for("BTC-USD")})

      assert Map.has_key?(:sys.get_state(feed).delivering, "BTC-USD")

      # The add and remove cycle: nothing wanted any more, nothing recorded, and the notice
      # is armed again for the next flood.
      assert :ok = Feed.update_symbols(feed, [])
      state = :sys.get_state(feed)
      assert state.delivering == %{}
      refute state.unrecorded_noticed?

      send(feed, {:dp_exchange, :coinbase, quote_for("U1-USD")})
      assert map_size(:sys.get_state(feed).delivering) == 1
    end
  end
end

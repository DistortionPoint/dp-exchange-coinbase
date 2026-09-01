defmodule DpExchange.Coinbase.PortfoliosTest do
  @moduledoc """
  Portfolios — the address, not the value.

  **"The account's BTC balance" is not a well-formed question on this venue.** Two
  portfolios hold separate balances, take separate positions and can be margined separately,
  and a package that answered anyway has picked one and not said which.

  Two assertions carry the file. **A deleted portfolio stays in the listing** — the venue
  keeps it because old orders still name its id, and filtering it out here would make a
  historical id look like one that never existed. And **the breakdown is not the listing
  narrowed to one**: the listing names portfolios, the breakdown returns what is inside one.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Fake, Rest}
  alias DpExchange.Core.{Config, Types}

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

  describe "list_portfolios/2" do
    test "a deleted portfolio is returned, not filtered out" do
      body = %{
        "portfolios" => [
          %{"uuid" => "pf-1", "name" => "Default", "type" => "DEFAULT", "deleted" => false},
          %{"uuid" => "pf-2", "name" => "Retired", "type" => "CONSUMER", "deleted" => true}
        ]
      }

      assert {:ok, portfolios} =
               Rest.list_portfolios(@credentials, plug: responding(body), retry_attempts: 0)

      assert length(portfolios) == 2
      assert Enum.any?(portfolios, & &1.deleted)
      assert %Types.Portfolio{id: "pf-1", name: "Default"} = hd(portfolios)
    end

    test "no type filter is sent unless the caller asked for one" do
      # A filter this package chose would hide portfolios the caller did not ask to hide.
      me = self()

      assert {:ok, []} =
               Rest.list_portfolios(@credentials,
                 plug: capturing(%{"portfolios" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert String.ends_with?(path, "/portfolios")
      assert query == ""

      assert {:ok, []} =
               Rest.list_portfolios(@credentials,
                 portfolio_type: "CONSUMER",
                 plug: capturing(%{"portfolios" => []}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", _path, query2, _raw}
      assert query2 =~ "portfolio_type=CONSUMER"
    end

    test "a body without the key is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.list_portfolios(@credentials, plug: responding(%{}), retry_attempts: 0)
    end
  end

  describe "the breakdown is a different answer from the listing" do
    test "it comes back as the venue's own map, under its breakdown key" do
      body = %{
        "breakdown" => %{
          "portfolio" => %{"uuid" => "pf-1"},
          "portfolio_balances" => %{"total_balance" => %{"value" => "100"}},
          "spot_positions" => []
        }
      }

      assert {:ok, breakdown} =
               Rest.get_portfolio_breakdown(@credentials, "pf-1",
                 plug: responding(body),
                 retry_attempts: 0
               )

      assert breakdown["portfolio_balances"]["total_balance"]["value"] == "100"
    end

    test "the currency filter reaches the venue" do
      me = self()

      assert {:ok, _breakdown} =
               Rest.get_portfolio_breakdown(@credentials, "pf-1",
                 currency: "USD",
                 plug: capturing(%{"breakdown" => %{}}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "GET", path, query, _raw}
      assert String.ends_with?(path, "/portfolios/pf-1")
      assert query =~ "currency=USD"
    end
  end

  describe "creating, renaming and deleting" do
    test "a create without a name is refused before a request is made" do
      # An unnamed portfolio is one a caller cannot tell from another later.
      assert {:error, :name_required} = Rest.create_portfolio(@credentials, [])
    end

    test "a create sends only the name" do
      me = self()

      assert {:ok, portfolio} =
               Rest.create_portfolio(@credentials,
                 name: "Strategy A",
                 plug:
                   capturing(%{"portfolio" => %{"uuid" => "pf-9", "name" => "Strategy A"}}, me),
                 retry_attempts: 0
               )

      assert portfolio.id == "pf-9"
      assert_receive {:request, "POST", path, _query, raw}
      assert String.ends_with?(path, "/portfolios")
      assert Jason.decode!(raw) == %{"name" => "Strategy A"}
    end

    test "a rename is a PUT carrying only the new name" do
      me = self()

      assert {:ok, portfolio} =
               Rest.rename_portfolio(@credentials, "pf-1", "Renamed",
                 plug: capturing(%{"portfolio" => %{"uuid" => "pf-1", "name" => "Renamed"}}, me),
                 retry_attempts: 0
               )

      assert portfolio.name == "Renamed"
      assert_receive {:request, "PUT", path, _query, raw}
      assert String.ends_with?(path, "/portfolios/pf-1")
      assert Jason.decode!(raw) == %{"name" => "Renamed"}
    end

    test "a delete is a DELETE with no body" do
      me = self()

      assert {:ok, _result} =
               Rest.delete_portfolio(@credentials, "pf-1",
                 plug: capturing(%{}, me),
                 retry_attempts: 0
               )

      assert_receive {:request, "DELETE", path, query, raw}
      assert String.ends_with?(path, "/portfolios/pf-1")
      assert query == ""
      assert raw == ""
    end

    test "an unreadable response on each write is refused" do
      opts = [plug: responding(%{}), retry_attempts: 0]

      assert {:error, :unexpected_response_shape} =
               Rest.create_portfolio(@credentials, [name: "X"] ++ opts)

      assert {:error, :unexpected_response_shape} =
               Rest.rename_portfolio(@credentials, "pf-1", "X", opts)
    end

    test "a 500 is an error on each of the five" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, Jason.encode!(%{"error" => "nope"}))
      end

      opts = [plug: plug, retry_attempts: 0]

      assert {:error, _reason} = Rest.list_portfolios(@credentials, opts)
      assert {:error, _reason} = Rest.get_portfolio_breakdown(@credentials, "pf-1", opts)
      assert {:error, _reason} = Rest.create_portfolio(@credentials, [name: "X"] ++ opts)
      assert {:error, _reason} = Rest.rename_portfolio(@credentials, "pf-1", "X", opts)
      assert {:error, _reason} = Rest.delete_portfolio(@credentials, "pf-1", opts)
    end
  end

  describe "the fake and the facade" do
    test "the fake keeps a deleted portfolio in its listing" do
      assert {:ok, portfolios} = Fake.list_portfolios()
      assert Enum.any?(portfolios, & &1.deleted)
      assert Enum.any?(portfolios, &(&1.deleted == false))
    end

    test "the fake refuses a nameless create and echoes a rename" do
      assert {:error, :name_required} = Fake.create_account()
      assert {:ok, %{name: "Strategy A"}} = Fake.create_account(name: "Strategy A")
      assert {:ok, %{id: "pf-1", name: "Renamed"}} = Fake.rename_account("pf-1", "Renamed")
    end

    test "the facade delegates the listing, the breakdown and the delete" do
      base = [credentials: @credentials, retry_attempts: 0]

      assert {:ok, []} =
               DpExchange.Coinbase.list_portfolios(
                 base ++ [plug: responding(%{"portfolios" => []})]
               )

      assert {:ok, _breakdown} =
               DpExchange.Coinbase.get_portfolio_breakdown(@credentials, "pf-1",
                 plug: responding(%{"breakdown" => %{}}),
                 retry_attempts: 0
               )

      assert {:ok, _result} =
               DpExchange.Coinbase.delete_portfolio(@credentials, "pf-1",
                 plug: responding(%{}),
                 retry_attempts: 0
               )
    end

    test "create_account/1 and rename_account/3 reach the portfolio endpoints" do
      # Advanced Trade has no notion of creating an *account* — a portfolio is the
      # subdivision an API can make, and it is what these callbacks mean here.
      base = [credentials: @credentials, retry_attempts: 0]

      assert {:ok, %{id: "pf-9"}} =
               DpExchange.Coinbase.create_account(
                 base ++
                   [name: "Strategy A", plug: responding(%{"portfolio" => %{"uuid" => "pf-9"}})]
               )

      assert {:ok, %{id: "pf-1"}} =
               DpExchange.Coinbase.rename_account(
                 "pf-1",
                 "Renamed",
                 base ++ [plug: responding(%{"portfolio" => %{"uuid" => "pf-1"}})]
               )
    end
  end
end

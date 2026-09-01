defmodule DpExchange.Coinbase.AdminTest do
  @moduledoc """
  Key permissions, the server clock, and what `test_connection/2` actually asks.

  **`can_transfer` is a separate permission from `can_trade`**, and a key routinely holds
  one and not the other. Asking here is cheaper than discovering a missing one from a
  refused withdrawal.

  **`test_connection/2` asks two different questions.** Without credentials it reads the
  public clock — reachability alone. With them it reads the key's permissions, which fails
  if the key is wrong and says what the key can do if it is right. An unreachable venue and
  an unaccepted key are different problems, and the second comes back `{:refused, _}`.
  """

  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.{Fake, Rest}
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

  @permissions %{
    "can_view" => true,
    "can_trade" => true,
    "can_transfer" => false,
    "portfolio_uuid" => "pf-1",
    "portfolio_type" => "DEFAULT"
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
      send(test_pid, {:request, conn.method, conn.request_path})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end
  end

  describe "get_key_permissions/2" do
    test "the three permissions are separate, and one of them moves money" do
      assert {:ok, permissions} =
               Rest.get_key_permissions(@credentials,
                 plug: responding(@permissions),
                 retry_attempts: 0
               )

      assert permissions["can_trade"] == true
      assert permissions["can_transfer"] == false
    end

    test "the portfolio the key is scoped to comes back with it" do
      # A key is scoped to a portfolio, so "the account's balance" through this key is that
      # portfolio's — and this is where a caller finds out which.
      assert {:ok, permissions} =
               Rest.get_key_permissions(@credentials,
                 plug: responding(@permissions),
                 retry_attempts: 0
               )

      assert permissions["portfolio_uuid"] == "pf-1"
      assert permissions["portfolio_type"] == "DEFAULT"
    end

    test "a body without the permissions is unreadable" do
      assert {:error, :unexpected_response_shape} =
               Rest.get_key_permissions(@credentials, plug: responding(%{}), retry_attempts: 0)
    end
  end

  describe "get_server_time/1" do
    test "the venue's clock comes back as its own map, undiffed" do
      # The difference a caller cares about is against its own clock at the moment it asked;
      # computing it inside the package would hide the round trip in the number.
      body = %{"iso" => "2026-09-01T20:00:00Z", "epochSeconds" => "1788033600"}

      assert {:ok, time} = Rest.get_server_time(plug: responding(body), retry_attempts: 0)
      assert time["iso"] == "2026-09-01T20:00:00Z"
      assert time["epochSeconds"] == "1788033600"
    end

    test "it is a public GET at its own path" do
      me = self()

      assert {:ok, _time} =
               Rest.get_server_time(plug: capturing(%{"iso" => "x"}, me), retry_attempts: 0)

      assert_receive {:request, "GET", path}
      assert String.ends_with?(path, "/time")
    end
  end

  describe "test_connection/2 asks two different questions" do
    test "without credentials it reads the clock" do
      me = self()

      assert {:ok, result} =
               Rest.test_connection(nil, plug: capturing(%{"iso" => "x"}, me), retry_attempts: 0)

      assert result["reachable"] == true
      assert result["time"]["iso"] == "x"
      assert_receive {:request, "GET", path}
      assert String.ends_with?(path, "/time")
    end

    test "an empty credential map is the same as none" do
      me = self()

      assert {:ok, _result} =
               Rest.test_connection(%{}, plug: capturing(%{"iso" => "x"}, me), retry_attempts: 0)

      assert_receive {:request, "GET", path}
      assert String.ends_with?(path, "/time")
    end

    test "with credentials it reads the permissions" do
      me = self()

      assert {:ok, result} =
               Rest.test_connection(@credentials,
                 plug: capturing(@permissions, me),
                 retry_attempts: 0
               )

      assert result["reachable"] == true
      assert result["can_transfer"] == false
      assert_receive {:request, "GET", path}
      assert String.ends_with?(path, "/key_permissions")
    end

    test "a rejected credential is a refusal, not an unreachable venue" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"error" => "unauthorized"}))
      end

      assert {:error, _reason} =
               Rest.test_connection(@credentials, plug: plug, retry_attempts: 0)
    end
  end

  describe "the fake and the facade" do
    test "the fake's key cannot transfer, as a real one often cannot" do
      assert {:ok, %{"can_transfer" => false, "can_trade" => true}} = Fake.get_roles()
    end

    test "the fake splits test_connection the same way" do
      assert {:ok, %{"time" => _time}} = Fake.test_connection(nil, [])
      assert {:ok, %{"can_view" => true}} = Fake.test_connection(%{api_key: "k"}, [])
    end

    test "the facade delegates all three" do
      base = [credentials: @credentials, retry_attempts: 0]

      assert {:ok, _permissions} =
               DpExchange.Coinbase.get_roles(base ++ [plug: responding(@permissions)])

      assert {:ok, _time} =
               DpExchange.Coinbase.get_server_time(
                 plug: responding(%{"iso" => "x"}),
                 retry_attempts: 0
               )

      assert {:ok, _result} =
               DpExchange.Coinbase.test_connection(@credentials,
                 plug: responding(@permissions),
                 retry_attempts: 0
               )
    end
  end
end

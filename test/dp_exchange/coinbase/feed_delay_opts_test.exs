defmodule DpExchange.Coinbase.FeedDelayOptsTest do
  use ExUnit.Case, async: true

  alias DpExchange.Coinbase.Feed

  # The four retry/timeout/refresh delays reach `Process.send_after/3` long after `init/1`
  # returns. A value that is not a non-negative integer used to crash the feed inside a
  # `handle_info`, on every alias fetch; it now fails the start, as `shard_spacing_ms` does.

  @options ~w(subscribe_retry_delay_ms alias_map_retry_delay_ms alias_map_fetch_timeout_ms
              alias_map_refresh_ms)a

  defp feed_opts(extra) do
    base = [
      name: :"feed_#{System.unique_integer([:positive])}",
      alias_map_source: fn -> {:ok, %{}} end
    ]

    base ++ extra
  end

  for option <- @options do
    describe "#{option}" do
      test "a negative value is refused at start" do
        Process.flag(:trap_exit, true)

        assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
                 Feed.start_link(feed_opts([{unquote(option), -1}]))

        assert message =~ "#{unquote(option)} must be a non-negative integer"
      end

      test "a non-integer value is refused at start" do
        Process.flag(:trap_exit, true)

        assert {:error, {%ArgumentError{message: message}, _stacktrace}} =
                 Feed.start_link(feed_opts([{unquote(option), "30"}]))

        assert message =~ "#{unquote(option)} must be a non-negative integer"
      end

      test "nil takes the default and an integer is kept" do
        pid = start_supervised!({Feed, feed_opts([{unquote(option), nil}])})
        assert is_integer(:sys.get_state(pid)[unquote(option)])

        other = start_supervised!({Feed, feed_opts([{unquote(option), 600_000}])}, id: :other)
        assert :sys.get_state(other)[unquote(option)] == 600_000
      end
    end
  end
end

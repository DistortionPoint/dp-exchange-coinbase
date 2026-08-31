defmodule DpExchange.Coinbase.DeprecatedEndpointsTest do
  @moduledoc """
  Coinbase's INTX perpetuals endpoints are vendor-deprecated, and this package must never
  call one.

  ## Why a test rather than a note

  They are absent today. Nothing stopped them being added tomorrow, and the way this family
  has actually gone wrong is not a bad decision — it is a correct decision that quietly
  stopped being true while nothing watched. A note in a design document is read once; this
  fails the build.

  The six are `intx/balances/{portfolio_uuid}`, `intx/portfolio/{portfolio_uuid}`,
  `intx/positions/{portfolio_uuid}`, `intx/positions/{portfolio_uuid}/{symbol}`,
  `intx/allocate` and `intx/multi_asset_collateral`. Coinbase marks them deprecated in its
  own reference; a deprecated endpoint can change or vanish without a changelog entry, and
  a package built on one fails at a time nobody chose.

  This is the "no undocumented endpoints" rule one step earlier: **an endpoint the vendor
  has withdrawn support for is worse than one it never documented**, because it currently
  works.

  ## This test reads code, not prose

  The equivalent guard in `dp_exchange_gemini` first failed on a moduledoc that named an
  archived endpoint in order to explain why the package avoids it. That explanation is the
  most valuable thing in that file, so both guards strip documentation and comments before
  looking. A docstring cannot call an endpoint.
  """

  use ExUnit.Case, async: true

  @lib Path.join([__DIR__, "..", "..", "..", "lib"]) |> Path.expand()

  defp source_files, do: Path.wildcard(Path.join(@lib, "**/*.ex"))

  defp code_only(body) do
    body
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {acc, in_heredoc?} ->
      cond do
        in_heredoc? and String.contains?(line, ~s(""")) -> {acc, false}
        in_heredoc? -> {acc, true}
        String.contains?(line, ~s(""")) -> {acc, true}
        true -> {[String.replace(line, ~r/#.*$/, "") | acc], false}
      end
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  test "no code path constructs an INTX endpoint" do
    offenders =
      for path <- source_files(),
          code = code_only(File.read!(path)),
          String.contains?(code, "intx") do
        Path.relative_to(path, @lib)
      end

    assert offenders == [],
           """
           These files reference Coinbase's deprecated INTX endpoints in code:
           #{inspect(offenders)}

           All six are vendor-deprecated and are APPROVED-SKIP in the coverage plan. If
           Coinbase has un-deprecated them, delete this test deliberately and record what
           changed — do not weaken it.
           """
  end

  test "stripping documentation does not strip the whole file" do
    assert Enum.any?(source_files(), fn path ->
             path |> File.read!() |> code_only() |> String.contains?("defmodule")
           end)
  end
end

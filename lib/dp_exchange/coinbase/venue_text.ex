defmodule DpExchange.Coinbase.VenueText do
  @moduledoc """
  Bounds a value the venue sent before it is quoted into an error tuple. Internal.

  An error such as `{:invalid_decimal, :price, value}` or `{:preview_rejected, errs}` quotes
  what the venue said, and nothing limits how much that is: a reply whose field holds a
  megabyte of text put a megabyte into every caller's error tuple, into whatever they log,
  and, because a decoded string is a sub-binary of the whole response, kept the entire
  document alive for as long as the tuple lived.

  `bound/1` answers a value that is **small and detached** or says it was cut. Text longer
  than `#{1_024}` bytes is cut at that size (back to a whole UTF-8 character) and ends
  `"… (N bytes)"` with the full size, as `Core.HttpClient` marks a cut error body, so a cut
  never reads as complete. Any other term is kept as it is when its encoded size is at most
  `#{4_096}` bytes, and is otherwise replaced by a bounded `inspect/2` carrying the same size
  mark. Everything returned is a copy: nothing in it refers to the document it came from.
  """

  @max_text_bytes 1_024
  @max_term_bytes 4_096

  @doc """
  `value`, bounded and copied out of the document it was decoded from. Numbers, atoms and
  booleans are returned as they are.
  """
  @spec bound(term()) :: term()
  def bound(text) when is_binary(text) do
    if byte_size(text) <= @max_text_bytes, do: :binary.copy(text), else: cut(text)
  end

  def bound(value) when is_number(value) or is_atom(value), do: value

  def bound(term) do
    size = :erlang.external_size(term)

    if size <= @max_term_bytes do
      term |> :erlang.term_to_binary() |> :erlang.binary_to_term()
    else
      inspect(term, limit: 20, printable_limit: 256) <> "… (#{size} bytes)"
    end
  end

  # A byte prefix, trimmed back to a whole UTF-8 character; bounded at three trims, since a
  # character is at most four bytes and a prefix still invalid after that was never text.
  defp cut(text) do
    prefix = text |> binary_part(0, @max_text_bytes) |> valid_prefix(3)
    prefix <> "… (#{byte_size(text)} bytes)"
  end

  defp valid_prefix(prefix, trims_left) do
    if String.valid?(prefix) or trims_left == 0,
      do: prefix,
      else: valid_prefix(binary_part(prefix, 0, byte_size(prefix) - 1), trims_left - 1)
  end
end

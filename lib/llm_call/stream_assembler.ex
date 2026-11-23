defmodule LlmCall.StreamAssembler do
  @moduledoc """
  Turns streamed tool-call fragments into complete `LlmCall.ToolCall` values.

  Pure and protocol-neutral: it never executes a tool and never sends a result.
  Pending calls are keyed by `LlmCall.StreamEvent.index`, so several calls can
  complete independently and out of order.

  The core has no JSON decoder, so `new/1` takes one:

      assembler = LlmCall.StreamAssembler.new(json_decoder: &JSON.decode/1)

  Without a decoder, a call still arrives with its `raw_arguments` and an
  `arguments_error` of `:no_json_decoder`; it never arrives with invented
  arguments. The decoder's own message becomes the `reason` of
  `{:invalid_json, reason}`.
  """

  alias LlmCall.{StreamDelta, StreamEvent, ToolCall}

  @type decoder :: (String.t() -> {:ok, map()} | {:error, String.t()}) | nil

  @opaque t :: %__MODULE__{
            json_decoder: decoder(),
            calls: map()
          }

  @default_max_argument_bytes 8 * 1024 * 1024

  defstruct json_decoder: nil, max_argument_bytes: @default_max_argument_bytes, calls: %{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    decoder = Keyword.get(opts, :json_decoder)

    unless is_nil(decoder) or is_function(decoder, 1) do
      raise ArgumentError, "json_decoder must be a 1-arity function or nil"
    end

    max = Keyword.get(opts, :max_argument_bytes, @default_max_argument_bytes)

    unless is_integer(max) and max > 0 do
      raise ArgumentError, "max_argument_bytes must be a positive integer"
    end

    %__MODULE__{json_decoder: decoder, max_argument_bytes: max}
  end

  @spec feed(t(), StreamEvent.t()) :: {:ok, t(), [ToolCall.t()]}
  def feed(%__MODULE__{} = assembler, %StreamEvent{
        type: :tool_call_start,
        index: index,
        delta: %StreamDelta.ToolCall{} = delta
      }) do
    {:ok, put_pending(assembler, index, delta), []}
  end

  def feed(%__MODULE__{} = assembler, %StreamEvent{
        type: :tool_call_delta,
        index: index,
        delta: %StreamDelta.ToolCall{arguments: fragment}
      })
      when is_binary(fragment) do
    {:ok, append_arguments(assembler, index, fragment), []}
  end

  def feed(%__MODULE__{} = assembler, %StreamEvent{type: :tool_call_stop, index: index}) do
    finalize(assembler, [normalize_index(index)])
  end

  def feed(%__MODULE__{} = assembler, %StreamEvent{type: type})
      when type in [:content_stop, :message_stop] do
    finalize(assembler, pending_indexes(assembler))
  end

  def feed(%__MODULE__{} = assembler, %StreamEvent{}), do: {:ok, assembler, []}

  @spec finish(t()) :: {:ok, t(), [ToolCall.t()]}
  def finish(%__MODULE__{} = assembler), do: finalize(assembler, pending_indexes(assembler))

  defp put_pending(assembler, index, %StreamDelta.ToolCall{} = delta) do
    index = normalize_index(index)

    update_in(assembler.calls, fn calls ->
      entry = Map.get(calls, index, new_entry())

      Map.put(calls, index, %{entry | id: delta.id, name: delta.name})
    end)
  end

  # Fragments are kept as an iodata prefix and joined once, so a large argument
  # costs one pass rather than a quadratic append. `max_argument_bytes` bounds the
  # one accumulation path in the streaming stack that the SSE frame cap cannot see.
  defp append_arguments(assembler, index, fragment) do
    index = normalize_index(index)
    max = assembler.max_argument_bytes

    update_in(assembler.calls, fn calls ->
      entry = Map.get(calls, index, new_entry())
      room = max - entry.size

      Map.put(calls, index, add_fragment(entry, fragment, room))
    end)
  end

  defp new_entry, do: %{id: nil, name: nil, fragments: [], size: 0, overflow: false}

  defp add_fragment(%{overflow: true} = entry, _fragment, _room), do: entry

  defp add_fragment(entry, fragment, room) when byte_size(fragment) <= room do
    %{entry | fragments: [fragment | entry.fragments], size: entry.size + byte_size(fragment)}
  end

  defp add_fragment(_entry, _fragment, room) when room <= 0, do: %{new_entry() | overflow: true}

  defp add_fragment(entry, fragment, room) do
    %{entry | fragments: [binary_part(fragment, 0, room) | entry.fragments], overflow: true}
  end

  defp pending_indexes(%__MODULE__{calls: calls}), do: calls |> Map.keys() |> Enum.sort()

  defp finalize(%__MODULE__{} = assembler, indexes) do
    {completed, remaining} = pop_calls(assembler, indexes)

    {:ok, %__MODULE__{assembler | calls: remaining}, completed}
  end

  defp pop_calls(assembler, indexes) do
    {entries, remaining} = Map.split(assembler.calls, indexes)

    completed =
      entries
      |> Enum.sort_by(fn {index, _entry} -> index end)
      |> Enum.map(fn {index, entry} -> build_call(assembler, index, entry) end)

    {completed, remaining}
  end

  defp build_call(%__MODULE__{} = assembler, index, entry) do
    raw = entry.fragments |> Enum.reverse() |> IO.iodata_to_binary()

    cond do
      entry.overflow ->
        %ToolCall{
          id: entry.id,
          name: entry.name,
          arguments: nil,
          raw_arguments: raw,
          arguments_error: {:too_large, assembler.max_argument_bytes},
          index: index
        }

      raw == "" ->
        %ToolCall{
          id: entry.id,
          name: entry.name,
          arguments: %{},
          raw_arguments: nil,
          arguments_error: nil,
          index: index
        }

      true ->
        {arguments, arguments_error} = decode(assembler.json_decoder, raw)

        %ToolCall{
          id: entry.id,
          name: entry.name,
          arguments: arguments,
          raw_arguments: raw,
          arguments_error: arguments_error,
          index: index
        }
    end
  end

  defp decode(nil, _raw), do: {nil, :no_json_decoder}

  defp decode(decoder, raw) do
    case decoder.(raw) do
      {:ok, arguments} when is_map(arguments) ->
        {arguments, nil}

      {:ok, _not_an_object} ->
        {nil, {:invalid_json, "arguments are not a JSON object"}}

      {:error, reason} when is_binary(reason) ->
        {nil, {:invalid_json, reason}}

      {:error, _other} ->
        {nil, {:invalid_json, "arguments are not valid JSON"}}
    end
  end

  defp normalize_index(nil), do: 0
  defp normalize_index(index) when is_integer(index) and index >= 0, do: index
  defp normalize_index(_index), do: 0
end

defmodule LlmDialect.StreamAssembler do
  @moduledoc """
  Turns streamed tool-call fragments into complete `LlmDialect.ToolCall` values.

  Pure and protocol-neutral: it never executes a tool and never sends a result.
  Pending calls are keyed by `LlmDialect.StreamEvent.index`, so several calls can
  complete independently and out of order.

  The core has no JSON decoder, so `new/1` takes one:

      assembler = LlmDialect.StreamAssembler.new(json_decoder: &JSON.decode/1)

  Without a decoder, a call still arrives with its `raw_arguments` and an
  `arguments_error`; it never arrives with invented arguments.
  """

  alias LlmDialect.{StreamDelta, StreamEvent, ToolCall}

  @type decoder :: (String.t() -> {:ok, map()} | {:error, String.t()}) | nil

  @opaque t :: %__MODULE__{
            json_decoder: decoder(),
            calls: map()
          }

  defstruct json_decoder: nil, calls: %{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    decoder = Keyword.get(opts, :json_decoder)

    unless is_nil(decoder) or is_function(decoder, 1) do
      raise ArgumentError, "json_decoder must be a 1-arity function or nil"
    end

    %__MODULE__{json_decoder: decoder}
  end

  @spec feed(t(), StreamEvent.t()) :: {:ok, t(), [ToolCall.t()]}
  def feed(%__MODULE__{} = assembler, %StreamEvent{
        type: :tool_call_start,
        index: index,
        delta: delta
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
      Map.put(calls, index, %{
        id: delta.id,
        name: delta.name,
        arguments: get_in(calls, [index, :arguments]) || ""
      })
    end)
  end

  defp append_arguments(assembler, index, fragment) do
    index = normalize_index(index)

    update_in(assembler.calls, fn calls ->
      entry =
        calls
        |> Map.get(index, %{id: nil, name: nil, arguments: ""})
        |> Map.update!(:arguments, &(&1 <> fragment))

      Map.put(calls, index, entry)
    end)
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

  defp build_call(%__MODULE__{json_decoder: decoder}, index, entry) do
    case entry.arguments do
      "" ->
        %ToolCall{
          id: entry.id,
          name: entry.name,
          arguments: %{},
          raw_arguments: nil,
          arguments_error: nil,
          index: index
        }

      raw ->
        {arguments, arguments_error} = decode(decoder, raw)

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

  defp decode(nil, raw), do: {nil, {:invalid_json, raw}}

  defp decode(decoder, raw) do
    case decoder.(raw) do
      {:ok, arguments} when is_map(arguments) -> {arguments, nil}
      {:ok, _not_a_map} -> {nil, {:invalid_json, raw}}
      {:error, reason} when is_binary(reason) -> {nil, {:invalid_json, reason}}
      {:error, _other} -> {nil, {:invalid_json, raw}}
    end
  end

  defp normalize_index(nil), do: 0
  defp normalize_index(index) when is_integer(index), do: index
end

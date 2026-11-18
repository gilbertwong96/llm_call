defmodule LlmCall.SSE do
  @moduledoc """
  Server-sent event framing.

  The transport hands over body chunks; this module turns them into `data`
  payloads. Only `data:` matters to the codecs — `event:`, `id:`, `retry:`, and
  comment lines are ignored — and multiple `data:` lines in one event are joined
  with a newline, as the SSE specification requires.

  A chunk may split a line or an event; the remainder is kept in `buffer` until
  the next chunk. `flush/1` returns a trailing event that arrived without its
  terminating blank line, and an empty buffer when the body ended cleanly.

      {payloads, state} = SSE.parse(state, chunk)
  """

  @type t :: %__MODULE__{buffer: String.t()}

  defstruct buffer: ""

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Parses one body chunk into the events it completes."
  @spec parse(t(), binary()) :: {[String.t()], t()}
  def parse(%__MODULE__{buffer: buffer}, chunk) when is_binary(chunk) do
    data = buffer <> normalise(chunk)
    blocks = String.split(data, "\n\n")
    {complete, [rest]} = Enum.split(blocks, -1)

    payloads =
      complete
      |> Enum.map(&event_payload/1)
      |> Enum.reject(&is_nil/1)

    {payloads, %__MODULE__{buffer: rest}}
  end

  @doc """
  Returns the event left in the buffer at end of body, if any.

  Providers terminate events with a blank line, so this is normally empty; it
  exists so a truncated stream does not lose its last event.
  """
  @spec flush(t()) :: {[String.t()], t()}
  def flush(%__MODULE__{buffer: ""}), do: {[], new()}

  def flush(%__MODULE__{buffer: buffer}) do
    case event_payload(buffer) do
      nil -> {[], new()}
      payload -> {[payload], new()}
    end
  end

  defp normalise(chunk), do: String.replace(chunk, "\r\n", "\n")

  defp event_payload(block) do
    data =
      block
      |> String.split("\n")
      |> Enum.reduce([], fn line, acc ->
        case data_line(line) do
          nil -> acc
          payload -> [payload | acc]
        end
      end)
      |> Enum.reverse()

    case data do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  defp data_line("data:" <> rest), do: String.replace_prefix(rest, " ", "")
  defp data_line(_line), do: nil
end

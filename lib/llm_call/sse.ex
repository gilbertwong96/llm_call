defmodule LlmCall.SSE do
  @moduledoc """
  Server-sent event framing.

  The transport hands over body chunks; this module turns them into `data`
  payloads. Multiple `data:` lines in one event are joined with a newline, as the
  SSE specification requires. `event:` and comment lines are dropped, because a
  codec reads the event name out of the payload.

  `retry:` is the server's reconnection hint. It is kept on the state in
  `retry_ms` rather than dropped, so a caller that owns reconnection policy can
  read it; the library never reconnects a stream itself.

  A chunk may split a line or an event; the remainder is kept in `buffer` until
  the next chunk. `flush/1` returns a trailing event that arrived without its
  terminating blank line, and an empty buffer when the body ended cleanly.

  A peer that never sends the blank line ending an event would grow the buffer
  without bound, so a pending event is capped at `@max_buffer` bytes. Exceeding it
  raises `LlmCall.SSE.Error` rather than truncating, because a truncated event
  would decode as a shorter payload that still looks valid.

      {payloads, state} = SSE.parse(state, chunk)
      state.retry_ms
  """

  @type t :: %__MODULE__{
          buffer: String.t(),
          cr_pending?: boolean(),
          retry_ms: non_neg_integer() | nil
        }

  defstruct buffer: "", cr_pending?: false, retry_ms: nil

  # Generous next to a real payload: the largest single event a provider sends is
  # a tool call or a reasoning block, far below this.
  @max_buffer 1_048_576

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Parses one body chunk into the events it completes."
  @spec parse(t(), binary()) :: {[String.t()], t()}
  def parse(%__MODULE__{buffer: buffer, cr_pending?: cr_pending?} = state, chunk)
      when is_binary(chunk) do
    raw = buffer <> join_split_crlf(chunk, cr_pending?)
    blocks = raw |> normalise() |> String.split("\n\n")
    {complete, [rest]} = Enum.split(blocks, -1)

    payloads =
      complete
      |> Enum.map(&event_payload/1)
      |> Enum.reject(&is_nil/1)

    retry_ms = complete |> Enum.reduce(state.retry_ms, &retry_hint/2)

    if byte_size(rest) > @max_buffer do
      raise LlmCall.SSE.Error,
        message:
          "an SSE event has exceeded #{@max_buffer} bytes without its terminating blank line"
    end

    {payloads, %__MODULE__{buffer: rest, cr_pending?: cr_pending?(raw, rest), retry_ms: retry_ms}}
  end

  @doc """
  Returns the event left in the buffer at end of body, if any.

  Providers terminate events with a blank line, so this is normally empty; it
  exists so a truncated stream does not lose its last event.
  """
  @spec flush(t()) :: {[String.t()], t()}
  def flush(%__MODULE__{buffer: "", retry_ms: retry_ms}),
    do: {[], %__MODULE__{retry_ms: retry_ms}}

  def flush(%__MODULE__{buffer: buffer, retry_ms: retry_ms}) do
    retry_ms = retry_hint(buffer, retry_ms)

    case event_payload(buffer) do
      nil -> {[], %__MODULE__{retry_ms: retry_ms}}
      payload -> {[payload], %__MODULE__{retry_ms: retry_ms}}
    end
  end

  defp normalise(chunk) do
    chunk
    |> String.replace("\r\n", "\n")
    |> String.replace("\r", "\n")
  end

  # `normalise/1` turns a lone `\r` into `\n` before the buffer is stored, so a
  # CRLF split across chunks would arrive as `\n\n` and end the event early.
  defp join_split_crlf("\n" <> rest, true), do: rest
  defp join_split_crlf(chunk, _cr_pending?), do: chunk

  defp cr_pending?(raw, rest) do
    ends_with_cr?(raw) and String.ends_with?(rest, "\n")
  end

  defp ends_with_cr?(raw) when byte_size(raw) > 0, do: :binary.last(raw) == ?\r
  defp ends_with_cr?(_raw), do: false

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
      [""] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  # `retry: <milliseconds>` is a field of the preceding event, so it is read from
  # the whole block. A malformed value is ignored, leaving the previous hint.
  defp retry_hint(block, previous) do
    block
    |> String.split("\n")
    |> Enum.reduce(previous, fn
      "retry:" <> rest, _acc ->
        case rest |> String.trim() |> Integer.parse() do
          {ms, ""} when ms >= 0 -> ms
          _other -> previous
        end

      _line, acc ->
        acc
    end)
  end

  defp data_line("data:" <> rest), do: String.replace_prefix(rest, " ", "")
  defp data_line(_line), do: nil
end

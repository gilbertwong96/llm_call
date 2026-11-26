defmodule LlmCall.EventStream do
  @moduledoc """
  `application/vnd.amazon.eventstream` framing.

  Bedrock's `ConverseStream` does not answer with server-sent events: the body is a
  sequence of binary frames, each carrying its own length, headers and CRC-32. This
  module turns body chunks into `LlmCall.EventStream.Message` structs; it does not
  know what the payload means and does not decode JSON.

  ## Frame layout

      +---------------------------------+---------------------------------+
      | total length     (4, big endian)| headers length   (4, big endian)|
      +---------------------------------+---------------------------------+
      | prelude CRC-32   (4)            |  CRC of the eight bytes above   |
      +-------------------------------------------------------------------+
      | headers          (headers length bytes)                           |
      +-------------------------------------------------------------------+
      | payload          (total - 16 - headers length bytes)              |
      +-------------------------------------------------------------------+
      | message CRC-32   (4)            |  CRC of every byte above        |
      +-------------------------------------------------------------------+

  Both checksums are CRC-32 as `:erlang.crc32/1` computes it — the same polynomial
  as zlib, not CRC-32C. They are the reason this format is safe to parse
  incrementally: a corrupted length would otherwise be used as an offset into the
  next frame, and a corrupted payload would decode as a shorter message that still
  looks valid. The prelude is checked **before** its length fields are used.

  ## Headers

  Each header is a one-byte name length, the name, a one-byte value type, then the
  value: `0`/`1` boolean, `2` byte, `3` short, `4` integer, `5` long, `6` byte array,
  `7` string, `8` timestamp, `9` UUID. See `LlmCall.EventStream.Message` for how each
  becomes an Elixir value. An unknown type is an error rather than a skipped field,
  because skipping it would misplace the next header.

  ## Buffering

  A chunk may split a frame at any byte; the remainder stays in `buffer` until the
  next chunk. A frame is capped at 16 MiB, and the cap is applied to the length the
  frame *claims*, before the bytes arrive, so a peer cannot make this process buffer
  gigabytes by announcing them.

  `finish/1` refuses a buffer that still holds bytes: a body that ends mid-frame is a
  truncated stream, not a complete one. That is the same rule §12 applies to SSE.

      {messages, state} = EventStream.parse(EventStream.new(), chunk)
      :ok = EventStream.finish(state)
  """

  alias LlmCall.EventStream.{Error, Message}

  # Prelude (8) plus its CRC (4): the bytes needed before the lengths can be trusted.
  @prelude 12

  # Prelude + prelude CRC + message CRC. The smallest possible frame is this, empty.
  @overhead 16

  # A Converse delta is a few kilobytes. The cap exists so a bogus length cannot ask
  # this process to hold a large buffer before the checksum has a chance to reject it.
  @max_frame 16_777_216

  @type t :: %__MODULE__{buffer: binary()}

  defstruct buffer: ""

  @doc "A decoder with an empty buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Appends a body chunk and returns the messages it completes.

  Raises `LlmCall.EventStream.Error` when the bytes cannot be a frame: a bad
  checksum, an impossible length, an unknown header type, or a header that runs past
  its block. A chunk that ends inside a frame is not an error — the frame completes on
  a later chunk.
  """
  @spec parse(t(), binary()) :: {[Message.t()], t()}
  def parse(%__MODULE__{} = state, chunk) when is_binary(chunk) do
    frames(%__MODULE__{state | buffer: state.buffer <> chunk}, [])
  end

  @doc """
  Asserts that the body ended on a frame boundary.

  A body that stops mid-frame lost the rest of a message, which is a truncated
  stream rather than a shorter one.
  """
  @spec finish(t()) :: :ok
  def finish(%__MODULE__{buffer: ""}), do: :ok

  def finish(%__MODULE__{buffer: buffer}) do
    raise Error,
      message: "the body ended after #{byte_size(buffer)} bytes of a truncated frame"
  end

  defp frames(%__MODULE__{buffer: <<total::32, _::binary>> = buffer} = state, acc) do
    cond do
      total > @max_frame ->
        raise Error,
          message: "a frame exceeds the #{@max_frame}-byte cap (#{total} bytes claimed)"

      total < @overhead ->
        raise Error,
          message: "total length #{total} is below the #{@overhead}-byte frame overhead"

      byte_size(buffer) < @prelude ->
        {Enum.reverse(acc), state}

      true ->
        <<_total::32, headers_length::32, prelude_crc::32, _::binary>> = buffer

        if :erlang.crc32(binary_part(buffer, 0, 8)) != prelude_crc do
          raise Error, message: "prelude checksum mismatch: the frame header is corrupt"
        end

        if headers_length > total - @overhead do
          raise Error,
            message: "headers length #{headers_length} does not fit a #{total}-byte frame"
        end

        if byte_size(buffer) < total,
          do: {Enum.reverse(acc), state},
          else: take_frame(state, buffer, total, headers_length, acc)
    end
  end

  defp frames(%__MODULE__{} = state, acc), do: {Enum.reverse(acc), state}

  defp take_frame(%__MODULE__{} = state, buffer, total, headers_length, acc) do
    payload_length = total - @overhead - headers_length
    frame = binary_part(buffer, 0, total)

    <<_total::32, ^headers_length::32, _prelude_crc::32, headers::binary-size(^headers_length),
      payload::binary-size(^payload_length), crc::32>> =
      frame

    if :erlang.crc32(binary_part(frame, 0, total - 4)) != crc do
      raise Error, message: "message checksum mismatch: the frame body is corrupt"
    end

    message = %Message{headers: decode_headers(headers), payload: payload}
    rest = binary_part(buffer, total, byte_size(buffer) - total)
    frames(%__MODULE__{state | buffer: rest}, [message | acc])
  end

  defp decode_headers(headers), do: decode_headers(headers, %{})

  defp decode_headers(<<>>, acc), do: acc

  defp decode_headers(<<name_length::8, rest::binary>>, acc) do
    {name, rest} = take(rest, name_length, "header name")
    {type, rest} = value_type(rest)
    {value, rest} = header_value(type, rest)

    decode_headers(rest, Map.put(acc, utf8(name, "header name"), value))
  end

  defp value_type(<<type::8, rest::binary>>), do: {type, rest}

  defp value_type(_rest),
    do: raise(Error, message: "a header ends without its value type")

  defp header_value(0, rest), do: {true, rest}
  defp header_value(1, rest), do: {false, rest}
  defp header_value(2, rest), do: signed(rest, 8, "byte header")
  defp header_value(3, rest), do: signed(rest, 16, "short header")
  defp header_value(4, rest), do: signed(rest, 32, "integer header")
  defp header_value(5, rest), do: signed(rest, 64, "long header")
  defp header_value(8, rest), do: signed(rest, 64, "timestamp header")
  defp header_value(9, rest), do: take(rest, 16, "uuid header value")

  defp header_value(6, rest) do
    {size, rest} = unsigned(rest, 16, "byte-array header length")
    take(rest, size, "byte-array header value")
  end

  defp header_value(7, rest) do
    {size, rest} = unsigned(rest, 16, "string header length")
    {value, rest} = take(rest, size, "string header value")
    {utf8(value, "header value"), rest}
  end

  defp header_value(type, _rest) do
    raise Error,
      message: "header type #{type} is not one the event-stream specification defines"
  end

  defp signed(binary, bits, what) do
    {bytes, rest} = take(binary, div(bits, 8), what)
    <<value::signed-big-size(^bits)>> = bytes
    {value, rest}
  end

  defp unsigned(binary, bits, what) do
    {bytes, rest} = take(binary, div(bits, 8), what)
    <<value::big-size(^bits)>> = bytes
    {value, rest}
  end

  defp take(binary, size, _what) when byte_size(binary) >= size do
    <<taken::binary-size(^size), rest::binary>> = binary
    {taken, rest}
  end

  defp take(binary, size, what) do
    raise Error,
      message:
        "a #{what} of #{size} bytes runs past its block " <>
          "(#{byte_size(binary)} bytes left)"
  end

  defp utf8(binary, what) do
    if String.valid?(binary),
      do: binary,
      else: raise(Error, message: "a #{what} is not valid UTF-8")
  end
end

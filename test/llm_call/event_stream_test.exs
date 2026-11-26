defmodule LlmCall.EventStreamTest do
  use ExUnit.Case, async: true

  alias LlmCall.EventStream
  alias LlmCall.EventStream.{Error, Message}
  alias LlmCall.Fixtures.EventStream, as: Frames

  defp parse!(bytes) do
    {messages, state} = EventStream.parse(EventStream.new(), bytes)
    assert EventStream.finish(state) == :ok
    messages
  end

  # The `@smithy/eventstream-codec` fixtures are the assertion: if the decoder agreed
  # with itself and not with the AWS SDK, these bytes are what catches it.
  test "decodes the frame Bedrock sends first" do
    assert [%Message{headers: headers, payload: payload}] = parse!(Frames.frame(:message_start))

    assert headers == %{
             ":message-type" => "event",
             ":event-type" => "messageStart",
             ":content-type" => "application/json"
           }

    assert payload == ~s({"role":"assistant"})
  end

  test "returns every frame a chunk completes, in order" do
    chunk =
      Frames.frame(:message_start) <>
        Frames.frame(:content_block_delta) <> Frames.frame(:content_block_delta)

    assert [first, second, third] = parse!(chunk)
    assert first.headers[":event-type"] == "messageStart"
    assert second.payload == ~s({"delta":{"text":"Hello"},"contentBlockIndex":0})
    assert third == second
  end

  test "a frame split at any offset completes on the next chunk" do
    frame = Frames.frame(:content_block_delta)
    size = byte_size(frame)

    for split <- 1..(size - 1) do
      state = EventStream.new()
      {none, state} = EventStream.parse(state, binary_part(frame, 0, split))
      assert none == []

      rest = binary_part(frame, split, size - split)
      {[message], state} = EventStream.parse(state, rest)
      assert message.payload == ~s({"delta":{"text":"Hello"},"contentBlockIndex":0})
      assert EventStream.finish(state) == :ok
    end
  end

  test "a chunk that ends inside the prelude keeps the remainder" do
    {_, state} = EventStream.parse(EventStream.new(), Frames.frame(:split_first_half))

    assert {[message], state} =
             EventStream.parse(state, Frames.frame(:split_second_half))

    assert message.payload == ~s({"delta":{"text":"split"}})
    assert EventStream.finish(state) == :ok
  end

  # Bedrock reports a throttled or failed stream as a frame, so this is not an error
  # case for the framer: the codec decides what an exception frame means.
  test "an exception frame is a frame like any other" do
    assert [message] = parse!(Frames.frame(:exception))

    assert message.headers[":message-type"] == "exception"
    assert message.headers[":exception-type"] == "throttlingException"
    assert message.payload == ~s({"message":"Too many requests"})
  end

  test "every header value type decodes to an Elixir value" do
    assert [%Message{headers: headers, payload: "payload"}] =
             parse!(Frames.frame(:every_header_type))

    assert headers == %{
             "bool_true" => true,
             "bool_false" => false,
             "byte" => -7,
             "short" => -300,
             "integer" => -70_000,
             "long" => 1_234_567_890_123,
             "binary" => <<0x00, 0xFF, 0x7F>>,
             "string" => "héllo",
             "timestamp" => 1_700_000_000_000,
             "uuid" =>
               <<0x01, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF, 0x01, 0x23, 0x45, 0x67, 0x89,
                 0xAB, 0xCD, 0xEF>>
           }
  end

  test "the payload stays bytes" do
    assert [%Message{payload: <<0x00, 0xFF, 0xFE, 0x80>>}] = parse!(Frames.frame(:binary_payload))
  end

  test "a frame with no headers and no payload" do
    assert [%Message{headers: %{}, payload: ""}] = parse!(Frames.frame(:empty))
  end

  test "an empty chunk completes nothing" do
    assert {[], state} = EventStream.parse(EventStream.new(), "")
    assert EventStream.finish(state) == :ok
  end

  # The checksums exist because a corrupted length would otherwise be used as an
  # offset, and a corrupted payload would decode as a shorter but valid message.
  test "a corrupted payload is refused by the message checksum" do
    frame = Frames.frame(:message_start)
    size = byte_size(frame)
    corrupted = binary_part(frame, 0, size - 5) <> "X" <> binary_part(frame, size - 4, 4)

    assert_raise Error, ~r/message checksum/, fn -> parse!(corrupted) end
  end

  # The prelude checksum is checked before its lengths are used, so a corrupted length
  # is refused rather than becoming an offset into the next frame. The corruption has to
  # be a plausible length: an impossible one is caught earlier, by the cap.
  test "a corrupted length is refused by the prelude checksum before it is used" do
    frame = Frames.frame(:message_start)
    <<_::32, rest::binary>> = frame
    corrupted = <<128::32, rest::binary>>

    assert_raise Error, ~r/prelude checksum/, fn -> parse!(corrupted) end
  end

  test "a frame that claims more bytes than the cap is refused without waiting for them" do
    <<_total::32, headers_length::32, _::binary>> = Frames.frame(:message_start)
    prelude = <<0xFFFFFFFF::32, headers_length::32>>

    assert_raise Error, ~r/exceeds/, fn ->
      EventStream.parse(EventStream.new(), <<prelude::binary, :erlang.crc32(prelude)::32>>)
    end
  end

  test "a total length below the frame overhead is refused" do
    assert_raise Error, ~r/total length/, fn -> parse!(frame_with(total: 15)) end
  end

  test "a headers length that cannot fit the frame is refused" do
    assert_raise Error, ~r/headers length/, fn ->
      parse!(frame_with(headers_length: 4))
    end
  end

  test "a header that runs past the header block is refused" do
    assert_raise Error, ~r/header name/, fn -> parse!(frame_with(headers: <<9, "ab">>)) end
  end

  test "an unknown header value type is refused, not dropped" do
    assert_raise Error, ~r/header type/, fn ->
      parse!(frame_with(headers: <<2, "ab", 10>>))
    end
  end

  test "a header string that is not UTF-8 is refused" do
    assert_raise Error, ~r/UTF-8/, fn ->
      parse!(frame_with(headers: <<2, "ab", 7, 1::16, 0xFF>>))
    end
  end

  test "a body that ends mid-frame is a truncated stream" do
    frame = Frames.frame(:message_start)
    {[], state} = EventStream.parse(EventStream.new(), binary_part(frame, 0, 20))

    assert_raise Error, ~r/truncated/, fn -> EventStream.finish(state) end
  end

  # A frame this test builds itself, so a malformed prelude or header block can be
  # presented to the decoder; the checksums are real, so the failure under test is the
  # one named, not a checksum.
  defp frame_with(options) do
    payload = Keyword.get(options, :payload, "")
    headers = Keyword.get(options, :headers, "")
    headers_length = Keyword.get(options, :headers_length, byte_size(headers))
    total = Keyword.get(options, :total, 16 + byte_size(headers) + byte_size(payload))

    prelude = <<total::32, headers_length::32>>
    prefixed = <<prelude::binary, :erlang.crc32(prelude)::32, headers::binary, payload::binary>>
    <<prefixed::binary, :erlang.crc32(prefixed)::32>>
  end
end

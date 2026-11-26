defmodule LlmCall.Dialect.Bedrock.ConverseStreamTest do
  use ExUnit.Case, async: true

  alias LlmCall.Dialect.Bedrock.Converse
  alias LlmCall.EventStream.Message, as: Frame
  alias LlmCall.Fixtures.EventStream, as: Frames

  alias LlmCall.{
    Config,
    Content,
    Error,
    Request,
    StreamDelta,
    StreamEvent,
    Usage
  }

  alias LlmCall.TestHTTPServer, as: TestHTTP

  defmodule Provider do
    @moduledoc false

    use LlmCall.Provider,
      base_url: "http://127.0.0.1:1",
      auth: :none,
      codecs: [chat: Converse]
  end

  defp request do
    %Request{
      model: "m",
      messages: [%LlmCall.Message{role: :user, content: [%Content.Text{text: "hi"}]}]
    }
  end

  defp start_state do
    {:ok, state} = Converse.init_stream(request(), %Config{})
    state
  end

  # A framed message as the transport delivers it: the headers say which event it is,
  # the payload is JSON.
  defp frame(event_type, payload) do
    %Frame{
      headers: %{":message-type" => "event", ":event-type" => event_type},
      payload: JSON.encode!(payload)
    }
  end

  defp exception(exception_type, payload) do
    %Frame{
      headers: %{":message-type" => "exception", ":exception-type" => exception_type},
      payload: JSON.encode!(payload)
    }
  end

  defp decode!(framed, state) do
    assert {:ok, events, state} = Converse.decode_stream_event(framed, %Config{}, state)
    {events, state}
  end

  test "the codec declares the event-stream framing and a streaming endpoint" do
    assert Converse.stream_framing() == LlmCall.EventStream
    assert %{streaming: true} = Converse.capabilities(request(), %Config{})

    assert {:ok, %{path: "/model/m/converse-stream", body: body}} =
             Converse.encode_request(%{request() | stream: true}, %Config{})

    # The endpoint carries the flag, so the body must not.
    refute Map.has_key?(body, "stream")

    assert {:ok, %{path: "/model/m/converse"}} = Converse.encode_request(request(), %Config{})
  end

  test "messageStart opens the message" do
    assert {[%StreamEvent{type: :message_start}], _state} =
             decode!(frame("messageStart", %{"role" => "assistant"}), start_state())
  end

  test "a text block opens, streams deltas, and closes" do
    {[open], state} =
      decode!(
        frame("contentBlockStart", %{"start" => %{}, "contentBlockIndex" => 0}),
        start_state()
      )

    assert %StreamEvent{type: :content_start, index: 0} = open

    assert {[%StreamEvent{type: :text_delta, index: 0, delta: %StreamDelta.Text{text: "Hello"}}],
            state} =
             decode!(
               frame("contentBlockDelta", %{
                 "delta" => %{"text" => "Hello"},
                 "contentBlockIndex" => 0
               }),
               state
             )

    assert {[%StreamEvent{type: :content_stop, index: 0}], _state} =
             decode!(frame("contentBlockStop", %{"contentBlockIndex" => 0}), state)
  end

  test "a tool block carries its id and name, then its argument fragments, then closes" do
    {[open], state} =
      decode!(
        frame("contentBlockStart", %{
          "start" => %{"toolUse" => %{"toolUseId" => "tu_1", "name" => "get"}},
          "contentBlockIndex" => 1
        }),
        start_state()
      )

    assert %StreamEvent{type: :tool_call_start, index: 1} = open

    assert %StreamDelta.ToolCall{id: "tu_1", name: "get", index: 1, arguments: nil} = open.delta

    assert {[%StreamEvent{type: :tool_call_delta, index: 1, delta: delta}], state} =
             decode!(
               frame("contentBlockDelta", %{
                 "delta" => %{"toolUse" => %{"input" => ~s({"a":)}},
                 "contentBlockIndex" => 1
               }),
               state
             )

    # A fragment is a fragment: the codec does not try to decode half a document.
    assert %StreamDelta.ToolCall{arguments: ~s({"a":)} = delta

    assert {[%StreamEvent{type: :tool_call_stop, index: 1}], _state} =
             decode!(frame("contentBlockStop", %{"contentBlockIndex" => 1}), state)
  end

  test "reasoning text and its signature are thinking deltas" do
    assert {[%StreamEvent{type: :thinking_delta, delta: %StreamDelta.Thinking{text: "hm"}}],
            _state} =
             decode!(
               frame("contentBlockDelta", %{
                 "delta" => %{"reasoningContent" => %{"text" => "hm"}},
                 "contentBlockIndex" => 0
               }),
               start_state()
             )

    assert {[%StreamEvent{type: :thinking_delta, delta: %StreamDelta.Thinking{signature: "sig"}}],
            _state} =
             decode!(
               frame("contentBlockDelta", %{
                 "delta" => %{"reasoningContent" => %{"signature" => "sig"}},
                 "contentBlockIndex" => 0
               }),
               start_state()
             )
  end

  # Bedrock sends usage *after* messageStop, so the terminator cannot be emitted there:
  # the IR would see a message_stop followed by another event. The terminator is
  # flushed when the body ends, as Gemini's does.
  test "messageStop is the stop reason; the terminator is flushed at end of body" do
    assert {[
              %StreamEvent{
                type: :message_delta,
                delta: %StreamDelta.MessageDelta{stop_reason: :end_turn}
              }
            ], state} =
             decode!(frame("messageStop", %{"stopReason" => "end_turn"}), start_state())

    assert {:ok, [%StreamEvent{type: :message_stop}], _state} =
             Converse.finish_stream(state, %Config{})
  end

  test "metadata carries the usage, and keeps the stop reason it arrived after" do
    {[_stop], state} = decode!(frame("messageStop", %{"stopReason" => "tool_use"}), start_state())

    assert {[%StreamEvent{type: :message_delta, delta: delta}], state} =
             decode!(
               frame("metadata", %{
                 "usage" => %{
                   "inputTokens" => 3,
                   "outputTokens" => 5,
                   "totalTokens" => 8,
                   "cacheReadInputTokens" => 1
                 },
                 "metrics" => %{"latencyMs" => 120}
               }),
               state
             )

    assert %StreamDelta.MessageDelta{
             stop_reason: :tool_calls,
             usage: %Usage{
               input_tokens: 3,
               output_tokens: 5,
               total_tokens: 8,
               cache_read_tokens: 1
             }
           } = delta

    assert {:ok, [%StreamEvent{type: :message_stop}], _state} =
             Converse.finish_stream(state, %Config{})
  end

  test "a stream that ends without messageStop is an invalid response" do
    assert {:error, %Error{kind: :invalid_response, message: message}} =
             Converse.finish_stream(start_state(), %Config{})

    assert message =~ "messageStop"
  end

  test "an exception frame is a provider error, not an event" do
    assert {:error, %Error{kind: :provider, message: "Too many requests"}} =
             Converse.decode_stream_event(
               exception("throttlingException", %{"message" => "Too many requests"}),
               %Config{},
               start_state()
             )
  end

  # `:message-type: error` is the framing's own failure channel, and its payload is the
  # message text rather than JSON. Treating it as an event would surface a connection
  # failure as a data frame.
  test "a framing error message is a provider error, not a raw event" do
    message = %Frame{
      headers: %{
        ":message-type" => "error",
        ":error-code" => "InternalFailure",
        ":error-message" => "the connection failed"
      },
      payload: "the connection failed"
    }

    assert {:error, %Error{kind: :provider, code: "InternalFailure", message: message_text}} =
             Converse.decode_stream_event(message, %Config{}, start_state())

    assert message_text == "the connection failed"
  end

  test "an error message without a message header falls back to its payload" do
    message = %Frame{
      headers: %{":message-type" => "error"},
      payload: "boom"
    }

    assert {:error, %Error{kind: :provider, message: "boom"}} =
             Converse.decode_stream_event(message, %Config{}, start_state())
  end

  test "an unknown event is kept raw rather than dropped" do
    assert {[%StreamEvent{type: :message_delta, delta: %StreamDelta.Raw{data: data}}], _state} =
             decode!(frame("futureEvent", %{"future" => true}), start_state())

    assert data == %{"future" => true}
  end

  # End to end through the public API, on frames produced by the Smithy codec.
  test "a real stream yields the IR events in order" do
    TestHTTP.start()
    on_exit(&TestHTTP.stop/0)

    TestHTTP.put_events([
      {:status, 200},
      {:data, Frames.frame(:message_start)},
      {:data, Frames.frame(:content_block_delta)},
      {:data, Frames.frame(:message_stop)},
      {:data, Frames.frame(:metadata)}
    ])

    client = Provider.client(base_url: TestHTTP.url())
    assert {:ok, stream} = LlmCall.stream(client, request())

    assert [
             %StreamEvent{type: :message_start},
             %StreamEvent{type: :text_delta, delta: %StreamDelta.Text{text: "Hello"}},
             %StreamEvent{
               type: :message_delta,
               delta: %StreamDelta.MessageDelta{stop_reason: :end_turn}
             },
             %StreamEvent{type: :message_delta, delta: %StreamDelta.MessageDelta{usage: usage}},
             %StreamEvent{type: :message_stop}
           ] = Enum.to_list(stream)

    assert %Usage{input_tokens: 3, output_tokens: 5, total_tokens: 8} = usage
  end
end

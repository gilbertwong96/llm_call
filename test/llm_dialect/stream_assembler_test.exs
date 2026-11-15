defmodule LlmDialect.StreamAssemblerTest do
  use ExUnit.Case, async: true

  alias LlmDialect.StreamAssembler
  alias LlmDialect.{StreamDelta, StreamEvent, StreamState, ToolCall}

  defp decoder(input) do
    case :json.decode(input) do
      value when is_map(value) -> {:ok, value}
      _ -> {:error, "not an object"}
    end
  rescue
    _ -> {:error, "invalid json"}
  end

  defp start(index, id, name) do
    %StreamEvent{
      type: :tool_call_start,
      index: index,
      delta: %StreamDelta.ToolCall{id: id, name: name, index: index}
    }
  end

  defp delta(index, fragment) do
    %StreamEvent{
      type: :tool_call_delta,
      index: index,
      delta: %StreamDelta.ToolCall{arguments: fragment, index: index}
    }
  end

  defp stop(index),
    do: %StreamEvent{
      type: :tool_call_stop,
      index: index,
      delta: %StreamDelta.ToolCall{index: index}
    }

  test "assembles fragmented arguments into a decoded map" do
    assembler = StreamAssembler.new(json_decoder: &decoder/1)

    {:ok, assembler, []} = StreamAssembler.feed(assembler, start(0, "call_1", "get_weather"))
    {:ok, assembler, []} = StreamAssembler.feed(assembler, delta(0, ~s({"city":)))
    {:ok, assembler, []} = StreamAssembler.feed(assembler, delta(0, ~s("Oslo"})))
    {:ok, assembler, [call]} = StreamAssembler.feed(assembler, stop(0))

    assert call == %ToolCall{
             id: "call_1",
             name: "get_weather",
             arguments: %{"city" => "Oslo"},
             raw_arguments: ~s({"city":"Oslo"}),
             arguments_error: nil,
             index: 0
           }

    assert {:ok, _assembler, []} = StreamAssembler.finish(assembler)
  end

  test "tool_call_stop finalizes the call" do
    assembler = StreamAssembler.new(json_decoder: &decoder/1)

    {:ok, assembler, []} = StreamAssembler.feed(assembler, start(0, "call_1", "f"))
    {:ok, assembler, []} = StreamAssembler.feed(assembler, delta(0, ~s({"a":1})))
    {:ok, assembler, [call]} = StreamAssembler.feed(assembler, stop(0))

    assert call.arguments == %{"a" => 1}
    assert {:ok, _assembler, []} = StreamAssembler.finish(assembler)
  end

  test "multiple calls finalize in index order" do
    assembler = StreamAssembler.new(json_decoder: &decoder/1)

    {:ok, assembler, []} = StreamAssembler.feed(assembler, start(1, "call_b", "b"))
    {:ok, assembler, []} = StreamAssembler.feed(assembler, delta(1, ~s({"x":2})))
    {:ok, assembler, []} = StreamAssembler.feed(assembler, start(0, "call_a", "a"))
    {:ok, assembler, []} = StreamAssembler.feed(assembler, delta(0, ~s({"x":1})))
    {:ok, _assembler, calls} = StreamAssembler.feed(assembler, %StreamEvent{type: :message_stop})

    assert Enum.map(calls, & &1.id) == ["call_a", "call_b"]
  end

  test "content_stop finalizes pending calls" do
    assembler = StreamAssembler.new(json_decoder: &decoder/1)

    {:ok, assembler, []} = StreamAssembler.feed(assembler, start(0, "call_1", "f"))
    {:ok, assembler, []} = StreamAssembler.feed(assembler, delta(0, ~s({})))

    {:ok, _assembler, [call]} =
      StreamAssembler.feed(assembler, %StreamEvent{type: :content_stop, index: 0})

    assert call.arguments == %{}
  end

  test "malformed arguments preserve raw_arguments and report arguments_error" do
    assembler = StreamAssembler.new(json_decoder: &decoder/1)

    {:ok, assembler, []} = StreamAssembler.feed(assembler, start(0, "call_1", "f"))
    {:ok, assembler, []} = StreamAssembler.feed(assembler, delta(0, ~s({"ci)))
    {:ok, _assembler, [call]} = StreamAssembler.feed(assembler, stop(0))

    assert call.arguments == nil
    assert call.raw_arguments == ~s({"ci)
    assert call.arguments_error == {:invalid_json, "invalid json"}
  end

  test "partial fragments finalized by finish/1 are reported, not guessed" do
    assembler = StreamAssembler.new(json_decoder: &decoder/1)

    {:ok, assembler, []} = StreamAssembler.feed(assembler, start(0, "call_1", "f"))
    {:ok, assembler, []} = StreamAssembler.feed(assembler, delta(0, ~s({"ci)))
    {:ok, _assembler, [call]} = StreamAssembler.finish(assembler)

    assert call.arguments == nil
    assert call.arguments_error == {:invalid_json, "invalid json"}
  end

  test "without a decoder the raw arguments are kept and the error is typed" do
    assembler = StreamAssembler.new()

    {:ok, assembler, []} = StreamAssembler.feed(assembler, start(0, "call_1", "f"))
    {:ok, assembler, []} = StreamAssembler.feed(assembler, delta(0, ~s({"a":1})))
    {:ok, _assembler, [call]} = StreamAssembler.feed(assembler, stop(0))

    assert call.arguments == nil
    assert call.raw_arguments == ~s({"a":1})
    assert call.arguments_error == {:invalid_json, ~s({"a":1})}
  end

  test "a call with no streamed arguments decodes to an empty map" do
    assembler = StreamAssembler.new(json_decoder: &decoder/1)

    {:ok, assembler, []} = StreamAssembler.feed(assembler, start(0, "call_1", "f"))
    {:ok, _assembler, [call]} = StreamAssembler.feed(assembler, stop(0))

    assert call.arguments == %{}
    assert call.raw_arguments == nil
    assert call.arguments_error == nil
  end

  test "a delta for an unseen index without start data still assembles" do
    assembler = StreamAssembler.new(json_decoder: &decoder/1)
    {:ok, assembler, []} = StreamAssembler.feed(assembler, delta(nil, ~s({"a":1})))
    {:ok, _assembler, [call]} = StreamAssembler.finish(assembler)

    assert call.index == 0
    assert call.arguments == %{"a" => 1}
  end

  test "unrelated events are ignored" do
    assembler = StreamAssembler.new(json_decoder: &decoder/1)

    assert {:ok, ^assembler, []} =
             StreamAssembler.feed(assembler, %StreamEvent{
               type: :text_delta,
               delta: %StreamDelta.Text{text: "hi"}
             })
  end

  test "StreamState carries codec and opaque data" do
    state = StreamState.new(SomeCodec, %{cursor: 1})

    assert StreamState.codec(state) == SomeCodec
    assert StreamState.data(state) == %{cursor: 1}
  end
end

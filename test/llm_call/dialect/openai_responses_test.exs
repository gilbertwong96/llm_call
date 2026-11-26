defmodule LlmCall.Dialect.OpenAIResponsesTest do
  use ExUnit.Case, async: true

  alias LlmCall.Dialect.OpenAI.Responses

  alias LlmCall.{
    Config,
    Content,
    Error,
    Message,
    Reasoning,
    Request,
    StreamDelta,
    StreamEvent,
    ToolCall,
    ToolResult,
    ToolSpec
  }

  alias LlmCall.Fixtures.OpenAIResponses, as: Fx

  defp encode(request, config \\ %Config{}) do
    assert {:ok, encoded} = Responses.encode_request(request, config)
    encoded
  end

  defp text_request(overrides \\ []) do
    struct(
      %Request{
        model: "gpt-4.1",
        messages: [%Message{role: :user, content: [%Content.Text{text: "Hello"}]}]
      },
      overrides
    )
  end

  defp stream_events(events, config \\ %Config{}) do
    {:ok, state} = Responses.init_stream(text_request(), config)

    {events, _state} =
      Enum.reduce(events, {[], state}, fn event, {acc, state} ->
        assert {:ok, new_events, state} = Responses.decode_stream_event(event, config, state)
        {acc ++ new_events, state}
      end)

    events
  end

  test "a reasoning or argument delta whose payload is not a string is rejected" do
    {:ok, state} = Responses.init_stream(text_request(), %Config{})

    for type <- [
          "response.reasoning_summary_text.delta",
          "response.reasoning_text.delta",
          "response.function_call_arguments.delta"
        ] do
      assert {:error, %LlmCall.Error{kind: :invalid_response, message: message}} =
               Responses.decode_stream_event(%{"type" => type, "delta" => nil}, %Config{}, state)

      assert message =~ "is not a string"
    end
  end

  test "a text delta whose payload is not a string is an invalid response" do
    {:ok, state} = Responses.init_stream(text_request(), %Config{})

    assert {:error, %LlmCall.Error{kind: :invalid_response, message: message}} =
             Responses.decode_stream_event(
               %{"type" => "response.output_text.delta", "delta" => nil},
               %Config{},
               state
             )

    assert message =~ "text delta is not a string"
  end

  test "info/0 declares the protocol and IR version" do
    assert %LlmCall.Codec.Info{name: :openai_responses, protocol: :openai_responses} =
             Responses.info()
  end

  test "encodes a minimal text request as input items" do
    encoded = encode(text_request())

    assert encoded.method == :post
    assert encoded.path == "/v1/responses"

    assert encoded.body == %{
             "model" => "gpt-4.1",
             "input" => [
               %{
                 "type" => "message",
                 "role" => "user",
                 "content" => [%{"type" => "input_text", "text" => "Hello"}]
               }
             ]
           }
  end

  test "system string and system parts become instructions" do
    assert encode(text_request(system: "be nice")).body["instructions"] == "be nice"

    assert encode(text_request(system: [%Content.Text{text: "a"}, %Content.Text{text: "b"}])).body[
             "instructions"
           ] == "a\nb"
  end

  test "assistant tool calls and user tool results become typed items" do
    call = %ToolCall{id: "call_1", name: "f", arguments: %{"x" => 1}}

    assistant = %Message{
      role: :assistant,
      content: [%Content.Text{text: "let me check"}, call]
    }

    result = %ToolResult{call_id: "call_1", content: "42"}
    user = %Message{role: :user, content: [result, %Content.Text{text: "thanks"}]}

    input = encode(text_request(messages: [assistant, user])).body["input"]

    assert input == [
             %{
               "type" => "message",
               "role" => "assistant",
               "content" => [%{"type" => "input_text", "text" => "let me check"}]
             },
             %{
               "type" => "function_call",
               "call_id" => "call_1",
               "name" => "f",
               "arguments" => ~s({"x":1})
             },
             %{
               "type" => "function_call_output",
               "call_id" => "call_1",
               "output" => "42"
             },
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => "thanks"}]
             }
           ]
  end

  test "raw tool arguments win over the decoded map" do
    call = %ToolCall{id: "call_1", name: "f", raw_arguments: ~s({"x":2}), arguments: %{"x" => 1}}

    [item] =
      encode(text_request(messages: [%Message{role: :assistant, content: [call]}])).body["input"]

    assert item["arguments"] == ~s({"x":2})
  end

  test "images and files encode as input parts" do
    image = %Content.Image{source: {:base64, "AAA"}, media_type: "image/png"}
    file = %Content.File{source: {:file_id, "file_1"}, filename: "a.pdf"}
    message = %Message{role: :user, content: [image, file]}

    [%{"content" => content}] = encode(text_request(messages: [message])).body["input"]

    assert content == [
             %{
               "type" => "input_image",
               "image_url" => "data:image/png;base64,AAA"
             },
             %{
               "type" => "input_file",
               "file_id" => "file_1",
               "filename" => "a.pdf"
             }
           ]
  end

  test "tools, tool_choice and strict map to the flat Responses envelope" do
    tools = [
      %ToolSpec{
        name: "f",
        description: "d",
        parameters: %{"type" => "object"},
        strict: true
      }
    ]

    body = encode(text_request(tools: tools, tool_choice: {:tool, "f"})).body

    assert body["tools"] == [
             %{
               "type" => "function",
               "name" => "f",
               "description" => "d",
               "parameters" => %{"type" => "object"},
               "strict" => true
             }
           ]

    assert body["tool_choice"] == %{"type" => "function", "name" => "f"}
  end

  test "builtin tools pass through with their native configuration" do
    tool = %ToolSpec{
      kind: :builtin,
      name: "web_search",
      provider_options: %{"search_context_size" => "low"}
    }

    assert encode(text_request(tools: [tool])).body["tools"] == [
             %{"type" => "web_search", "search_context_size" => "low"}
           ]
  end

  test "output formats map to text.format" do
    assert encode(text_request(output: :json_object)).body["text"] == %{
             "format" => %{"type" => "json_object"}
           }

    schema = {:json_schema, "s", %{"type" => "object"}, true}

    assert encode(text_request(output: schema)).body["text"] == %{
             "format" => %{
               "type" => "json_schema",
               "name" => "s",
               "schema" => %{"type" => "object"},
               "strict" => true
             }
           }
  end

  test "reasoning effort and summary map to the reasoning object" do
    reasoning = %Reasoning{effort: :high, summary: :auto}

    assert encode(text_request(reasoning: reasoning)).body["reasoning"] == %{
             "effort" => "high",
             "summary" => "auto"
           }
  end

  test "params map max_tokens to max_output_tokens" do
    body = encode(text_request(params: %{max_tokens: 64, temperature: 0.2})).body

    assert body["max_output_tokens"] == 64
    assert body["temperature"] == 0.2
  end

  test "provider_options merge store and previous_response_id beside the canonical body" do
    options = %{openai: %{"store" => true, "previous_response_id" => "resp_0"}}
    body = encode(text_request(provider_options: options)).body

    assert body["store"] == true
    assert body["previous_response_id"] == "resp_0"
  end

  test "known native provider options are type-checked" do
    assert {:error, %Error{kind: :validation, message: message}} =
             Responses.validate_request(
               text_request(provider_options: %{openai: %{"access_programs" => "blue"}}),
               %Config{}
             )

    assert message =~ "access_programs"

    assert :ok ==
             Responses.validate_request(
               text_request(
                 provider_options: %{
                   openai: %{"access_programs" => %{"cyber" => "daybreak_blue"}}
                 }
               ),
               %Config{}
             )
  end

  test "config default provider options apply and the request wins" do
    config = %Config{
      default_provider_options: %{openai: %{"store" => false, "metadata" => %{"a" => 1}}}
    }

    request = text_request(provider_options: %{openai: %{"store" => true}})
    body = encode(request, config).body

    assert body["store"] == true
    assert body["metadata"] == %{"a" => 1}
  end

  test "reserved provider options are validation errors" do
    for options <- [%{"model" => "evil"}, %{"input" => []}, %{"reasoning" => %{}}] do
      assert {:error, %Error{kind: :validation, message: message}} =
               Responses.validate_request(
                 text_request(provider_options: %{openai: options}),
                 %Config{}
               )

      assert message =~ "canonical field"
    end
  end

  test "unsupported canonical values are validation errors, never silent drops" do
    thinking = %Content.Thinking{text: "why", signature: "sig"}

    assert {:error, %Error{message: thinking_message}} =
             Responses.validate_request(
               text_request(messages: [%Message{role: :assistant, content: [thinking]}]),
               %Config{}
             )

    assert thinking_message =~ "reasoning items cannot be replayed"

    assert {:error, %Error{message: raw_message}} =
             Responses.validate_request(
               text_request(
                 messages: [
                   %Message{role: :user, content: [%Content.Raw{type: "blob", data: %{}}]}
                 ]
               ),
               %Config{}
             )

    assert raw_message =~ "raw content"

    assert {:error, %Error{message: params_message}} =
             Responses.validate_request(text_request(params: %{stop: ["x"]}), %Config{})

    assert params_message =~ "stop"

    assert {:error, %Error{message: budget_message}} =
             Responses.validate_request(
               text_request(reasoning: %Reasoning{budget_tokens: 1024}),
               %Config{}
             )

    assert budget_message =~ "budget_tokens"
  end

  test "base64 images require a media type and tool_choice needs tools" do
    image = %Content.Image{source: {:base64, "AAA"}}

    assert {:error, %Error{message: message}} =
             Responses.validate_request(
               text_request(messages: [%Message{role: :user, content: [image]}]),
               %Config{}
             )

    assert message =~ "media_type"

    assert {:error, %Error{message: choice_message}} =
             Responses.validate_request(text_request(tool_choice: :required), %Config{})

    assert choice_message =~ "requires at least one tool"

    assert {:error, %Error{message: allowed_message}} =
             Responses.validate_request(
               text_request(tools: [%ToolSpec{name: "f"}], tool_choice: {:allowed, ["f"]}),
               %Config{}
             )

    assert allowed_message =~ "is not supported"
  end

  test "decodes a text response with output items and usage" do
    assert {:ok, %LlmCall.Response{} = response} =
             Responses.decode_response(Fx.text_response(), %Config{})

    assert response.id == "resp_1"
    assert response.model == "gpt-4.1"
    assert response.stop_reason == :end_turn
    assert [%Content.Text{text: "Hello there"}] = response.content

    assert %LlmCall.Usage{
             input_tokens: 12,
             output_tokens: 5,
             total_tokens: 17,
             cache_read_tokens: 3,
             reasoning_tokens: 0
           } = response.usage
  end

  test "decodes annotations and unknown items without dropping them" do
    assert {:ok, %{content: content}} =
             Responses.decode_response(Fx.annotated_response(), %Config{})

    assert [
             %Content.Text{text: "See the file"},
             %Content.Raw{type: "annotation", data: %{"file_id" => "file_1"}}
           ] = content

    assert {:ok, %{content: [%Content.Raw{type: "web_search_call"}]}} =
             Responses.decode_response(Fx.builtin_tool_response(), %Config{})
  end

  test "decodes a function call with its call_id and arguments" do
    assert {:ok, %{content: [%ToolCall{} = call], stop_reason: :tool_calls}} =
             Responses.decode_response(Fx.tool_call_response(), %Config{})

    assert call.id == "call_1"
    assert call.name == "get_weather"
    assert call.arguments == %{"city" => "Oslo"}
    assert call.raw_arguments == ~s({"city":"Oslo"})
  end

  test "non-list annotations are ignored instead of raising" do
    payload =
      put_in(
        Fx.text_response(),
        ["output", Access.at(0), "content", Access.at(0), "annotations"],
        %{"unexpected" => true}
      )

    assert {:ok, %{content: [%Content.Text{text: "Hello there"}]}} =
             Responses.decode_response(payload, %Config{})
  end

  test "a malformed item or part is tolerated instead of raising" do
    assert {:ok, state} = Responses.init_stream(text_request(), %Config{})

    assert {:ok, [], state} =
             Responses.decode_stream_event(
               %{"type" => "response.output_item.added", "output_index" => 0, "item" => "bad"},
               %Config{},
               state
             )

    assert {:ok, [%StreamEvent{type: :content_start}], _state} =
             Responses.decode_stream_event(
               %{
                 "type" => "response.content_part.added",
                 "output_index" => 0,
                 "part" => "bad"
               },
               %Config{},
               state
             )
  end

  test "a non-object stream event is an invalid_response error" do
    assert {:ok, state} = Responses.init_stream(text_request(), %Config{})

    assert {:error, %Error{kind: :invalid_response}} =
             Responses.decode_stream_event("not an event", %Config{}, state)
  end

  test "decodes reasoning summaries into thinking with the encrypted signature" do
    assert {:ok, %{content: [%Content.Thinking{} = thinking, %Content.Text{}]}} =
             Responses.decode_response(Fx.reasoning_response(), %Config{})

    assert thinking.text == "Checked the weather"
    assert thinking.signature == "enc_1"
  end

  test "incomplete responses carry a stop reason, failed responses are typed errors" do
    assert {:ok, %{stop_reason: :max_tokens}} =
             Responses.decode_response(Fx.incomplete_response(), %Config{})

    assert {:error, %Error{kind: :provider, code: "server_error", retryable?: true}} =
             Responses.decode_response(Fx.failed_response(), %Config{})
  end

  test "decode_error/2 normalizes the error envelope" do
    assert %Error{kind: :provider, message: "bad request", code: "invalid"} =
             Responses.decode_error(Fx.error_payload(), %Config{})
  end

  test "capture_raw keeps the response payload only when asked" do
    assert {:ok, %{raw: nil}} = Responses.decode_response(Fx.text_response(), %Config{})

    assert {:ok, %{raw: %{"id" => "resp_1"}}} =
             Responses.decode_response(Fx.text_response(), %Config{capture_raw: :response})
  end

  test "streams text as lifecycle and delta events" do
    message = Fx.message_item("msg_1", [])

    events =
      stream_events([
        Fx.created(),
        Fx.in_progress(),
        Fx.output_item_added(message, 0),
        Fx.content_part_added(%{"type" => "output_text", "text" => ""}, 0),
        Fx.text_delta("Hel"),
        Fx.text_delta("lo"),
        Fx.text_done("Hello"),
        Fx.content_part_done(%{"type" => "output_text", "text" => "Hello"}, 0),
        Fx.output_item_done(message, 0),
        Fx.completed()
      ])

    assert Enum.map(events, & &1.type) == [
             :message_start,
             :content_start,
             :text_delta,
             :text_delta,
             :content_stop,
             :message_delta,
             :message_stop
           ]

    assert [
             %StreamEvent{delta: %StreamDelta.Text{text: "Hel"}},
             %StreamEvent{delta: %StreamDelta.Text{text: "lo"}}
           ] = Enum.filter(events, &(&1.type == :text_delta))

    assert %StreamEvent{delta: %StreamDelta.MessageDelta{stop_reason: :end_turn, usage: usage}} =
             Enum.find(events, &(&1.type == :message_delta))

    assert %LlmCall.Usage{total_tokens: 17} = usage
  end

  test "streams function calls with start, delta and stop" do
    item = %{"type" => "function_call", "call_id" => "call_1", "name" => "get_weather"}

    events =
      stream_events([
        Fx.created(),
        Fx.output_item_added(item, 0),
        Fx.arguments_delta(~s({"city":)),
        Fx.arguments_delta(~s("Oslo"})),
        Fx.arguments_done(~s({"city":"Oslo"})),
        Fx.output_item_done(item, 0),
        Fx.completed(Fx.tool_call_response())
      ])

    assert Enum.map(events, & &1.type) == [
             :message_start,
             :tool_call_start,
             :tool_call_delta,
             :tool_call_delta,
             :tool_call_stop,
             :message_delta,
             :message_stop
           ]

    assert %StreamEvent{delta: %StreamDelta.MessageDelta{stop_reason: :tool_calls}} =
             Enum.find(events, &(&1.type == :message_delta))
  end

  test "streams reasoning summaries as thinking deltas" do
    events =
      stream_events([
        Fx.created(),
        Fx.output_item_added(%{"type" => "reasoning"}, 0),
        Fx.reasoning_delta("Checked"),
        Fx.reasoning_delta(" the weather"),
        Fx.completed(Fx.reasoning_response())
      ])

    assert [
             %StreamEvent{type: :thinking_delta, delta: %StreamDelta.Thinking{text: "Checked"}},
             %StreamEvent{
               type: :thinking_delta,
               delta: %StreamDelta.Thinking{text: " the weather"}
             }
           ] = Enum.filter(events, &(&1.type == :thinking_delta))
  end

  test "streamed failures and error events are typed errors" do
    assert {:ok, state} = Responses.init_stream(text_request(), %Config{})

    assert {:error, %Error{kind: :provider, code: "server_error"}} =
             Responses.decode_stream_event(Fx.failed_event(), %Config{}, state)

    assert {:error, %Error{kind: :provider}} =
             Responses.decode_stream_event(Fx.error_event(), %Config{}, state)
  end

  test "unknown stream events are preserved as raw deltas" do
    events = stream_events([%{"type" => "response.queued", "response" => %{}}])

    assert [
             %StreamEvent{
               type: :message_delta,
               delta: %StreamDelta.Raw{data: %{"type" => "response.queued"}}
             }
           ] =
             events
  end

  test "stream raw capture keeps every event only with capture_raw: :all" do
    config = %Config{capture_raw: :all}
    events = stream_events([Fx.created(), Fx.completed()], config)

    assert Enum.all?(events, &(&1.raw != nil))
  end

  test "capabilities describe the Responses surface" do
    assert %LlmCall.Capabilities{
             tools: true,
             builtin_tools: :passthrough,
             structured_output: :json_schema,
             image_input: %LlmCall.Capabilities.Input{inline: true, url: true, file: true},
             file_input: %LlmCall.Capabilities.Input{inline: true, url: true, file: true},
             stateful: true,
             streaming: true
           } = Responses.capabilities(text_request(), %Config{})
  end
end

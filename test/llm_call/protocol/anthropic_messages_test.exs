defmodule LlmCall.Protocol.AnthropicMessagesTest do
  use ExUnit.Case, async: true

  alias LlmCall.Protocol.Anthropic.Messages

  alias LlmCall.{
    Config,
    Content,
    Error,
    Message,
    Reasoning,
    Request,
    ToolCall,
    ToolResult,
    ToolSpec
  }

  alias LlmCall.Fixtures.AnthropicMessages, as: Fx

  defp encode(request, config \\ %Config{}) do
    assert {:ok, encoded} = Messages.encode_request(request, config)
    encoded
  end

  defp text_request(overrides \\ []) do
    struct(
      %Request{
        model: "claude-sonnet-4-5",
        params: %{max_tokens: 1024},
        messages: [%Message{role: :user, content: [%Content.Text{text: "Hello"}]}]
      },
      overrides
    )
  end

  test "info/0 carries the Anthropic API version" do
    assert %LlmCall.Codec.Info{
             name: :anthropic_messages,
             protocol: :anthropic_messages,
             version: "2023-06-01",
             ir_version: 1
           } = Messages.info()
  end

  test "encodes a minimal text request with the required headers" do
    encoded = encode(text_request())
    assert encoded.path == "/v1/messages"
    assert encoded.query == %{}

    assert encoded.headers == [
             {"content-type", "application/json"},
             {"anthropic-version", "2023-06-01"}
           ]

    assert encoded.body == %{
             "model" => "claude-sonnet-4-5",
             "max_tokens" => 1024,
             "messages" => [
               %{"role" => "user", "content" => [%{"type" => "text", "text" => "Hello"}]}
             ]
           }
  end

  test "system is top-level and accepts a string or text blocks" do
    assert encode(text_request(system: "Be terse.")).body["system"] == "Be terse."

    assert encode(text_request(system: [%Content.Text{text: "Be terse."}])).body["system"] ==
             [%{"type" => "text", "text" => "Be terse."}]
  end

  test "tool calls and tool results map to tool_use and tool_result blocks" do
    messages = [
      %Message{role: :user, content: [%Content.Text{text: "weather?"}]},
      %Message{
        role: :assistant,
        content: [%ToolCall{id: "toolu_1", name: "get_weather", arguments: %{"city" => "Oslo"}}]
      },
      %Message{
        role: :user,
        content: [
          %ToolResult{
            call_id: "toolu_1",
            name: "get_weather",
            content: [%Content.Text{text: "Sunny"}],
            is_error: true
          }
        ]
      }
    ]

    body = encode(text_request(messages: messages)).body

    assert Enum.at(body["messages"], 1) == %{
             "role" => "assistant",
             "content" => [
               %{
                 "type" => "tool_use",
                 "id" => "toolu_1",
                 "name" => "get_weather",
                 "input" => %{"city" => "Oslo"}
               }
             ]
           }

    assert Enum.at(body["messages"], 2) == %{
             "role" => "user",
             "content" => [
               %{
                 "type" => "tool_result",
                 "tool_use_id" => "toolu_1",
                 "content" => [%{"type" => "text", "text" => "Sunny"}],
                 "is_error" => true
               }
             ]
           }
  end

  test "tool result with string content sends the string" do
    messages = [%Message{role: :user, content: [%ToolResult{call_id: "t1", content: "Sunny"}]}]

    assert encode(text_request(messages: messages)).body["messages"]
           |> hd()
           |> Map.fetch!("content") == [
             %{"type" => "tool_result", "tool_use_id" => "t1", "content" => "Sunny"}
           ]
  end

  test "tools map to name/description/input_schema and tool_choice to the Anthropic union" do
    tools = [
      %ToolSpec{
        name: "get_weather",
        description: "Get weather",
        parameters: %{"type" => "object"}
      }
    ]

    body = encode(text_request(tools: tools, tool_choice: :required)).body

    assert body["tools"] == [
             %{
               "name" => "get_weather",
               "description" => "Get weather",
               "input_schema" => %{"type" => "object"}
             }
           ]

    assert body["tool_choice"] == %{"type" => "any"}

    assert encode(text_request(tools: tools, tool_choice: {:tool, "get_weather"})).body[
             "tool_choice"
           ] == %{"type" => "tool", "name" => "get_weather"}

    assert encode(text_request(tools: tools, tool_choice: :none)).body["tool_choice"] == %{
             "type" => "none"
           }

    assert encode(text_request(tools: tools, tool_choice: :auto)).body["tool_choice"] == %{
             "type" => "auto"
           }
  end

  test "sampling params map to native fields" do
    body =
      encode(
        text_request(
          params: %{max_tokens: 64, temperature: 0.2, top_p: 0.9, top_k: 40, stop: ["END"]}
        )
      ).body

    assert body["max_tokens"] == 64
    assert body["temperature"] == 0.2
    assert body["top_p"] == 0.9
    assert body["top_k"] == 40
    assert body["stop_sequences"] == ["END"]
  end

  test "thinking budget and disabled effort map to the thinking field" do
    assert encode(text_request(reasoning: %Reasoning{budget_tokens: 2048})).body["thinking"] ==
             %{"type" => "enabled", "budget_tokens" => 2048}

    assert encode(text_request(reasoning: %Reasoning{effort: :none})).body["thinking"] == %{
             "type" => "disabled"
           }

    assert {:error, %Error{kind: :validation}} =
             Messages.encode_request(
               text_request(reasoning: %Reasoning{effort: :high}),
               %Config{}
             )

    assert {:error, %Error{kind: :validation}} =
             Messages.encode_request(
               text_request(reasoning: %Reasoning{summary: :auto}),
               %Config{}
             )
  end

  test "images and documents map to their Anthropic sources" do
    messages = [
      %Message{
        role: :user,
        content: [
          %Content.Image{source: {:base64, "AAA"}, media_type: "image/png"},
          %Content.Image{source: {:url, "https://example.com/a.png"}},
          %Content.File{
            source: {:base64, "PDF"},
            media_type: "application/pdf",
            filename: "a.pdf"
          }
        ]
      }
    ]

    assert encode(text_request(messages: messages)).body["messages"]
           |> hd()
           |> Map.fetch!("content") == [
             %{
               "type" => "image",
               "source" => %{"type" => "base64", "media_type" => "image/png", "data" => "AAA"}
             },
             %{
               "type" => "image",
               "source" => %{"type" => "url", "url" => "https://example.com/a.png"}
             },
             %{
               "type" => "document",
               "source" => %{
                 "type" => "base64",
                 "media_type" => "application/pdf",
                 "data" => "PDF"
               },
               "title" => "a.pdf"
             }
           ]
  end

  test "thinking blocks round-trip and require a signature" do
    messages = [
      %Message{
        role: :assistant,
        content: [%Content.Thinking{text: "hmm", signature: "sig"}, %Content.Text{text: "hi"}]
      }
    ]

    assert encode(text_request(messages: messages)).body["messages"]
           |> hd()
           |> Map.fetch!("content")
           |> hd() == %{"type" => "thinking", "thinking" => "hmm", "signature" => "sig"}

    no_signature = [%Message{role: :assistant, content: [%Content.Thinking{text: "hmm"}]}]

    assert {:error, %Error{kind: :validation}} =
             Messages.encode_request(text_request(messages: no_signature), %Config{})
  end

  test "provider_options are merged but reserved keys are rejected" do
    assert encode(
             text_request(provider_options: %{anthropic: %{"metadata" => %{"user_id" => "u1"}}})
           ).body[
             "metadata"
           ] == %{"user_id" => "u1"}

    assert {:error, %Error{kind: :validation}} =
             Messages.encode_request(
               text_request(provider_options: %{anthropic: %{"messages" => []}}),
               %Config{}
             )
  end

  test "unsupported canonical values are validation errors, never silent drops" do
    cases = [
      text_request(params: %{seed: 1}),
      text_request(params: %{}),
      text_request(output: :json_object),
      text_request(output: {:json_schema, "x", %{}, nil}),
      text_request(tools: [%ToolSpec{name: "f"}], tool_choice: {:allowed, ["f"]}),
      text_request(tools: [%ToolSpec{kind: :builtin, name: "web_search"}]),
      text_request(params: %{max_tokens: nil, top_k: nil}),
      text_request(messages: [%Message{role: :assistant, content: []}]),
      text_request(
        messages: [%Message{role: :user, content: [%Content.Image{source: {:file_id, "f"}}]}]
      ),
      text_request(
        messages: [%Message{role: :user, content: [%Content.Image{source: {:base64, "AAA"}}]}]
      ),
      text_request(messages: [%Message{role: :user, content: [%ToolResult{content: "x"}]}]),
      text_request(system: [%Content.Image{source: {:url, "u"}}]),
      %Request{model: "x", params: %{max_tokens: 1}, messages: []}
    ]

    for request <- cases do
      assert {:error, %Error{kind: :validation, message: message}} =
               Messages.validate_request(request, %Config{})

      assert is_binary(message)
      assert {:error, %Error{kind: :validation}} = Messages.encode_request(request, %Config{})
    end
  end

  defp stream_state(config \\ %Config{}) do
    assert {:ok, state} = Messages.init_stream(text_request(stream: true), config)
    state
  end

  defp run_stream(events, config \\ %Config{}) do
    Enum.reduce(events, {stream_state(config), []}, fn event, {state, acc} ->
      {:ok, new_events, state} = Messages.decode_stream_event(event, config, state)
      {state, acc ++ new_events}
    end)
  end

  describe "decode" do
    test "decodes text, thinking and tool_use blocks with usage" do
      assert {:ok, response} = Messages.decode_response(Fx.text_response(), %Config{})
      assert response.id == "msg_123"
      assert response.model == "claude-sonnet-4-5"
      assert response.stop_reason == :end_turn
      assert LlmCall.Response.text(response) == "Hello"

      assert response.usage == %LlmCall.Usage{
               input_tokens: 12,
               output_tokens: 5,
               total_tokens: 17,
               cache_read_tokens: 3,
               cache_write_tokens: 7,
               reasoning_tokens: nil
             }
    end

    test "decodes tool_use blocks into ToolCall values with a decoded input map" do
      {:ok, response} = Messages.decode_response(Fx.tool_response(), %Config{})
      assert response.stop_reason == :tool_calls

      assert [
               %ToolCall{
                 id: "toolu_1",
                 name: "get_weather",
                 arguments: %{"city" => "Oslo"},
                 raw_arguments: nil,
                 arguments_error: nil
               }
             ] = LlmCall.Response.tool_calls(response)
    end

    test "thinking and unknown blocks are preserved" do
      {:ok, response} = Messages.decode_response(Fx.mixed_response(), %Config{})

      assert [
               %Content.Thinking{text: "step", signature: "sig"},
               %Content.Text{text: "Hi"},
               %Content.Raw{type: "redacted_thinking"}
             ] = response.content
    end

    test "capture_raw :response keeps the payload and stop_reason mapping covers every value" do
      payload = Fx.text_response()

      assert {:ok, %{raw: ^payload}} =
               Messages.decode_response(payload, %Config{capture_raw: :response})

      for {wire, canonical} <- [
            {"end_turn", :end_turn},
            {"max_tokens", :max_tokens},
            {"stop_sequence", :stop_sequence},
            {"tool_use", :tool_calls},
            {"refusal", :content_filter},
            {"pause_turn", :unknown}
          ] do
        assert {:ok, %{stop_reason: ^canonical}} =
                 Messages.decode_response(Fx.response_with_stop(wire), %Config{})
      end
    end

    test "invalid payloads are invalid_response errors" do
      assert {:error, %Error{kind: :invalid_response}} =
               Messages.decode_response(%{"nope" => 1}, %Config{})

      assert {:error, %Error{kind: :invalid_response}} =
               Messages.decode_response(%{"content" => "text"}, %Config{})
    end

    test "decode_error/2 normalizes the provider envelope" do
      payload = Fx.error_payload()

      assert %Error{
               kind: :provider,
               message: "Overloaded",
               code: "overloaded_error",
               retryable?: true,
               raw: ^payload
             } = Messages.decode_error(payload, %Config{})

      assert %Error{kind: :invalid_response, raw: nil} =
               Messages.decode_error(%{"weird" => 1}, %Config{})
    end

    test "capabilities/2 declares the Anthropic surface" do
      caps = Messages.capabilities(text_request(), %Config{})

      assert %LlmCall.Capabilities{
               tools: true,
               parallel_tool_calls: true,
               tool_choice: true,
               structured_output: :none,
               image_input: true,
               file_input: true,
               streaming_tool_calls: true,
               prompt_cache: true,
               stateful: false,
               streaming: true
             } = caps

      assert %LlmCall.ReasoningCapabilities{
               supported: true,
               budget_tokens: true,
               adaptive: true,
               efforts: [],
               summary: []
             } = caps.reasoning
    end
  end

  describe "stream" do
    test "text stream emits start, deltas, message delta and stop" do
      {_state, events} = run_stream(Fx.text_stream())

      assert Enum.map(events, & &1.type) == [
               :message_start,
               :content_start,
               :text_delta,
               :text_delta,
               :content_stop,
               :message_delta,
               :message_stop
             ]

      assert Enum.map(Enum.filter(events, &(&1.type == :text_delta)), & &1.delta.text) == [
               "Hel",
               "lo"
             ]

      assert %LlmCall.StreamDelta.MessageDelta{
               stop_reason: :end_turn,
               usage: %LlmCall.Usage{output_tokens: 5, input_tokens: 12}
             } = Enum.at(events, 5).delta
    end

    test "tool_use blocks emit tool_call_start, deltas and tool_call_stop and assemble" do
      {_state, events} = run_stream(Fx.tool_stream())

      assert Enum.map(events, & &1.type) == [
               :message_start,
               :tool_call_start,
               :tool_call_delta,
               :tool_call_delta,
               :tool_call_stop,
               :message_delta,
               :message_stop
             ]

      assembler = LlmCall.StreamAssembler.new(json_decoder: &LlmCall.TestJSON.decode/1)

      {_assembler, calls} =
        Enum.reduce(events, {assembler, []}, fn event, {assembler, acc} ->
          {:ok, assembler, new} = LlmCall.StreamAssembler.feed(assembler, event)
          {assembler, acc ++ new}
        end)

      assert [
               %ToolCall{
                 id: "toolu_1",
                 name: "get_weather",
                 arguments: %{"city" => "Oslo"},
                 index: 0
               }
             ] = calls
    end

    test "thinking deltas and signature deltas both map to thinking_delta" do
      {_state, events} = run_stream(Fx.thinking_stream())
      thinking = Enum.filter(events, &(&1.type == :thinking_delta))

      assert Enum.map(thinking, & &1.delta.text) == ["think", ""]
      assert List.last(thinking).delta.signature == "sig"
    end

    test "ping emits no events and error payloads become typed errors" do
      state = stream_state()

      assert {:ok, [], ^state} =
               Messages.decode_stream_event(%{"type" => "ping"}, %Config{}, state)

      assert {:error, %Error{kind: :provider}} =
               Messages.decode_stream_event(
                 %{"type" => "error", "error" => Fx.error_payload()["error"]},
                 %Config{},
                 state
               )
    end

    test "unknown event types are preserved as Raw message deltas" do
      state = stream_state()

      event = %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "citations_delta", "citation" => %{}}
      }

      assert {:ok,
              [
                %LlmCall.StreamEvent{
                  type: :message_delta,
                  delta: %LlmCall.StreamDelta.Raw{data: data}
                }
              ], _state} = Messages.decode_stream_event(event, %Config{}, state)

      assert data["data"]["type"] == "citations_delta"
    end

    test "capture_raw :all keeps raw events and finish_stream emits nothing" do
      event = Fx.text_stream() |> Enum.at(2)

      assert {:ok, [%LlmCall.StreamEvent{raw: ^event}], state} =
               Messages.decode_stream_event(
                 event,
                 %Config{capture_raw: :all},
                 stream_state(%Config{capture_raw: :all})
               )

      assert {:ok, [], ^state} = Messages.finish_stream(state, %Config{})
    end
  end

  describe "review fixes" do
    test "role rules reject parts that cannot appear in that turn" do
      cases = [
        [%Message{role: :user, content: [%ToolCall{id: "c", name: "f", arguments: %{}}]}],
        [%Message{role: :assistant, content: [%ToolResult{call_id: "c", content: "x"}]}],
        [%Message{role: :user, content: []}],
        [%Message{role: :assistant, content: []}],
        [%Message{role: :user, content: [%Content.Thinking{text: "t", signature: "s"}]}]
      ]

      for messages <- cases do
        assert {:error, %Error{kind: :validation}} =
                 Messages.validate_request(text_request(messages: messages), %Config{})

        assert {:error, %Error{kind: :validation}} =
                 Messages.encode_request(text_request(messages: messages), %Config{})
      end
    end

    test "reasoning and tool provider options are merged into their native locations" do
      reasoning = %Reasoning{budget_tokens: 1024, provider_options: %{"display" => "omitted"}}

      assert encode(text_request(reasoning: reasoning)).body["thinking"] == %{
               "type" => "enabled",
               "budget_tokens" => 1024,
               "display" => "omitted"
             }

      tools = [
        %ToolSpec{name: "f", provider_options: %{"cache_control" => %{"type" => "ephemeral"}}}
      ]

      assert encode(text_request(tools: tools)).body["tools"]
             |> hd()
             |> Map.fetch!("cache_control") == %{"type" => "ephemeral"}
    end

    test "strict tools are rejected when the protocol cannot express them" do
      tools = [%ToolSpec{name: "f", strict: true}]

      assert {:error, %Error{kind: :validation}} =
               Messages.validate_request(text_request(tools: tools), %Config{})

      assert {:error, %Error{kind: :validation}} =
               Messages.encode_request(text_request(tools: tools), %Config{})
    end

    test "a tool call whose only arguments are undecodable is rejected" do
      messages = [
        %Message{role: :assistant, content: [%ToolCall{id: "t1", name: "f", raw_arguments: "{"}]}
      ]

      assert {:error, %Error{kind: :validation}} =
               Messages.validate_request(text_request(messages: messages), %Config{})
    end
  end

  describe "deferred minors" do
    test "an empty system part list sends no system field" do
      refute Map.has_key?(encode(text_request(system: [])).body, "system")
    end

    test "raw blocks are rejected in the system field" do
      system = [%Content.Raw{type: "text", data: %{"type" => "text", "text" => "x"}}]

      assert {:error, %Error{kind: :validation}} =
               Messages.validate_request(text_request(system: system), %Config{})

      assert {:error, %Error{kind: :validation}} =
               Messages.encode_request(text_request(system: system), %Config{})
    end
  end

  describe "modalities" do
    test "text is the only accepted output modality" do
      refute Map.has_key?(encode(text_request()).body, "responseModalities")

      for modalities <- [[:image], [:text, :image], [:video]] do
        request = text_request(modalities: modalities)

        assert {:error, %Error{kind: :validation, message: message}} =
                 Messages.validate_request(request, %Config{})

        assert message =~ "modality"
        assert {:error, %Error{kind: :validation}} = Messages.encode_request(request, %Config{})
      end
    end

    test "capabilities declare text output only" do
      assert Messages.capabilities(text_request(), %Config{}).modalities == [:text]
    end
  end
end

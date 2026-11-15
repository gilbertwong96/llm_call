defmodule LlmDialect.Protocol.GeminiGenerateContentTest do
  use ExUnit.Case, async: true

  alias LlmDialect.Protocol.Gemini.GenerateContent

  alias LlmDialect.{
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

  alias LlmDialect.Fixtures.GeminiGenerateContent, as: Fx

  defp encode(request, config \\ %Config{}) do
    assert {:ok, encoded} = GenerateContent.encode_request(request, config)
    encoded
  end

  defp text_request(overrides \\ []) do
    struct(
      %Request{
        model: "gemini-2.5-pro",
        messages: [%Message{role: :user, content: [%Content.Text{text: "Hello"}]}]
      },
      overrides
    )
  end

  test "info/0 declares the Gemini API version" do
    assert %LlmDialect.Codec.Info{
             name: :gemini_generate_content,
             protocol: :gemini_generate_content,
             version: "v1beta",
             ir_version: 1
           } = GenerateContent.info()
  end

  test "encodes a minimal request into contents with a model-relative path" do
    encoded = encode(text_request())
    assert encoded.path == "/v1beta/models/gemini-2.5-pro:generateContent"
    assert encoded.query == %{}
    assert encoded.headers == [{"content-type", "application/json"}]

    assert encoded.body == %{
             "contents" => [%{"role" => "user", "parts" => [%{"text" => "Hello"}]}]
           }
  end

  test "assistant turns become role: model" do
    messages = [
      %Message{role: :user, content: [%Content.Text{text: "hi"}]},
      %Message{role: :assistant, content: [%Content.Text{text: "hello"}]}
    ]

    assert Enum.map(encode(text_request(messages: messages)).body["contents"], & &1["role"]) ==
             ["user", "model"]
  end

  test "system becomes systemInstruction with parts" do
    assert encode(text_request(system: "Be terse.")).body["systemInstruction"] == %{
             "parts" => [%{"text" => "Be terse."}]
           }

    assert encode(text_request(system: [%Content.Text{text: "a"}, %Content.Text{text: "b"}])).body[
             "systemInstruction"
           ] == %{"parts" => [%{"text" => "a"}, %{"text" => "b"}]}
  end

  test "tool calls, tool results and thinking parts map to Gemini parts" do
    messages = [
      %Message{
        role: :assistant,
        content: [
          %Content.Thinking{text: "hmm"},
          %ToolCall{name: "get_weather", arguments: %{"city" => "Oslo"}}
        ]
      },
      %Message{
        role: :user,
        content: [
          %ToolResult{
            name: "get_weather",
            content: [%Content.Text{text: "Sunny"}],
            is_error: false
          }
        ]
      }
    ]

    parts = encode(text_request(messages: messages)).body["contents"]

    assert Enum.at(parts, 0)["parts"] == [
             %{"text" => "hmm", "thought" => true},
             %{"functionCall" => %{"name" => "get_weather", "args" => %{"city" => "Oslo"}}}
           ]

    assert Enum.at(parts, 1)["parts"] == [
             %{
               "functionResponse" => %{
                 "name" => "get_weather",
                 "response" => %{"result" => "Sunny"}
               }
             }
           ]
  end

  test "error tool results carry an error object and missing name is rejected" do
    messages = [
      %Message{role: :user, content: [%ToolResult{name: "f", content: "boom", is_error: true}]}
    ]

    assert encode(text_request(messages: messages)).body["contents"]
           |> hd()
           |> Map.fetch!("parts") == [
             %{"functionResponse" => %{"name" => "f", "response" => %{"error" => "boom"}}}
           ]

    assert {:error, %Error{kind: :validation}} =
             GenerateContent.encode_request(
               text_request(
                 messages: [%Message{role: :user, content: [%ToolResult{content: "x"}]}]
               ),
               %Config{}
             )
  end

  test "tools become functionDeclarations and tool_choice becomes functionCallingConfig" do
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
               "functionDeclarations" => [
                 %{
                   "name" => "get_weather",
                   "description" => "Get weather",
                   "parameters" => %{"type" => "object"}
                 }
               ]
             }
           ]

    assert body["toolConfig"] == %{"functionCallingConfig" => %{"mode" => "ANY"}}

    assert encode(text_request(tools: tools, tool_choice: :none)).body["toolConfig"] == %{
             "functionCallingConfig" => %{"mode" => "NONE"}
           }

    assert encode(text_request(tools: tools, tool_choice: {:tool, "get_weather"})).body[
             "toolConfig"
           ] == %{
             "functionCallingConfig" => %{
               "mode" => "ANY",
               "allowedFunctionNames" => ["get_weather"]
             }
           }

    assert encode(text_request(tools: tools, tool_choice: {:allowed, ["get_weather"]})).body[
             "toolConfig"
           ] == %{
             "functionCallingConfig" => %{
               "mode" => "ANY",
               "allowedFunctionNames" => ["get_weather"]
             }
           }

    refute Map.has_key?(encode(text_request(tools: tools)).body, "toolConfig")
  end

  test "params and output map into generationConfig" do
    body =
      encode(
        text_request(
          params: %{temperature: 0.2, top_p: 0.9, top_k: 40, max_tokens: 128, stop: ["END"]},
          output: {:json_schema, "person", %{"type" => "object"}, nil}
        )
      ).body

    assert body["generationConfig"] == %{
             "temperature" => 0.2,
             "topP" => 0.9,
             "topK" => 40,
             "maxOutputTokens" => 128,
             "stopSequences" => ["END"],
             "responseMimeType" => "application/json",
             "responseSchema" => %{"type" => "object"}
           }

    assert encode(text_request(output: :json_object)).body["generationConfig"] == %{
             "responseMimeType" => "application/json"
           }
  end

  test "reasoning maps to thinkingConfig" do
    assert encode(text_request(reasoning: %Reasoning{effort: :high})).body["generationConfig"] ==
             %{"thinkingConfig" => %{"thinkingLevel" => "high"}}

    assert encode(text_request(reasoning: %Reasoning{budget_tokens: 512})).body[
             "generationConfig"
           ] ==
             %{"thinkingConfig" => %{"thinkingBudget" => 512}}

    assert encode(text_request(reasoning: %Reasoning{effort: :none})).body["generationConfig"] ==
             %{"thinkingConfig" => %{"thinkingBudget" => 0}}

    assert {:error, %Error{kind: :validation}} =
             GenerateContent.encode_request(
               text_request(reasoning: %Reasoning{effort: :medium}),
               %Config{}
             )

    assert {:error, %Error{kind: :validation}} =
             GenerateContent.encode_request(
               text_request(reasoning: %Reasoning{effort: :high, budget_tokens: 512}),
               %Config{}
             )
  end

  test "streaming switches the path and adds alt=sse" do
    encoded = encode(text_request(stream: true))
    assert encoded.path == "/v1beta/models/gemini-2.5-pro:streamGenerateContent"
    assert encoded.query == %{"alt" => "sse"}
    refute Map.has_key?(encoded.body, "stream")
  end

  test "images and files map to inlineData and fileData" do
    messages = [
      %Message{
        role: :user,
        content: [
          %Content.Image{source: {:base64, "AAA"}, media_type: "image/png"},
          %Content.File{
            source: {:url, "https://example.com/a.pdf"},
            media_type: "application/pdf"
          }
        ]
      }
    ]

    assert encode(text_request(messages: messages)).body["contents"]
           |> hd()
           |> Map.fetch!("parts") == [
             %{"inlineData" => %{"mimeType" => "image/png", "data" => "AAA"}},
             %{
               "fileData" => %{
                 "mimeType" => "application/pdf",
                 "fileUri" => "https://example.com/a.pdf"
               }
             }
           ]
  end

  test "provider_options accept the :google alias and reject reserved keys" do
    assert encode(text_request(provider_options: %{google: %{"safetySettings" => []}})).body[
             "safetySettings"
           ] == []

    assert {:error, %Error{kind: :validation}} =
             GenerateContent.encode_request(
               text_request(provider_options: %{gemini: %{"contents" => []}}),
               %Config{}
             )
  end

  test "unsupported canonical values are validation errors, never silent drops" do
    cases = [
      text_request(params: %{seed: 1}),
      text_request(tools: [%ToolSpec{kind: :builtin, name: "google_search"}]),
      text_request(output: {:json_schema, "x", %{}, true}),
      text_request(
        messages: [%Message{role: :user, content: [%Content.Image{source: {:file_id, "f"}}]}]
      ),
      text_request(
        messages: [%Message{role: :user, content: [%Content.Image{source: {:base64, "AAA"}}]}]
      ),
      text_request(
        messages: [
          %Message{role: :assistant, content: [%ToolCall{name: "f", raw_arguments: "{"}]}
        ]
      ),
      text_request(reasoning: %Reasoning{summary: :auto}),
      text_request(tools: [], tool_choice: :required),
      %Request{model: "m", messages: []}
    ]

    for request <- cases do
      assert {:error, %Error{kind: :validation, message: message}} =
               GenerateContent.validate_request(request, %Config{})

      assert is_binary(message)

      assert {:error, %Error{kind: :validation}} =
               GenerateContent.encode_request(request, %Config{})
    end
  end

  defp stream_state(config \\ %Config{}) do
    assert {:ok, state} = GenerateContent.init_stream(text_request(stream: true), config)
    state
  end

  defp run_stream(chunks, config \\ %Config{}) do
    Enum.reduce(chunks, {stream_state(config), []}, fn chunk, {state, acc} ->
      {:ok, events, state} = GenerateContent.decode_stream_event(chunk, config, state)
      {state, acc ++ events}
    end)
  end

  describe "decode" do
    test "decodes text parts, usage and stop reason" do
      assert {:ok, response} = GenerateContent.decode_response(Fx.text_response(), %Config{})
      assert response.id == "resp-1"
      assert response.model == "gemini-2.5-pro"
      assert response.stop_reason == :end_turn
      assert LlmDialect.Response.text(response) == "Hello"

      assert response.usage == %LlmDialect.Usage{
               input_tokens: 12,
               output_tokens: 5,
               total_tokens: 17,
               cache_read_tokens: 3,
               cache_write_tokens: nil,
               reasoning_tokens: 2
             }
    end

    test "functionCall parts become ToolCall values with a decoded args map" do
      {:ok, response} = GenerateContent.decode_response(Fx.tool_response(), %Config{})
      assert response.stop_reason == :tool_calls

      assert [
               %ToolCall{
                 id: nil,
                 name: "get_weather",
                 arguments: %{"city" => "Oslo"},
                 raw_arguments: nil
               }
             ] = LlmDialect.Response.tool_calls(response)
    end

    test "thought parts, inlineData and unknown parts are preserved" do
      {:ok, response} = GenerateContent.decode_response(Fx.mixed_response(), %Config{})

      assert [
               %Content.Thinking{text: "hmm", signature: "ts"},
               %Content.Text{text: "Hi"},
               %Content.Image{source: {:base64, "AAA"}, media_type: "image/png"},
               %Content.Raw{type: "executableCode"}
             ] = response.content
    end

    test "finish reasons map to canonical stop reasons" do
      for {wire, canonical} <- [
            {"STOP", :end_turn},
            {"MAX_TOKENS", :max_tokens},
            {"SAFETY", :content_filter},
            {"RECITATION", :content_filter},
            {"OTHER", :unknown},
            {"MALFORMED_FUNCTION_CALL", :unknown}
          ] do
        assert {:ok, %{stop_reason: ^canonical}} =
                 GenerateContent.decode_response(Fx.response_with_finish(wire), %Config{})
      end

      assert {:ok, %{stop_reason: :content_filter}} =
               GenerateContent.decode_response(Fx.blocked_response(), %Config{})
    end

    test "extra candidates are preserved as Raw content" do
      {:ok, response} = GenerateContent.decode_response(Fx.two_candidates_response(), %Config{})
      assert [%Content.Text{text: "first"}, %Content.Raw{type: "candidate"}] = response.content
    end

    test "capture_raw and invalid payloads behave as specified" do
      payload = Fx.text_response()

      assert {:ok, %{raw: ^payload}} =
               GenerateContent.decode_response(payload, %Config{capture_raw: :response})

      assert {:ok, %{raw: nil}} = GenerateContent.decode_response(payload, %Config{})

      assert {:error, %Error{kind: :invalid_response}} =
               GenerateContent.decode_response(%{"nope" => 1}, %Config{})

      assert {:error, %Error{kind: :invalid_response}} =
               GenerateContent.decode_response(%{"candidates" => [%{}]}, %Config{})
    end

    test "decode_error/2 normalizes the Google error envelope" do
      payload = Fx.error_payload()

      assert %Error{
               kind: :provider,
               message: "Quota exceeded",
               code: "RESOURCE_EXHAUSTED",
               status: nil,
               retryable?: true,
               raw: ^payload
             } = GenerateContent.decode_error(payload, %Config{})

      assert %Error{kind: :invalid_response, raw: nil} =
               GenerateContent.decode_error(%{"weird" => 1}, %Config{})
    end

    test "capabilities/2 declares the Gemini surface" do
      caps = GenerateContent.capabilities(text_request(), %Config{})

      assert %LlmDialect.Capabilities{
               tools: true,
               parallel_tool_calls: true,
               tool_choice: true,
               structured_output: :json_schema,
               image_input: true,
               file_input: true,
               streaming_tool_calls: true,
               prompt_cache: true,
               stateful: false,
               streaming: true
             } = caps

      assert %LlmDialect.ReasoningCapabilities{
               efforts: [:none, :low, :high],
               budget_tokens: true,
               adaptive: false,
               summary: []
             } = caps.reasoning
    end
  end

  describe "stream" do
    test "text chunks emit deltas and finish_stream flushes usage and stop" do
      {state, events} = run_stream(Fx.text_chunks())
      assert Enum.map(events, & &1.type) == [:text_delta, :text_delta, :message_delta]

      assert Enum.map(Enum.filter(events, &(&1.type == :text_delta)), & &1.delta.text) == [
               "Hel",
               "lo"
             ]

      assert %LlmDialect.StreamDelta.MessageDelta{stop_reason: :end_turn} =
               List.last(events).delta

      assert {:ok,
              [
                %LlmDialect.StreamEvent{
                  type: :message_delta,
                  delta: %LlmDialect.StreamDelta.MessageDelta{
                    usage: %LlmDialect.Usage{total_tokens: 17}
                  }
                },
                %LlmDialect.StreamEvent{type: :message_stop}
              ], state} = GenerateContent.finish_stream(state, %Config{})

      assert state |> LlmDialect.StreamState.data() |> Map.fetch!(:finished?) == true
      assert {:ok, [], _state} = GenerateContent.finish_stream(state, %Config{})
    end

    test "functionCall parts emit a complete start/delta/stop triple and assemble" do
      {_state, events} = run_stream(Fx.tool_chunks())
      assert Enum.map(events, & &1.type) == [:tool_call_start, :tool_call_delta, :tool_call_stop]

      assembler = LlmDialect.StreamAssembler.new(json_decoder: &LlmDialect.TestJSON.decode/1)

      {_assembler, calls} =
        Enum.reduce(events, {assembler, []}, fn event, {assembler, acc} ->
          {:ok, assembler, new} = LlmDialect.StreamAssembler.feed(assembler, event)
          {assembler, acc ++ new}
        end)

      assert [
               %ToolCall{
                 id: nil,
                 name: "get_weather",
                 arguments: %{"city" => "Oslo"},
                 index: 0
               }
             ] = calls
    end

    test "two function calls get distinct indexes" do
      {_state, events} = run_stream(Fx.two_tool_chunks())

      assert Enum.map(Enum.filter(events, &(&1.type == :tool_call_start)), & &1.index) == [0, 1]
    end

    test "thought text emits thinking deltas and capture_raw :all keeps the chunk" do
      chunk = Fx.thought_chunk()

      assert {:ok,
              [
                %LlmDialect.StreamEvent{
                  type: :thinking_delta,
                  delta: %LlmDialect.StreamDelta.Thinking{text: "hmm"},
                  raw: ^chunk
                }
              ], _} =
               GenerateContent.decode_stream_event(
                 chunk,
                 %Config{capture_raw: :all},
                 stream_state(%Config{capture_raw: :all})
               )

      assert {:ok, [%LlmDialect.StreamEvent{raw: nil}], _} =
               GenerateContent.decode_stream_event(chunk, %Config{}, stream_state())
    end

    test "error chunks become typed errors and unknown chunks are Raw message deltas" do
      assert {:error, %Error{kind: :provider}} =
               GenerateContent.decode_stream_event(
                 %{"error" => Fx.error_payload()["error"]},
                 %Config{},
                 stream_state()
               )

      assert {:ok,
              [
                %LlmDialect.StreamEvent{
                  type: :message_delta,
                  delta: %LlmDialect.StreamDelta.Raw{}
                }
              ], _} =
               GenerateContent.decode_stream_event(%{"foo" => "bar"}, %Config{}, stream_state())
    end
  end

  describe "review fixes" do
    test "role rules reject parts that cannot appear in that turn" do
      cases = [
        [%Message{role: :user, content: [%ToolCall{name: "f", arguments: %{}}]}],
        [%Message{role: :assistant, content: [%ToolResult{name: "f", content: "x"}]}],
        [%Message{role: :user, content: []}],
        [%Message{role: :assistant, content: []}],
        [%Message{role: :user, content: [%Content.Thinking{text: "t"}]}]
      ]

      for messages <- cases do
        assert {:error, %Error{kind: :validation}} =
                 GenerateContent.validate_request(text_request(messages: messages), %Config{})

        assert {:error, %Error{kind: :validation}} =
                 GenerateContent.encode_request(text_request(messages: messages), %Config{})
      end
    end

    test "a thinking signature round-trips as thoughtSignature" do
      messages = [
        %Message{role: :assistant, content: [%Content.Thinking{text: "hmm", signature: "ts"}]}
      ]

      assert encode(text_request(messages: messages)).body["contents"]
             |> hd()
             |> Map.fetch!("parts") == [
               %{"text" => "hmm", "thought" => true, "thoughtSignature" => "ts"}
             ]
    end

    test "reasoning and tool provider options are merged into their native locations" do
      reasoning = %Reasoning{effort: :high, provider_options: %{"includeThoughts" => true}}

      assert encode(text_request(reasoning: reasoning)).body["generationConfig"] == %{
               "thinkingConfig" => %{"thinkingLevel" => "high", "includeThoughts" => true}
             }

      tools = [%ToolSpec{name: "f", provider_options: %{"behavior" => "BLOCKING"}}]

      assert encode(text_request(tools: tools)).body["tools"]
             |> hd()
             |> Map.fetch!("functionDeclarations")
             |> hd()
             |> Map.fetch!("behavior") == "BLOCKING"
    end

    test "strict tools are rejected when the protocol cannot express them" do
      tools = [%ToolSpec{name: "f", strict: true}]

      assert {:error, %Error{kind: :validation}} =
               GenerateContent.validate_request(text_request(tools: tools), %Config{})

      assert {:error, %Error{kind: :validation}} =
               GenerateContent.encode_request(text_request(tools: tools), %Config{})
    end

    test "a multi-key unknown part is preserved as Raw instead of raising" do
      payload =
        put_in(
          Fx.text_response(),
          ["candidates", Access.at(0), "content", "parts"],
          [%{"executableCode" => %{"code" => "1"}, "partMetadata" => %{"k" => "v"}}]
        )

      assert {:ok, response} = GenerateContent.decode_response(payload, %Config{})

      assert [%Content.Raw{type: "executableCode", data: %{"partMetadata" => _}}] =
               response.content
    end

    test "a safety-blocked candidate without content is a filtered response, not an error" do
      payload = %{
        "candidates" => [%{"finishReason" => "SAFETY", "index" => 0}],
        "modelVersion" => "gemini-2.5-pro"
      }

      assert {:ok, %{stop_reason: :content_filter, content: []}} =
               GenerateContent.decode_response(payload, %Config{})
    end

    test "a function call in an earlier chunk keeps stop_reason tool_calls" do
      chunks =
        Fx.tool_chunks() ++ [%{"candidates" => [%{"finishReason" => "STOP", "index" => 0}]}]

      {_state, events} = run_stream(chunks)

      assert %LlmDialect.StreamDelta.MessageDelta{stop_reason: :tool_calls} =
               List.last(events).delta
    end
  end

  describe "deferred minors" do
    test "an empty system part list sends no systemInstruction" do
      refute Map.has_key?(encode(text_request(system: [])).body, "systemInstruction")
    end

    test "model ids that would break the request path are rejected" do
      for model <- ["models/gemini-2.5-pro", "gemini-2.5-pro:generateContent", "tunedModels/x"] do
        assert {:error, %Error{kind: :validation}} =
                 GenerateContent.validate_request(text_request(model: model), %Config{})

        assert {:error, %Error{kind: :validation}} =
                 GenerateContent.encode_request(text_request(model: model), %Config{})
      end
    end
  end

  describe "modalities" do
    test "image output maps to responseModalities and merges into generationConfig" do
      body = encode(text_request(modalities: [:text, :image])).body
      assert body["generationConfig"] == %{"responseModalities" => ["TEXT", "IMAGE"]}

      body = encode(text_request(modalities: [:text, :image], params: %{temperature: 0.2})).body

      assert body["generationConfig"] == %{
               "temperature" => 0.2,
               "responseModalities" => ["TEXT", "IMAGE"]
             }

      refute Map.has_key?(
               encode(text_request()).body["generationConfig"] || %{},
               "responseModalities"
             )
    end

    test "video needs the long-running path and image output cannot be streamed" do
      for modalities <- [[:video], [:text, :video]] do
        assert {:error, %Error{kind: :validation}} =
                 GenerateContent.validate_request(text_request(modalities: modalities), %Config{})
      end

      streamed = text_request(modalities: [:text, :image], stream: true)

      assert {:error, %Error{kind: :validation, message: message}} =
               GenerateContent.validate_request(streamed, %Config{})

      assert message =~ "stream"

      assert {:error, %Error{kind: :validation}} =
               GenerateContent.init_stream(streamed, %Config{})
    end

    test "malformed modality lists are rejected" do
      for modalities <- [[], [:text, :text], [:audio], :text] do
        assert {:error, %Error{kind: :validation}} =
                 GenerateContent.validate_request(text_request(modalities: modalities), %Config{})
      end
    end

    test "capabilities declare text and image output" do
      assert GenerateContent.capabilities(text_request(), %Config{}).modalities ==
               [:text, :image]
    end
  end
end

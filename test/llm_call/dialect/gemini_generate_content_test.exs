defmodule LlmCall.Dialect.GeminiGenerateContentTest do
  use ExUnit.Case, async: true

  alias LlmCall.Dialect.Gemini.GenerateContent

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

  alias LlmCall.Fixtures.GeminiGenerateContent, as: Fx

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
    assert %LlmCall.Codec.Info{
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
        parameters: %{"type" => "OBJECT"}
      }
    ]

    body = encode(text_request(tools: tools, tool_choice: :required)).body

    assert body["tools"] == [
             %{
               "functionDeclarations" => [
                 %{
                   "name" => "get_weather",
                   "description" => "Get weather",
                   "parameters" => %{"type" => "OBJECT"}
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

  test "rejects tool schemas Gemini cannot express" do
    cases = [
      {%{"type" => "object"}, "must be uppercase"},
      {%{"type" => "OBJECT", "additionalProperties" => false}, "additionalProperties"},
      {%{"type" => "OBJECT", "properties" => %{"x" => %{"$ref" => "#/$defs/x"}}}, "$ref"},
      {%{"type" => "OBJECT", "$defs" => %{}}, "$defs"},
      {%{"type" => "OBJECT", "properties" => %{"x" => %{"prefixItems" => []}}}, "prefixItems"},
      {%{"type" => "OBJECT", "properties" => %{"x" => %{"oneOf" => []}}}, "oneOf"},
      {%{"type" => "OBJECT", "properties" => %{"x" => %{"const" => 1}}}, "const"}
    ]

    for {schema, expected} <- cases do
      assert {:error, %Error{kind: :validation, message: message}} =
               GenerateContent.validate_request(
                 text_request(tools: [%ToolSpec{name: "f", parameters: schema}]),
                 %Config{}
               )

      assert message =~ expected
    end
  end

  test "accepts already-projected tool schemas" do
    schema = %{
      "type" => "OBJECT",
      "properties" => %{
        "city" => %{"type" => "STRING"},
        "type" => %{"type" => "STRING"}
      },
      "required" => ["city"]
    }

    assert :ok ==
             GenerateContent.validate_request(
               text_request(tools: [%ToolSpec{name: "f", parameters: schema}]),
               %Config{}
             )
  end

  test "rejects response schemas Gemini cannot express" do
    cases = [
      {%{"type" => "object"}, "must be uppercase"},
      {%{"type" => "OBJECT", "additionalProperties" => false}, "additionalProperties"},
      {%{"type" => "OBJECT", "properties" => %{"x" => %{"$ref" => "#/$defs/x"}}}, "$ref"},
      {%{"type" => "OBJECT", "$defs" => %{}}, "$defs"},
      {%{"type" => "OBJECT", "properties" => %{"x" => %{"prefixItems" => []}}}, "prefixItems"},
      {%{"type" => "OBJECT", "properties" => %{"x" => %{"oneOf" => []}}}, "oneOf"},
      {%{"type" => "OBJECT", "properties" => %{"x" => %{"const" => 1}}}, "const"}
    ]

    for {schema, expected} <- cases do
      assert {:error, %Error{kind: :validation, message: message}} =
               GenerateContent.validate_request(
                 text_request(output: {:json_schema, "result", schema, nil}),
                 %Config{}
               )

      assert message =~ expected
    end
  end

  test "accepts already-projected response schemas" do
    schema = %{
      "type" => "OBJECT",
      "properties" => %{"city" => %{"type" => "STRING"}},
      "required" => ["city"]
    }

    assert :ok ==
             GenerateContent.validate_request(
               text_request(output: {:json_schema, "result", schema, nil}),
               %Config{}
             )
  end

  test "allowed tool names must be non-empty strings" do
    tools = [%ToolSpec{name: "get_weather"}]

    for names <- [["get_weather", 1], [""], [nil]] do
      assert {:error, %Error{kind: :validation, message: message}} =
               GenerateContent.validate_request(
                 text_request(tools: tools, tool_choice: {:allowed, names}),
                 %Config{}
               )

      assert message =~ "allowed"
    end
  end

  test "params and output map into generationConfig" do
    body =
      encode(
        text_request(
          params: %{temperature: 0.2, top_p: 0.9, top_k: 40, max_tokens: 128, stop: ["END"]},
          output: {:json_schema, "person", %{"type" => "OBJECT"}, nil}
        )
      ).body

    assert body["generationConfig"] == %{
             "temperature" => 0.2,
             "topP" => 0.9,
             "topK" => 40,
             "maxOutputTokens" => 128,
             "stopSequences" => ["END"],
             "responseMimeType" => "application/json",
             "responseSchema" => %{"type" => "OBJECT"}
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

  test "known native provider options are type-checked" do
    assert {:error, %Error{kind: :validation, message: message}} =
             GenerateContent.validate_request(
               text_request(provider_options: %{gemini: %{"safetySettings" => "bad"}}),
               %Config{}
             )

    assert message =~ "safetySettings"

    assert :ok ==
             GenerateContent.validate_request(
               text_request(provider_options: %{gemini: %{"safetySettings" => []}}),
               %Config{}
             )
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

  test "reasoning provider_options deep-merge into generationConfig" do
    body =
      encode(
        text_request(
          params: %{temperature: 0.2},
          reasoning: %Reasoning{
            provider_options: %{"includeThoughts" => true}
          }
        )
      ).body

    assert body["generationConfig"] == %{
             "temperature" => 0.2,
             "thinkingConfig" => %{"includeThoughts" => true}
           }
  end

  test "the :google alias merges with :gemini, and the request wins over config defaults" do
    body =
      encode(
        text_request(
          provider_options: %{
            google: %{"safetySettings" => [%{"category" => "HARM"}]},
            gemini: %{"cachedContent" => "cache-1"}
          }
        )
      ).body

    assert body["safetySettings"] == [%{"category" => "HARM"}]
    assert body["cachedContent"] == "cache-1"

    config = %Config{
      default_provider_options: %{
        gemini: %{"labels" => %{"team" => "default", "env" => "prod"}}
      }
    }

    request = text_request(provider_options: %{google: %{"labels" => %{"team" => "request"}}})

    assert encode(request, config).body["labels"] == %{
             "team" => "request",
             "env" => "prod"
           }
  end

  test "the configured JSON module encodes streamed function-call arguments" do
    chunk = %{
      "candidates" => [
        %{
          "content" => %{
            "parts" => [%{"functionCall" => %{"name" => "f", "args" => %{"a" => 1}}}]
          },
          "index" => 0
        }
      ]
    }

    {:ok, _state, events} =
      GenerateContent.init_stream(text_request(stream: true), %Config{json: LlmCall.MarkerJSON})
      |> case do
        {:ok, state} ->
          case GenerateContent.decode_stream_event(
                 chunk,
                 %Config{json: LlmCall.MarkerJSON},
                 state
               ) do
            {:ok, events, state} -> {:ok, state, events}
            other -> other
          end
      end

    delta = Enum.find(events, &(&1.type == :tool_call_start)).delta
    assert String.starts_with?(delta.arguments, "MARKER:")
  end

  test "hosted tools pass through as their provider key" do
    tools = [
      %ToolSpec{name: "f", parameters: %{"type" => "OBJECT"}},
      %ToolSpec{kind: :builtin, name: "google_search"}
    ]

    body = encode(text_request(tools: tools)).body

    assert [%{"functionDeclarations" => [_declaration]}, %{"google_search" => %{}}] =
             body["tools"]
  end

  test "the provider_options container is validated" do
    for options <- [nil, "not-a-map"] do
      assert {:error, %Error{kind: :validation, message: message}} =
               GenerateContent.validate_request(
                 text_request(provider_options: options),
                 %Config{}
               )

      assert message =~ "provider_options must be a map"
    end

    assert {:error, %Error{kind: :validation, message: message}} =
             GenerateContent.validate_request(
               text_request(provider_options: %{gemini: "not-a-map"}),
               %Config{}
             )

    assert message =~ "gemini must be a map"

    assert {:error, %Error{kind: :validation, message: message}} =
             GenerateContent.validate_request(
               text_request(provider_options: %{deepseek: %{}}),
               %Config{}
             )

    assert message =~ "is not used by this codec"
  end

  test "malformed json_schema output is rejected" do
    for output <- [
          {:json_schema, nil, %{}, nil},
          {:json_schema, "", %{}, nil},
          {:json_schema, "x", %{}, "strict"}
        ] do
      assert {:error, %Error{kind: :validation}} =
               GenerateContent.validate_request(text_request(output: output), %Config{})
    end
  end

  test "generationConfig may add native knobs but not canonical ones" do
    body =
      encode(
        text_request(
          params: %{temperature: 0.2},
          provider_options: %{
            gemini: %{"generationConfig" => %{"candidateCount" => 2, "seed" => 7}}
          }
        )
      ).body

    assert body["generationConfig"] == %{
             "temperature" => 0.2,
             "candidateCount" => 2,
             "seed" => 7
           }

    for key <- ["temperature", "responseMimeType", "responseModalities", "thinkingConfig"] do
      assert {:error, %Error{kind: :validation, message: message}} =
               GenerateContent.validate_request(
                 text_request(provider_options: %{gemini: %{"generationConfig" => %{key => 1}}}),
                 %Config{}
               )

      assert message =~ "canonical field"
    end

    assert {:error, %Error{kind: :validation, message: message}} =
             GenerateContent.validate_request(
               text_request(provider_options: %{gemini: %{"generationConfig" => "x"}}),
               %Config{}
             )

    assert message =~ "generationConfig must be a map"
  end

  test "reasoning provider_options cannot replace the canonical thinking config" do
    assert {:error, %Error{kind: :validation, message: message}} =
             GenerateContent.validate_request(
               text_request(
                 reasoning: %Reasoning{
                   effort: :high,
                   provider_options: %{"thinkingLevel" => "low"}
                 }
               ),
               %Config{}
             )

    assert message =~ "canonical field"
  end

  test "a shared Config may carry defaults for other providers" do
    assert :ok ==
             GenerateContent.validate_request(text_request(), %Config{
               default_provider_options: %{openai: %{"logprobs" => true}}
             })

    assert {:error, %Error{kind: :validation}} =
             GenerateContent.validate_request(
               text_request(provider_options: %{openai: %{}}),
               %Config{}
             )
  end

  test "the json_schema name is a caller-side label Gemini drops" do
    body = encode(text_request(output: {:json_schema, "person", %{"type" => "OBJECT"}, nil})).body

    assert body["generationConfig"] == %{
             "responseMimeType" => "application/json",
             "responseSchema" => %{"type" => "OBJECT"}
           }
  end

  test "native generationConfig keys land beside the canonical values" do
    body =
      encode(
        text_request(
          params: %{temperature: 0.2},
          provider_options: %{
            gemini: %{"generationConfig" => %{"candidateCount" => 2, "seed" => 7}}
          }
        )
      ).body

    assert body["generationConfig"] == %{
             "temperature" => 0.2,
             "candidateCount" => 2,
             "seed" => 7
           }

    tools = [
      %ToolSpec{
        name: "f",
        parameters: %{"type" => "OBJECT"},
        provider_options: %{"name" => "shadow"}
      }
    ]

    assert {:error, %Error{kind: :validation, message: message}} =
             GenerateContent.validate_request(text_request(tools: tools), %Config{})

    assert message =~ "canonical field"
  end

  test "the provider_options envelope is reserved, but native knobs stay reachable" do
    for options <- [
          %{gemini: %{"contents" => []}},
          %{gemini: %{"systemInstruction" => %{}}},
          %{gemini: %{"toolConfig" => %{}}}
        ] do
      assert {:error, %Error{kind: :validation, message: message}} =
               GenerateContent.validate_request(
                 text_request(provider_options: options),
                 %Config{}
               )

      assert message =~ "canonical field"
    end

    assert :ok ==
             GenerateContent.validate_request(
               text_request(
                 provider_options: %{
                   gemini: %{
                     "generationConfig" => %{
                       "candidateCount" => 2,
                       "seed" => 7,
                       "frequencyPenalty" => 0.5
                     }
                   }
                 }
               ),
               %Config{}
             )

    assert {:error, %Error{kind: :validation, message: message}} =
             GenerateContent.validate_request(text_request(), %Config{
               default_provider_options: %{
                 gemini: %{"generationConfig" => %{"temperature" => 0.9}}
               }
             })

    assert message =~ "canonical field"
  end

  test "unsupported canonical values are validation errors, never silent drops" do
    cases = [
      text_request(params: %{seed: 1}),
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
      assert LlmCall.Response.text(response) == "Hello"

      assert response.usage == %LlmCall.Usage{
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
             ] = LlmCall.Response.tool_calls(response)
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
            {"CONTINUATION", :max_tokens},
            {"SAFETY", :content_filter},
            {"RECITATION", :content_filter},
            {"LANGUAGE", :content_filter},
            {"BLOCKLIST", :content_filter},
            {"PROHIBITED_CONTENT", :content_filter},
            {"SPII", :content_filter},
            {"IMAGE_SAFETY", :content_filter},
            {"IMAGE_PROHIBITED_CONTENT", :content_filter},
            {"IMAGE_RECITATION", :content_filter},
            {"ESCALATION", :content_filter},
            {"MALFORMED_FUNCTION_CALL", :error},
            {"UNEXPECTED_TOOL_CALL", :error},
            {"TOO_MANY_TOOL_CALLS", :error},
            {"MISSING_THOUGHT_SIGNATURE", :error},
            {"MALFORMED_RESPONSE", :error},
            {"NO_IMAGE", :error},
            {"IMAGE_OTHER", :error},
            {"PUP_LIMITED_DISABLED", :error},
            {"FINISH_REASON_UNSPECIFIED", :unknown},
            {"OTHER", :unknown},
            {"A_REASON_FROM_THE_FUTURE", :unknown}
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
             } = GenerateContent.decode_error(payload, %Config{capture_raw: :response})

      assert %Error{kind: :provider, raw: nil} =
               GenerateContent.decode_error(payload, %Config{capture_raw: :none})

      unknown = %{"weird" => 1}

      assert %Error{kind: :invalid_response, raw: ^unknown} =
               GenerateContent.decode_error(unknown, %Config{capture_raw: :response})

      assert %Error{kind: :invalid_response, raw: nil} =
               GenerateContent.decode_error(unknown, %Config{capture_raw: :none})
    end

    test "capabilities/2 declares the Gemini surface" do
      caps = GenerateContent.capabilities(text_request(), %Config{})

      assert %LlmCall.Capabilities{
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

      assert %LlmCall.Reasoning.Capabilities{
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

      assert %LlmCall.StreamDelta.MessageDelta{stop_reason: :end_turn} =
               List.last(events).delta

      assert {:ok,
              [
                %LlmCall.StreamEvent{
                  type: :message_delta,
                  delta: %LlmCall.StreamDelta.MessageDelta{
                    usage: %LlmCall.Usage{total_tokens: 17}
                  }
                },
                %LlmCall.StreamEvent{type: :message_stop}
              ], state} = GenerateContent.finish_stream(state, %Config{})

      assert state |> LlmCall.StreamState.data() |> Map.fetch!(:finished?) == true
      assert {:ok, [], _state} = GenerateContent.finish_stream(state, %Config{})
    end

    test "functionCall parts emit a complete start/delta/stop triple and assemble" do
      {_state, events} = run_stream(Fx.tool_chunks())
      assert Enum.map(events, & &1.type) == [:tool_call_start, :tool_call_delta, :tool_call_stop]

      assembler = LlmCall.StreamAssembler.new(json_decoder: &LlmCall.TestJSON.decode/1)

      {_assembler, calls} =
        Enum.reduce(events, {assembler, []}, fn event, {assembler, acc} ->
          {:ok, assembler, new} = LlmCall.StreamAssembler.feed(assembler, event)
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
                %LlmCall.StreamEvent{
                  type: :thinking_delta,
                  delta: %LlmCall.StreamDelta.Thinking{text: "hmm"},
                  raw: ^chunk
                }
              ], _} =
               GenerateContent.decode_stream_event(
                 chunk,
                 %Config{capture_raw: :all},
                 stream_state(%Config{capture_raw: :all})
               )

      assert {:ok, [%LlmCall.StreamEvent{raw: nil}], _} =
               GenerateContent.decode_stream_event(chunk, %Config{}, stream_state())
    end

    test "streamed usage accumulates across chunks instead of being replaced" do
      chunks = [
        %{
          "candidates" => [
            %{"content" => %{"parts" => [%{"text" => "Hi"}]}, "index" => 0}
          ],
          "usageMetadata" => %{"promptTokenCount" => 10}
        },
        %{
          "candidates" => [
            %{"content" => %{"parts" => [%{"text" => " there"}]}, "index" => 0}
          ],
          "usageMetadata" => %{"candidatesTokenCount" => 4}
        },
        %{
          "candidates" => [
            %{"content" => %{"parts" => []}, "finishReason" => "STOP", "index" => 0}
          ],
          "usageMetadata" => %{"totalTokenCount" => 14}
        }
      ]

      {state, _events} = run_stream(chunks)

      assert {:ok,
              [
                %LlmCall.StreamEvent{
                  type: :message_delta,
                  delta: %LlmCall.StreamDelta.MessageDelta{
                    usage: %LlmCall.Usage{
                      input_tokens: 10,
                      output_tokens: 4,
                      total_tokens: 14
                    }
                  }
                },
                %LlmCall.StreamEvent{type: :message_stop}
              ], _state} = GenerateContent.finish_stream(state, %Config{})
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
                %LlmCall.StreamEvent{
                  type: :message_delta,
                  delta: %LlmCall.StreamDelta.Raw{}
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

      assert %LlmCall.StreamDelta.MessageDelta{stop_reason: :tool_calls} =
               List.last(events).delta
    end
  end

  describe "deferred minors" do
    test "an empty system part list sends no systemInstruction" do
      refute Map.has_key?(encode(text_request(system: [])).body, "systemInstruction")
    end

    test "model ids that would break the request path are rejected" do
      for model <- [
            "models/gemini-2.5-pro",
            "gemini-2.5-pro:generateContent",
            "tunedModels/x",
            "gemini-2.5-pro?alt=json",
            "gemini-2.5-pro#fragment",
            "gemini 2.5 pro",
            "gemini%2Fpro"
          ] do
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
        assert {:error, %Error{kind: :validation, message: message}} =
                 GenerateContent.validate_request(text_request(modalities: modalities), %Config{})

        assert message =~ "predict path"
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

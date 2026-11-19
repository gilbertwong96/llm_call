defmodule LlmCall.Protocol.OpenAIChatTest do
  use ExUnit.Case, async: true

  alias LlmCall.Protocol.OpenAI.Chat

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

  alias LlmCall.Fixtures.OpenAIChat, as: Fx

  defp encode(request, config \\ %Config{}) do
    assert {:ok, encoded} = Chat.encode_request(request, config)
    encoded
  end

  defp text_request(overrides \\ []) do
    struct(
      %Request{
        model: "gpt-4o",
        messages: [%Message{role: :user, content: [%Content.Text{text: "Hello"}]}]
      },
      overrides
    )
  end

  test "info/0 declares the protocol and IR version" do
    assert %LlmCall.Codec.Info{name: :openai_chat, protocol: :openai_chat, ir_version: 1} =
             Chat.info()
  end

  test "encodes a minimal text request" do
    encoded = encode(text_request())
    assert encoded.method == :post
    assert encoded.path == "/v1/chat/completions"
    assert encoded.query == %{}
    assert encoded.headers == [{"content-type", "application/json"}]

    assert encoded.body == %{
             "model" => "gpt-4o",
             "messages" => [
               %{"role" => "user", "content" => [%{"type" => "text", "text" => "Hello"}]}
             ]
           }
  end

  test "system string and system parts both become a leading system message" do
    assert encode(text_request(system: "Be terse.")).body["messages"] |> hd() ==
             %{"role" => "system", "content" => "Be terse."}

    system = [%Content.Text{text: "Be "}, %Content.Text{text: "terse."}]

    assert encode(text_request(system: system)).body["messages"] |> hd() == %{
             "role" => "system",
             "content" => [
               %{"type" => "text", "text" => "Be "},
               %{"type" => "text", "text" => "terse."}
             ]
           }
  end

  test "assistant tool calls encode arguments as a JSON string and content as null" do
    messages = [
      %Message{role: :user, content: [%Content.Text{text: "weather?"}]},
      %Message{
        role: :assistant,
        content: [%ToolCall{id: "call_1", name: "get_weather", arguments: %{"city" => "Oslo"}}]
      }
    ]

    body = encode(text_request(messages: messages)).body

    assert Enum.at(body["messages"], 1) == %{
             "role" => "assistant",
             "content" => nil,
             "tool_calls" => [
               %{
                 "id" => "call_1",
                 "type" => "function",
                 "function" => %{"name" => "get_weather", "arguments" => ~s({"city":"Oslo"})}
               }
             ]
           }
  end

  test "raw_arguments win over the decoded arguments map" do
    messages = [
      %Message{
        role: :assistant,
        content: [
          %ToolCall{
            id: "call_1",
            name: "f",
            arguments: %{"a" => 1},
            raw_arguments: ~s({ "a" : 1 })
          }
        ]
      }
    ]

    call =
      encode(text_request(messages: messages)).body["messages"]
      |> hd()
      |> Map.fetch!("tool_calls")
      |> hd()

    assert call["function"]["arguments"] == ~s({ "a" : 1 })
  end

  test "tool results become role: tool messages placed before remaining user content" do
    messages = [
      %Message{
        role: :user,
        content: [
          %ToolResult{
            call_id: "call_1",
            name: "get_weather",
            content: [%Content.Text{text: "Sunny"}],
            is_error: false
          },
          %Content.Text{text: "thanks"}
        ]
      }
    ]

    assert encode(text_request(messages: messages)).body["messages"] == [
             %{"role" => "tool", "tool_call_id" => "call_1", "content" => "Sunny"},
             %{"role" => "user", "content" => [%{"type" => "text", "text" => "thanks"}]}
           ]
  end

  test "tool result with string content keeps the string" do
    messages = [
      %Message{
        role: :user,
        content: [%ToolResult{call_id: "call_1", content: "boom", is_error: true}]
      }
    ]

    assert encode(text_request(messages: messages)).body["messages"] == [
             %{"role" => "tool", "tool_call_id" => "call_1", "content" => "boom"}
           ]
  end

  test "tools, tool_choice and strict map to the OpenAI envelope" do
    tools = [
      %ToolSpec{
        name: "get_weather",
        description: "Get weather",
        parameters: %{"type" => "object"},
        strict: true
      }
    ]

    body = encode(text_request(tools: tools, tool_choice: {:tool, "get_weather"})).body

    assert body["tools"] == [
             %{
               "type" => "function",
               "function" => %{
                 "name" => "get_weather",
                 "description" => "Get weather",
                 "parameters" => %{"type" => "object"},
                 "strict" => true
               }
             }
           ]

    assert body["tool_choice"] == %{
             "type" => "function",
             "function" => %{"name" => "get_weather"}
           }

    assert encode(text_request(tools: tools, tool_choice: :required)).body["tool_choice"] ==
             "required"

    assert encode(text_request(tools: tools, tool_choice: :none)).body["tool_choice"] == "none"
  end

  test "sampling params and output formats map to native fields" do
    body =
      encode(
        text_request(
          params: %{temperature: 0.2, top_p: 0.9, max_tokens: 64, stop: ["\n"], seed: 7},
          output: {:json_schema, "person", %{"type" => "object"}, true}
        )
      ).body

    assert body["temperature"] == 0.2
    assert body["top_p"] == 0.9
    assert body["max_tokens"] == 64
    assert body["stop"] == ["\n"]
    assert body["seed"] == 7

    assert body["response_format"] == %{
             "type" => "json_schema",
             "json_schema" => %{
               "name" => "person",
               "schema" => %{"type" => "object"},
               "strict" => true
             }
           }

    assert encode(text_request(output: :json_object)).body["response_format"] == %{
             "type" => "json_object"
           }

    refute Map.has_key?(encode(text_request()).body, "response_format")
  end

  test "reasoning effort maps to reasoning_effort and unsupported axes are rejected" do
    assert encode(text_request(reasoning: %Reasoning{effort: :high})).body["reasoning_effort"] ==
             "high"

    assert {:error, %Error{kind: :validation}} =
             Chat.encode_request(text_request(reasoning: %Reasoning{effort: :max}), %Config{})

    assert {:error, %Error{kind: :validation}} =
             Chat.encode_request(
               text_request(reasoning: %Reasoning{budget_tokens: 1024}),
               %Config{}
             )

    assert {:error, %Error{kind: :validation}} =
             Chat.encode_request(text_request(reasoning: %Reasoning{summary: :auto}), %Config{})
  end

  test "stream requests ask OpenAI to include usage" do
    body = encode(text_request(stream: true)).body
    assert body["stream"] == true
    assert body["stream_options"] == %{"include_usage" => true}
    refute Map.has_key?(encode(text_request()).body, "stream")
  end

  test "images encode as image_url parts with data URLs" do
    messages = [
      %Message{
        role: :user,
        content: [
          %Content.Image{source: {:base64, "AAA"}, media_type: "image/png"},
          %Content.Image{source: {:url, "https://example.com/a.png"}}
        ]
      }
    ]

    assert encode(text_request(messages: messages)).body["messages"]
           |> hd()
           |> Map.fetch!("content") == [
             %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,AAA"}},
             %{"type" => "image_url", "image_url" => %{"url" => "https://example.com/a.png"}}
           ]
  end

  test "known native provider options are type-checked" do
    assert {:error, %Error{kind: :validation, message: message}} =
             Chat.validate_request(
               text_request(provider_options: %{openai: %{"logprobs" => "yes"}}),
               %Config{}
             )

    assert message =~ "logprobs"

    assert :ok ==
             Chat.validate_request(
               text_request(provider_options: %{openai: %{"logprobs" => true}}),
               %Config{}
             )
  end

  test "provider_options are merged but reserved keys are rejected" do
    body =
      encode(text_request(provider_options: %{openai: %{"logprobs" => true, "top_k" => 5}})).body

    assert body["logprobs"] == true
    assert body["top_k"] == 5

    assert {:error, %Error{kind: :validation}} =
             Chat.encode_request(
               text_request(provider_options: %{openai: %{"model" => "evil"}}),
               %Config{}
             )
  end

  test "config default provider options apply and the request wins" do
    config = %Config{default_provider_options: %{openai: %{"logprobs" => false, "n" => 1}}}
    request = text_request(provider_options: %{openai: %{"logprobs" => true}})
    body = encode(request, config).body

    assert body["logprobs"] == true
    assert body["n"] == 1
  end

  test "unsupported canonical values are validation errors, never silent drops" do
    cases = [
      text_request(params: %{top_k: 5}),
      text_request(output: :xml),
      text_request(output: {:json_schema, "x", "not-a-map", true}),
      text_request(reasoning: %Reasoning{provider_options: "not-a-map"}),
      text_request(tools: [%ToolSpec{name: "f", provider_options: "not-a-map"}]),
      text_request(tools: [%ToolSpec{kind: :builtin, name: "web_search"}]),
      text_request(tools: [%ToolSpec{name: "f"}], tool_choice: {:allowed, ["f"]}),
      text_request(tools: [], tool_choice: :required),
      text_request(
        messages: [
          %Message{
            role: :user,
            content: [%Content.File{source: {:base64, "AAA"}, media_type: "application/pdf"}]
          }
        ]
      ),
      text_request(
        messages: [%Message{role: :user, content: [%Content.Image{source: {:file_id, "file-1"}}]}]
      ),
      text_request(messages: [%Message{role: :user, content: [%ToolResult{content: "x"}]}]),
      text_request(
        messages: [%Message{role: :assistant, content: [%ToolCall{name: "f", arguments: %{}}]}]
      ),
      text_request(
        messages: [
          %Message{
            role: :user,
            content: [%ToolResult{call_id: "c", content: [%Content.Image{source: {:url, "u"}}]}]
          }
        ]
      ),
      %Request{model: "", messages: [%Message{}]},
      %Request{model: "gpt-4o", messages: []}
    ]

    for request <- cases do
      assert {:error, %Error{kind: :validation, message: message}} =
               Chat.validate_request(request, %Config{})

      assert is_binary(message)
      assert {:error, %Error{kind: :validation}} = Chat.encode_request(request, %Config{})
    end
  end

  test "reasoning and tool provider options cannot replace canonical fields" do
    assert {:error, %Error{kind: :validation, message: message}} =
             Chat.validate_request(
               text_request(reasoning: %Reasoning{provider_options: %{"model" => "evil"}}),
               %Config{}
             )

    assert message =~ "canonical field"

    assert :ok ==
             Chat.validate_request(
               text_request(reasoning: %Reasoning{provider_options: %{"service_tier" => "flex"}}),
               %Config{}
             )

    tools = [
      %ToolSpec{
        name: "f",
        parameters: %{"type" => "object"},
        provider_options: %{"name" => "shadow"}
      }
    ]

    assert {:error, %Error{kind: :validation, message: message}} =
             Chat.validate_request(text_request(tools: tools), %Config{})

    assert message =~ "canonical field"
  end

  test "native request options land beside the canonical body" do
    body =
      encode(
        text_request(
          stream: true,
          provider_options: %{openai: %{"stream_options" => %{"include_obfuscation" => true}}}
        )
      ).body

    assert body["stream_options"] == %{
             "include_usage" => true,
             "include_obfuscation" => true
           }
  end

  test "a present but nil namespace is a typed error, not a raise" do
    for options <- [%{openai: nil}, %{"openai" => %{}}] do
      assert {:error, %Error{kind: :validation}} =
               Chat.validate_request(text_request(provider_options: options), %Config{})
    end

    assert {:error, %Error{kind: :validation}} =
             Chat.validate_request(text_request(), %Config{
               default_provider_options: %{openai: nil}
             })

    assert :ok ==
             Chat.validate_request(text_request(), %Config{
               default_provider_options: %{openai: %{}, anthropic: %{"metadata" => %{}}}
             })
  end

  test "a struct is not a namespace map" do
    assert {:error, %Error{kind: :validation, message: message}} =
             Chat.validate_request(
               text_request(provider_options: %{openai: %Date{year: 2026, month: 1, day: 1}}),
               %Config{}
             )

    assert message =~ "must be a map"
  end

  test "stream_options may add native keys but cannot switch usage off" do
    body =
      encode(
        text_request(
          stream: true,
          provider_options: %{openai: %{"stream_options" => %{"include_obfuscation" => true}}}
        )
      ).body

    assert body["stream_options"] == %{"include_usage" => true, "include_obfuscation" => true}

    assert {:error, %Error{kind: :validation, message: message}} =
             Chat.validate_request(
               text_request(
                 provider_options: %{openai: %{"stream_options" => %{"include_usage" => false}}}
               ),
               %Config{}
             )

    assert message =~ "canonical field"
  end

  test "reasoning options cannot replace or switch off stream_options" do
    body =
      encode(
        text_request(
          stream: true,
          reasoning: %Reasoning{
            effort: :high,
            provider_options: %{"stream_options" => %{"include_obfuscation" => true}}
          }
        )
      ).body

    assert body["stream_options"] == %{"include_usage" => true, "include_obfuscation" => true}

    assert {:error, %Error{kind: :validation, message: message}} =
             Chat.validate_request(
               text_request(
                 reasoning: %Reasoning{
                   effort: :high,
                   provider_options: %{"stream_options" => %{"include_usage" => false}}
                 }
               ),
               %Config{}
             )

    assert message =~ "canonical field"
  end

  test "a config default may add native stream_options keys" do
    body =
      encode(
        text_request(stream: true),
        %Config{
          default_provider_options: %{
            openai: %{"stream_options" => %{"include_obfuscation" => true}}
          }
        }
      ).body

    assert body["stream_options"] == %{"include_usage" => true, "include_obfuscation" => true}

    assert {:error, %Error{kind: :validation, message: message}} =
             Chat.validate_request(text_request(), %Config{
               default_provider_options: %{
                 openai: %{"stream_options" => %{"include_usage" => false}}
               }
             })

    assert message =~ "canonical field"
  end

  test "unencodable tool call arguments are a typed error" do
    messages = [
      %Message{
        role: :assistant,
        content: [%ToolCall{id: "c1", name: "f", arguments: %{"when" => {1, 2}}}]
      }
    ]

    assert {:error, %Error{kind: :validation, message: message}} =
             Chat.validate_request(text_request(messages: messages), %Config{})

    assert message =~ "JSON-encodable"

    atoms = [
      %Message{
        role: :assistant,
        content: [%ToolCall{id: "c1", name: "f", arguments: %{"mode" => :fast}}]
      }
    ]

    assert :ok == Chat.validate_request(text_request(messages: atoms), %Config{})
  end

  test "the configured JSON module encodes tool-call arguments" do
    messages = [
      %Message{
        role: :assistant,
        content: [%ToolCall{id: "c1", name: "f", arguments: %{"city" => "Oslo"}}]
      }
    ]

    body = encode(text_request(messages: messages), %Config{json: LlmCall.MarkerJSON}).body

    assert [%{"function" => %{"arguments" => arguments}}] = hd(body["messages"])["tool_calls"]
    assert String.starts_with?(arguments, "MARKER:")
  end

  test "the configured JSON module decodes tool-call raw arguments" do
    messages = [
      %Message{
        role: :assistant,
        content: [%ToolCall{id: "c1", name: "f", raw_arguments: ~s(MARKER:{"city":"Oslo"})}]
      }
    ]

    body = encode(text_request(messages: messages), %Config{json: LlmCall.MarkerJSON}).body

    assert [%{"function" => %{"arguments" => arguments}}] = hd(body["messages"])["tool_calls"]
    assert String.starts_with?(arguments, "MARKER:")
  end

  test "the provider_options container and envelope keys are validated" do
    for options <- [nil, "not-a-map"] do
      assert {:error, %Error{kind: :validation, message: message}} =
               Chat.validate_request(text_request(provider_options: options), %Config{})

      assert message =~ "provider_options must be a map"
    end

    for key <- ["model", "messages", "stream"] do
      assert {:error, %Error{kind: :validation, message: message}} =
               Chat.validate_request(
                 text_request(provider_options: %{openai: %{key => 1}}),
                 %Config{}
               )

      assert message =~ "canonical field"
    end

    assert {:error, %Error{kind: :validation, message: message}} =
             Chat.validate_request(
               text_request(provider_options: %{openai: %{{:tuple, 1} => 2}}),
               %Config{}
             )

    assert message =~ "must be a string"

    assert {:error, %Error{kind: :validation, message: message}} =
             Chat.validate_request(
               text_request(provider_options: %{openai: %{temperature: 0.1}}),
               %Config{}
             )

    assert message =~ "must be a string"

    assert :ok ==
             Chat.validate_request(
               text_request(provider_options: %{openai: %{"max_tokens" => 1}}),
               %Config{}
             )

    for namespace <- [:openai_chat, :gemini, :foo] do
      assert {:error, %Error{kind: :validation, message: message}} =
               Chat.validate_request(
                 text_request(provider_options: %{namespace => %{}}),
                 %Config{}
               )

      assert message =~ "is not used by this codec"
    end

    assert {:error, %Error{kind: :validation, message: message}} =
             Chat.validate_request(text_request(), %Config{
               default_provider_options: %{openai: %{"max_tokens" => 1}}
             })

    assert message =~ "canonical field"
  end

  test "output and provider-option shapes are rejected before encoding" do
    for {request, pattern} <- [
          {text_request(output: :xml), ~r/output :xml is not supported/},
          {text_request(output: {:json_schema, "x", "not-a-map", true}), ~r/map schema/},
          {text_request(reasoning: %Reasoning{provider_options: "not-a-map"}),
           ~r/reasoning.provider_options must be a map/},
          {text_request(tools: [%ToolSpec{name: "f", provider_options: "not-a-map"}]),
           ~r/tool provider_options must be a map/}
        ] do
      assert {:error, %Error{kind: :validation, message: message}} =
               Chat.validate_request(request, %Config{})

      assert message =~ pattern
    end
  end

  describe "decode" do
    test "decodes a text response with usage and stop reason" do
      assert {:ok, response} = Chat.decode_response(Fx.text_response(), %Config{})
      assert response.id == "chatcmpl-1"
      assert response.model == "gpt-4o"
      assert response.stop_reason == :end_turn
      assert LlmCall.Response.text(response) == "Hello there"

      assert response.usage == %LlmCall.Usage{
               input_tokens: 12,
               output_tokens: 5,
               total_tokens: 17,
               cache_read_tokens: 3,
               cache_write_tokens: nil,
               reasoning_tokens: 0
             }

      assert response.raw == nil
    end

    test "capture_raw :response keeps the full payload" do
      payload = Fx.text_response()

      assert {:ok, %{raw: ^payload}} =
               Chat.decode_response(payload, %Config{capture_raw: :response})

      assert {:ok, %{raw: ^payload}} = Chat.decode_response(payload, %Config{capture_raw: :all})
    end

    test "decodes tool calls with decoded and raw arguments" do
      assert {:ok, response} = Chat.decode_response(Fx.tool_call_response(), %Config{})
      assert response.stop_reason == :tool_calls
      assert [call] = LlmCall.Response.tool_calls(response)

      assert call == %ToolCall{
               id: "call_1",
               name: "get_weather",
               arguments: %{"city" => "Oslo"},
               raw_arguments: ~s({"city":"Oslo"}),
               arguments_error: nil,
               index: nil
             }
    end

    test "malformed tool arguments keep raw_arguments and never become an empty map" do
      {:ok, response} = Chat.decode_response(Fx.malformed_tool_call_response(), %Config{})
      assert [call] = LlmCall.Response.tool_calls(response)
      assert call.arguments == nil
      assert call.raw_arguments == ~s({"city":)
      assert call.arguments_error == {:invalid_json, ~s({"city":)}
    end

    test "non-object tool arguments are an arguments_error" do
      {:ok, response} = Chat.decode_response(Fx.array_tool_call_response(), %Config{})
      assert [call] = LlmCall.Response.tool_calls(response)
      assert call.arguments == nil
      assert call.arguments_error == {:invalid_json, "[1,2]"}
    end

    test "reasoning_content becomes a thinking block and refusal becomes Raw" do
      {:ok, response} = Chat.decode_response(Fx.reasoning_and_refusal_response(), %Config{})

      assert [
               %Content.Thinking{text: "step 1"},
               %Content.Text{text: "Answer"},
               %Content.Raw{type: "refusal"}
             ] = response.content
    end

    test "extra choices are preserved as Raw content instead of being dropped" do
      {:ok, response} = Chat.decode_response(Fx.two_choices_response(), %Config{})
      assert [%Content.Text{text: "first"}, %Content.Raw{type: "choice"}] = response.content
    end

    test "unknown finish reasons decode to :unknown and missing usage stays nil" do
      {:ok, response} = Chat.decode_response(Fx.unknown_finish_response(), %Config{})
      assert response.stop_reason == :unknown
      assert response.usage == nil
    end

    test "invalid payloads are invalid_response errors" do
      assert {:error, %Error{kind: :invalid_response}} =
               Chat.decode_response(%{"nope" => 1}, %Config{})

      assert {:error, %Error{kind: :invalid_response}} =
               Chat.decode_response(%{"choices" => []}, %Config{})
    end

    test "decode_error/2 normalizes the provider envelope" do
      payload = Fx.error_payload()

      assert %Error{
               kind: :provider,
               message: "Rate limit reached",
               code: "rate_limit_exceeded",
               status: nil,
               retryable?: true,
               raw: ^payload
             } = Chat.decode_error(payload, %Config{})

      assert %Error{kind: :invalid_response, raw: nil} = Chat.decode_error("boom", %Config{})

      numeric = %{"error" => %{"message" => "slow down", "code" => 429}}

      assert %Error{kind: :provider, code: "429", retryable?: false} =
               Chat.decode_error(numeric, %Config{})
    end

    test "capabilities/2 declares the OpenAI Chat surface" do
      caps = Chat.capabilities(text_request(), %Config{})

      assert %LlmCall.Capabilities{
               tools: true,
               parallel_tool_calls: true,
               tool_choice: true,
               structured_output: :json_schema,
               image_input: true,
               file_input: false,
               streaming_tool_calls: true,
               prompt_cache: true,
               stateful: false,
               streaming: true
             } = caps

      assert %LlmCall.ReasoningCapabilities{
               supported: true,
               budget_tokens: false,
               adaptive: false,
               summary: []
             } = caps.reasoning

      assert :high in caps.reasoning.efforts
    end
  end

  describe "stream" do
    test "text deltas, stop reason and usage" do
      {_state, events} = run_stream(Fx.text_chunks())

      assert Enum.map(events, & &1.type) == [
               :text_delta,
               :text_delta,
               :message_delta,
               :message_delta,
               :message_stop
             ]

      assert Enum.map(Enum.filter(events, &(&1.type == :text_delta)), & &1.delta.text) == [
               "Hel",
               "lo"
             ]

      assert %LlmCall.StreamDelta.MessageDelta{stop_reason: :end_turn, usage: nil} =
               Enum.at(events, 2).delta

      assert %LlmCall.StreamDelta.MessageDelta{
               stop_reason: nil,
               usage: %LlmCall.Usage{total_tokens: 17}
             } = Enum.at(events, 3).delta

      assert List.last(events).type == :message_stop
    end

    test "tool call fragments start, delta and stop" do
      {_state, events} = run_stream(Fx.tool_call_chunks())
      types = Enum.map(events, & &1.type)
      assert :tool_call_start in types
      assert :tool_call_delta in types
      assert :tool_call_stop in types

      assembler = LlmCall.StreamAssembler.new(json_decoder: &LlmCall.TestJSON.decode/1)

      {_assembler, calls} =
        Enum.reduce(events, {assembler, []}, fn event, {assembler, acc} ->
          {:ok, assembler, new} = LlmCall.StreamAssembler.feed(assembler, event)
          {assembler, acc ++ new}
        end)

      assert [%ToolCall{id: "call_1", name: "get_weather", arguments: %{"city" => "Oslo"}}] =
               calls
    end

    test "parallel tool calls in one choice keep the tool-call index, not the choice index" do
      chunk = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{
              "tool_calls" => [
                %{
                  "index" => 0,
                  "id" => "call_a",
                  "type" => "function",
                  "function" => %{"name" => "alpha", "arguments" => ~s({"n":1})}
                },
                %{
                  "index" => 1,
                  "id" => "call_b",
                  "type" => "function",
                  "function" => %{"name" => "beta", "arguments" => ~s({"n":2})}
                }
              ]
            },
            "finish_reason" => nil
          }
        ]
      }

      {_state, events} = run_stream([chunk])

      starts =
        for %LlmCall.StreamEvent{type: :tool_call_start, index: index} <- events, do: index

      assert starts == [0, 1]

      assembler = LlmCall.StreamAssembler.new(json_decoder: &LlmCall.TestJSON.decode/1)

      {assembler, calls} =
        Enum.reduce(events, {assembler, []}, fn event, {assembler, acc} ->
          {:ok, assembler, new} = LlmCall.StreamAssembler.feed(assembler, event)
          {assembler, acc ++ new}
        end)

      {:ok, _assembler, final} = LlmCall.StreamAssembler.finish(assembler)

      assert [%ToolCall{name: "alpha"}, %ToolCall{name: "beta"}] = calls ++ final
    end

    test "reasoning_content becomes a thinking delta, not a Raw fallback" do
      chunk = %{
        "choices" => [
          %{
            "index" => 0,
            "delta" => %{"reasoning_content" => "step 1"},
            "finish_reason" => nil
          }
        ]
      }

      {_state, events} = run_stream([chunk])

      assert [%LlmCall.StreamEvent{type: :thinking_delta, delta: delta} | _rest] = events
      assert %LlmCall.StreamDelta.Thinking{text: "step 1", signature: nil} = delta
    end

    test "usage merges instead of overwriting previously seen fields" do
      {_state, events} = run_stream(Fx.usage_split_chunks())

      usages =
        for %{
              type: :message_delta,
              delta: %LlmCall.StreamDelta.MessageDelta{usage: %LlmCall.Usage{} = usage}
            } <-
              events,
            do: usage

      assert [
               %LlmCall.Usage{input_tokens: 20, total_tokens: 20},
               %LlmCall.Usage{input_tokens: 20, output_tokens: 4, total_tokens: 20}
             ] = usages
    end

    test "a non-object chunk is an invalid response, not a silent end" do
      assert {:error, %Error{kind: :invalid_response, message: message}} =
               Chat.decode_stream_event("ping", %Config{}, stream_state())

      assert message =~ "not an object"
    end

    test "[DONE] terminates the stream" do
      assert {:done, %LlmCall.StreamState{}} =
               Chat.decode_stream_event("[DONE]", %Config{}, stream_state())
    end

    test "capture_raw :all keeps the raw chunk on each event" do
      chunk = Fx.text_chunk("Hi")

      assert {:ok, [%LlmCall.StreamEvent{raw: ^chunk}], _state} =
               Chat.decode_stream_event(
                 chunk,
                 %Config{capture_raw: :all},
                 stream_state(%Config{capture_raw: :all})
               )

      assert {:ok, [%LlmCall.StreamEvent{raw: nil}], _state} =
               Chat.decode_stream_event(chunk, %Config{}, stream_state())
    end

    test "unknown chunk shapes become Raw message deltas and finish_stream closes the stream once" do
      state = stream_state()

      assert {:ok,
              [
                %LlmCall.StreamEvent{
                  type: :message_delta,
                  delta: %LlmCall.StreamDelta.Raw{}
                }
              ], state} =
               Chat.decode_stream_event(%{"foo" => "bar"}, %Config{}, state)

      assert {:ok, [%LlmCall.StreamEvent{type: :message_stop}], state} =
               Chat.finish_stream(state, %Config{})

      assert {:ok, [], ^state} = Chat.finish_stream(state, %Config{})
    end
  end

  defp stream_state(config \\ %Config{}) do
    assert {:ok, state} = Chat.init_stream(text_request(stream: true), config)
    state
  end

  defp run_stream(chunks, config \\ %Config{}) do
    Enum.reduce(chunks, {stream_state(config), []}, fn chunk, {state, acc} ->
      case Chat.decode_stream_event(chunk, config, state) do
        {:ok, events, state} -> {state, acc ++ events}
        {:done, state} -> {state, acc ++ [:done]}
      end
    end)
  end

  describe "review fixes" do
    test "role rules reject parts that cannot appear in that turn" do
      cases = [
        [%Message{role: :user, content: [%ToolCall{id: "c", name: "f", arguments: %{}}]}],
        [%Message{role: :assistant, content: [%ToolResult{call_id: "c", content: "x"}]}],
        [%Message{role: :assistant, content: [%Content.Image{source: {:url, "u"}}]}],
        [%Message{role: :user, content: []}],
        [%Message{role: :assistant, content: []}]
      ]

      for messages <- cases do
        assert {:error, %Error{kind: :validation}} =
                 Chat.validate_request(text_request(messages: messages), %Config{})

        assert {:error, %Error{kind: :validation}} =
                 Chat.encode_request(text_request(messages: messages), %Config{})
      end
    end

    test "an unmapped streamed delta is preserved as a Raw message delta" do
      chunk = %{
        "choices" => [%{"index" => 0, "delta" => %{"refusal" => "no"}, "finish_reason" => nil}]
      }

      assert {:ok,
              [
                %LlmCall.StreamEvent{
                  type: :message_delta,
                  delta: %LlmCall.StreamDelta.Raw{data: data}
                }
              ], _state} = Chat.decode_stream_event(chunk, %Config{}, stream_state())

      assert data["data"]["refusal"] == "no"
    end

    test "non-string message content is preserved as Raw instead of dropped" do
      payload =
        put_in(
          Fx.text_response(),
          ["choices", Access.at(0), "message", "content"],
          [%{"type" => "text", "text" => "hi"}]
        )

      assert {:ok, response} = Chat.decode_response(payload, %Config{})
      assert [%Content.Raw{type: "content", data: %{"content" => _}}] = response.content
    end

    test "reasoning and tool provider options are merged into their native locations" do
      reasoning = %Reasoning{effort: :high, provider_options: %{"service_tier" => "flex"}}
      body = encode(text_request(reasoning: reasoning)).body
      assert body["reasoning_effort"] == "high"
      assert body["service_tier"] == "flex"

      tools = [%ToolSpec{name: "f", provider_options: %{"strict_mode" => true}}]

      assert encode(text_request(tools: tools)).body["tools"]
             |> hd()
             |> Map.fetch!("function")
             |> Map.fetch!("strict_mode") == true
    end
  end

  describe "deferred minors" do
    test "an empty system part list sends no system message" do
      body = encode(text_request(system: [])).body
      refute Map.has_key?(body, "system")
      assert [%{"role" => "user"}] = body["messages"]
    end
  end

  describe "modalities" do
    test "text is the only accepted output modality" do
      refute Map.has_key?(encode(text_request()).body, "responseModalities")

      for modalities <- [[:image], [:text, :image], [:video]] do
        request = text_request(modalities: modalities)

        assert {:error, %Error{kind: :validation, message: message}} =
                 Chat.validate_request(request, %Config{})

        assert message =~ "modality"
        assert {:error, %Error{kind: :validation}} = Chat.encode_request(request, %Config{})
      end
    end

    test "capabilities declare text output only" do
      assert Chat.capabilities(text_request(), %Config{}).modalities == [:text]
    end
  end
end

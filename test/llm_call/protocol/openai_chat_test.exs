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
end

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
end

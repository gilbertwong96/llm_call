defmodule LlmCall.Protocol.GeminiGenerateContentTest do
  use ExUnit.Case, async: true

  alias LlmCall.Protocol.Gemini.GenerateContent

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
end

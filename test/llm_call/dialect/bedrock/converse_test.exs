defmodule LlmCall.Dialect.Bedrock.ConverseTest do
  use ExUnit.Case, async: true

  alias LlmCall.Content
  alias LlmCall.Dialect.Bedrock.Converse

  alias LlmCall.{
    Capabilities,
    Config,
    Error,
    Message,
    Request,
    Response,
    ToolCall,
    ToolResult,
    ToolSpec,
    Usage
  }

  defp request(model, overrides \\ []) do
    struct(
      %Request{
        model: model,
        messages: [%Message{role: :user, content: [%Content.Text{text: "hi"}]}]
      },
      overrides
    )
  end

  defp encode!(request, config \\ %Config{}) do
    assert {:ok, encoded} = Converse.encode_request(request, config)
    encoded
  end

  test "a model id is one path segment" do
    encoded = encode!(request("anthropic.claude-3-5-sonnet-20241022-v2:0"))

    assert encoded.method == :post
    assert encoded.path == "/model/anthropic.claude-3-5-sonnet-20241022-v2%3A0/converse"
    assert {"content-type", "application/json"} in encoded.headers
  end

  test "a model ARN keeps its slash inside one segment" do
    arn = "arn:aws:bedrock:us-east-1:1:application-inference-profile/abc"
    encoded = encode!(request(arn))

    assert encoded.path ==
             "/model/arn%3Aaws%3Abedrock%3Aus-east-1%3A1%3Aapplication-inference-profile%2Fabc/converse"
  end

  test "text, system and inferenceConfig" do
    encoded =
      encode!(
        request("m",
          system: "be terse",
          params: %{max_tokens: 1024, temperature: 0.5}
        )
      )

    assert encoded.body == %{
             "system" => [%{"text" => "be terse"}],
             "messages" => [%{"role" => "user", "content" => [%{"text" => "hi"}]}],
             "inferenceConfig" => %{"maxTokens" => 1024, "temperature" => 0.5}
           }
  end

  test "tools, a tool call and a tool result" do
    spec = %ToolSpec{
      name: "get",
      description: "reads one value",
      parameters: %{"type" => "object", "properties" => %{"a" => %{"type" => "integer"}}}
    }

    encoded =
      encode!(
        request("m",
          tools: [spec],
          tool_choice: {:tool, "get"},
          messages: [
            %Message{role: :user, content: [%Content.Text{text: "ask"}]},
            %Message{
              role: :assistant,
              content: [%ToolCall{id: "t1", name: "get", arguments: %{"a" => 1}}]
            },
            %Message{role: :user, content: [%ToolResult{call_id: "t1", content: "ok"}]}
          ]
        )
      )

    assert [%{"toolSpec" => tool_spec}] = encoded.body["toolConfig"]["tools"]
    assert tool_spec["name"] == "get"
    assert tool_spec["description"] == "reads one value"

    assert tool_spec["inputSchema"]["json"] == %{
             "type" => "object",
             "properties" => %{"a" => %{"type" => "integer"}}
           }

    assert encoded.body["toolConfig"]["toolChoice"] == %{"tool" => %{"name" => "get"}}

    assert [
             %{"role" => "user"},
             %{
               "role" => "assistant",
               "content" => [
                 %{"toolUse" => %{"toolUseId" => "t1", "name" => "get", "input" => %{"a" => 1}}}
               ]
             },
             %{
               "role" => "user",
               "content" => [
                 %{"toolResult" => %{"toolUseId" => "t1", "status" => "success"}}
               ]
             }
           ] = encoded.body["messages"]
  end

  test "tool_choice maps to Converse's union" do
    spec = %ToolSpec{name: "get", parameters: %{"type" => "object"}}

    required = encode!(request("m", tools: [spec], tool_choice: :required))
    assert required.body["toolConfig"]["toolChoice"] == %{"any" => %{}}

    named = encode!(request("m", tools: [spec], tool_choice: {:tool, "get"}))
    assert named.body["toolConfig"]["toolChoice"] == %{"tool" => %{"name" => "get"}}

    automatic = encode!(request("m", tools: [spec], tool_choice: :auto))
    refute Map.has_key?(automatic.body["toolConfig"], "toolChoice")
  end

  test "provider_options.bedrock reaches additionalModelRequestFields" do
    encoded =
      encode!(request("m", provider_options: %{bedrock: %{"top_k" => 200}}))

    assert encoded.body["additionalModelRequestFields"] == %{"top_k" => 200}
  end

  test "the codec refuses what Converse cannot express, by name" do
    cases = [
      {"reasoning", [reasoning: %LlmCall.Reasoning{}]},
      {"output", [output: {:json_schema, "s", %{}, nil}]},
      {"modalities", [modalities: [:text, :image]]},
      {"top_k", [params: %{top_k: 5}]}
    ]

    for {name, overrides} <- cases do
      assert {:error, %Error{kind: :validation, message: message}} =
               Converse.encode_request(request("m", overrides), %Config{})

      assert message =~ name
    end

    for part <- [
          %Content.Image{source: {:url, "https://x/i.png"}},
          %Content.File{source: {:base64, "QQ=="}, media_type: "application/pdf"},
          %Content.Video{source: {:url, "https://x/v.mp4"}}
        ] do
      request = request("m", messages: [%Message{role: :user, content: [part]}])
      name = "Content." <> (part.__struct__ |> Module.split() |> List.last())

      assert {:error, %Error{kind: :validation, message: message}} =
               Converse.encode_request(request, %Config{})

      assert message =~ name
    end
  end

  test "capabilities describe exactly what the phase supports" do
    assert %Capabilities{
             tools: true,
             tool_choice: true,
             structured_output: :none,
             modalities: [:text],
             image_input: false,
             file_input: false,
             streaming: false,
             stateful: false
           } = Converse.capabilities(request("m"), %Config{})
  end

  test "a text response decodes to the canonical shape" do
    payload = %{
      "output" => %{
        "message" => %{"role" => "assistant", "content" => [%{"text" => "pong"}]}
      },
      "stopReason" => "end_turn",
      "usage" => %{"inputTokens" => 3, "outputTokens" => 5, "totalTokens" => 8}
    }

    assert {:ok,
            %Response{
              content: [%Content.Text{text: "pong"}],
              stop_reason: :end_turn,
              usage: %Usage{input_tokens: 3, output_tokens: 5, total_tokens: 8}
            }} = Converse.decode_response(payload, %Config{})
  end

  test "a toolUse block becomes a ToolCall" do
    payload = %{
      "output" => %{
        "message" => %{
          "role" => "assistant",
          "content" => [
            %{"toolUse" => %{"toolUseId" => "t1", "name" => "get", "input" => %{"a" => 1}}}
          ]
        }
      },
      "stopReason" => "tool_use"
    }

    assert {:ok, %Response{content: [%ToolCall{id: "t1", name: "get", arguments: %{"a" => 1}}]}} =
             Converse.decode_response(payload, %Config{})
  end

  test "every published stopReason maps into the canonical union" do
    mapping = %{
      "end_turn" => :end_turn,
      "tool_use" => :tool_calls,
      "max_tokens" => :max_tokens,
      "stop_sequence" => :stop_sequence,
      "content_filtered" => :content_filter,
      "guardrail_intervened" => :content_filter,
      "model_context_window_exceeded" => :max_tokens,
      "malformed_model_output" => :error,
      "malformed_tool_use" => :error,
      "something_new" => :unknown
    }

    for {wire, canonical} <- mapping do
      payload = %{
        "output" => %{"message" => %{"role" => "assistant", "content" => [%{"text" => "x"}]}},
        "stopReason" => wire
      }

      assert {:ok, %Response{stop_reason: ^canonical}} =
               Converse.decode_response(payload, %Config{})
    end
  end

  test "an error envelope becomes a provider error" do
    assert %Error{kind: :provider, message: "no such model"} =
             Converse.decode_error(%{"message" => "no such model"}, %Config{})
  end

  test "a payload that is not a Converse response is an invalid_response" do
    assert {:error, %Error{kind: :invalid_response}} = Converse.decode_response(%{}, %Config{})
  end
end

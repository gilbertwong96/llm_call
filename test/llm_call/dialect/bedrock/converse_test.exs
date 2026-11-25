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

    for {part, role} <- [
          {%Content.Image{source: {:url, "https://x/i.png"}}, :user},
          {%Content.File{source: {:base64, "QQ=="}, media_type: "application/pdf"}, :user},
          {%Content.Video{source: {:url, "https://x/v.mp4"}}, :user},
          {%Content.Thinking{text: "thinking"}, :assistant},
          {%Content.Raw{type: "reasoning", data: %{}}, :assistant}
        ] do
      request = request("m", messages: [%Message{role: role, content: [part]}])
      name = "Content." <> (part.__struct__ |> Module.split() |> List.last())

      assert {:error, %Error{kind: :validation, message: message}} =
               Converse.encode_request(request, %Config{})

      assert message =~ name
    end
  end

  test "a request with no messages or an empty message is refused" do
    assert {:error, %Error{kind: :validation, message: empty}} =
             Converse.encode_request(request("m", messages: []), %Config{})

    assert empty =~ "messages"

    assert {:error, %Error{kind: :validation, message: contentless}} =
             Converse.encode_request(
               request("m", messages: [%Message{role: :user, content: []}]),
               %Config{}
             )

    assert contentless =~ "content"
  end

  test "an empty system list is omitted rather than sent empty" do
    encoded = encode!(request("m", system: []))

    refute Map.has_key?(encoded.body, "system")
  end

  test "consecutive tool results are merged into one user turn" do
    encoded =
      encode!(
        request("m",
          messages: [
            %Message{role: :user, content: [%Content.Text{text: "two lookups"}]},
            %Message{
              role: :assistant,
              content: [
                %ToolCall{id: "t1", name: "get", arguments: %{"a" => 1}},
                %ToolCall{id: "t2", name: "get", arguments: %{"a" => 2}}
              ]
            },
            %Message{role: :user, content: [%ToolResult{call_id: "t1", content: "one"}]},
            %Message{role: :user, content: [%ToolResult{call_id: "t2", content: "two"}]}
          ]
        )
      )

    assert [%{"role" => "user"}, %{"role" => "assistant"}, %{"role" => "user"} = merged] =
             encoded.body["messages"]

    assert [%{"toolResult" => %{"toolUseId" => "t1"}}, %{"toolResult" => %{"toolUseId" => "t2"}}] =
             merged["content"]
  end

  test "tool parameters must be a JSON schema object" do
    nil_parameters = %ToolSpec{name: "get", parameters: nil}

    assert {:error, %Error{kind: :validation, message: message}} =
             Converse.encode_request(request("m", tools: [nil_parameters]), %Config{})

    assert message =~ "parameters"

    assert {:ok, encoded} =
             Converse.encode_request(
               request("m", tools: [%ToolSpec{name: "get", parameters: %{}}]),
               %Config{}
             )

    assert [%{"toolSpec" => %{"inputSchema" => %{"json" => %{}}}}] =
             encoded.body["toolConfig"]["tools"]
  end

  test "a tool call without an id is refused" do
    request =
      request("m",
        messages: [%Message{role: :assistant, content: [%ToolCall{name: "get", arguments: %{}}]}]
      )

    assert {:error, %Error{kind: :validation, message: message}} =
             Converse.encode_request(request, %Config{})

    assert message =~ "tool calls require an id"
  end

  test "a tool result without content or a call_id is refused" do
    empty =
      request("m",
        messages: [%Message{role: :user, content: [%ToolResult{call_id: "t1", content: []}]}]
      )

    assert {:error, %Error{kind: :validation, message: empty_message}} =
             Converse.encode_request(empty, %Config{})

    assert empty_message =~ "content"

    unnamed =
      request("m", messages: [%Message{role: :user, content: [%ToolResult{content: "ok"}]}])

    assert {:error, %Error{kind: :validation, message: unnamed_message}} =
             Converse.encode_request(unnamed, %Config{})

    assert unnamed_message =~ "call_id"
  end

  test "a response block this phase does not map is preserved as Content.Raw" do
    thinking = %{"reasoningContent" => %{"reasoningText" => %{"text" => "think"}}}

    payload = %{
      "output" => %{
        "message" => %{
          "role" => "assistant",
          "content" => [%{"text" => "x"}, thinking]
        }
      },
      "stopReason" => "end_turn"
    }

    assert {:ok, %Response{content: [%Content.Text{text: "x"}, %Content.Raw{} = raw]}} =
             Converse.decode_response(payload, %Config{})

    assert raw.type == "reasoningContent"
    assert raw.data == thinking
  end

  test "an unknown provider_options namespace or a non-map value is refused" do
    assert {:error, %Error{kind: :validation, message: message}} =
             Converse.encode_request(request("m", provider_options: %{openai: %{}}), %Config{})

    assert message =~ "openai"

    assert {:error, %Error{kind: :validation, message: non_map}} =
             Converse.encode_request(request("m", provider_options: %{bedrock: "x"}), %Config{})

    assert non_map =~ "bedrock"
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

  test "prompt-cache token counts are carried into Usage" do
    payload = %{
      "output" => %{"message" => %{"role" => "assistant", "content" => [%{"text" => "x"}]}},
      "stopReason" => "end_turn",
      "usage" => %{
        "inputTokens" => 10,
        "outputTokens" => 2,
        "totalTokens" => 12,
        "cacheReadInputTokens" => 300,
        "cacheWriteInputTokens" => 40
      }
    }

    assert {:ok,
            %Response{
              usage: %Usage{
                input_tokens: 10,
                output_tokens: 2,
                total_tokens: 12,
                cache_read_tokens: 300,
                cache_write_tokens: 40
              }
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

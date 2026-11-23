defmodule LlmCall.ToolsTest.NeutralCodec do
  def info, do: %LlmCall.Codec.Info{name: :neutral, protocol: :made_up, ir_version: 1}
end

defmodule LlmCall.ToolsTest do
  use ExUnit.Case, async: true

  alias LlmCall.Dialect.Anthropic.Messages
  alias LlmCall.Error
  alias LlmCall.ToolFixtures.Weather
  alias LlmCall.Tools
  alias LlmCall.ToolSpec
  alias LlmCall.ToolsTest.NeutralCodec

  defp user_message do
    %LlmCall.Message{role: :user, content: [%LlmCall.Content.Text{text: "hi"}]}
  end

  test "passes ToolSpec entries through untouched" do
    spec = %ToolSpec{name: "hand", description: "d", parameters: %{"type" => "object"}}
    assert {:ok, [^spec]} = Tools.expand([spec], Messages)
  end

  test "expands a module into one spec per declared tool" do
    assert {:ok, specs} = Tools.expand([Weather], Messages)
    assert Enum.map(specs, & &1.name) == ["forecast", "conditions"]
    assert Enum.map(specs, & &1.description) == ["Forecast for a city.", "Current conditions."]
    assert Enum.all?(specs, &(&1.parameters["required"] == ["city"]))
  end

  test "accepts the mixed forms in one list" do
    spec = %ToolSpec{name: "hand", parameters: %{"type" => "object"}}
    assert {:ok, specs} = Tools.expand([spec, Weather], Messages)
    assert Enum.map(specs, & &1.name) == ["hand", "forecast", "conditions"]
  end

  test "Gemini gets uppercase types from tool_call's own projection" do
    request = %LlmCall.Request{
      model: "gemini-2.5-pro",
      messages: [user_message()],
      tools: [Weather]
    }

    assert {:ok, %LlmCall.EncodedRequest{body: body}} =
             LlmCall.encode(LlmCall.Dialect.Gemini.GenerateContent, request, %LlmCall.Config{})

    [tool | _] = body["tools"]
    [declaration | _] = tool["functionDeclarations"]
    assert declaration["parameters"]["type"] == "OBJECT"
  end

  test "OpenAI takes the function map and leaves strict to ToolSpec" do
    request = %LlmCall.Request{model: "gpt-4o", messages: [user_message()], tools: [Weather]}

    assert {:ok, %LlmCall.EncodedRequest{body: body}} =
             LlmCall.encode(LlmCall.Dialect.OpenAI.Chat, request, %LlmCall.Config{})

    [tool | _] = body["tools"]
    assert tool["function"]["name"] == "forecast"
    refute Map.has_key?(tool["function"], "strict")
  end

  test "an unknown protocol falls back to provider-neutral schemas" do
    assert {:ok, specs} = Tools.expand([Weather], NeutralCodec)
    assert [%ToolSpec{parameters: %{"type" => "object"}} | _] = specs
  end

  test "normalize_request/2 expands the request tools" do
    request = %LlmCall.Request{model: "test-1", messages: [user_message()], tools: [Weather]}

    assert {:ok, %LlmCall.Request{} = normalized} = Tools.normalize_request(request, Messages)
    assert Enum.map(normalized.tools, & &1.name) == ["forecast", "conditions"]
    assert normalized.model == request.model
    assert normalized.messages == request.messages
  end

  test "normalize_request/2 passes the expansion error through" do
    request = %LlmCall.Request{model: "test-1", tools: Weather}

    assert {:error, %Error{kind: :validation, message: "neutral: tools must be a list"}} =
             Tools.normalize_request(request, NeutralCodec)
  end

  test "rejects a non-list" do
    assert {:error, %Error{kind: :validation, message: message}} =
             Tools.expand(Weather, NeutralCodec)

    assert message == "neutral: tools must be a list"
  end

  test "encode/3 accepts a module for Anthropic and sends the tool" do
    request = %LlmCall.Request{
      model: "claude-sonnet-4",
      params: %{max_tokens: 1024},
      messages: [user_message()],
      tools: [Weather]
    }

    assert {:ok, %LlmCall.EncodedRequest{body: body}} =
             LlmCall.encode(LlmCall.Dialect.Anthropic.Messages, request, %LlmCall.Config{})

    assert [_, _] = body["tools"]
  end

  test "tool_choice resolves against names that came from a module" do
    request = %LlmCall.Request{
      model: "claude-sonnet-4",
      params: %{max_tokens: 1024},
      messages: [user_message()],
      tools: [Weather],
      tool_choice: {:tool, "forecast"}
    }

    assert {:ok, _} =
             LlmCall.encode(LlmCall.Dialect.Anthropic.Messages, request, %LlmCall.Config{})
  end

  test "tool_choice naming a tool the modules do not declare is a validation error" do
    request = %LlmCall.Request{
      model: "claude-sonnet-4",
      params: %{max_tokens: 1024},
      messages: [user_message()],
      tools: [Weather],
      tool_choice: {:tool, "nope"}
    }

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.encode(LlmCall.Dialect.Anthropic.Messages, request, %LlmCall.Config{})

    assert message =~ "nope"
    refute message =~ "is not supported"
  end

  test "stream/3 expands module tools before init_stream" do
    client = %LlmCall.Client{
      provider: LlmCall.TestProvider,
      codecs: %{chat: LlmCall.Dialect.Anthropic.Messages},
      base_url: "http://127.0.0.1:1",
      config: %LlmCall.Config{}
    }

    request = %LlmCall.Request{
      model: "claude-sonnet-4",
      params: %{max_tokens: 1024},
      messages: [user_message()],
      tools: [Weather]
    }

    assert {:ok, %LlmCall.Stream{}} = LlmCall.stream(client, request)
  end

  test "init_stream/3 expands module tools before the codec" do
    request = %LlmCall.Request{
      model: "claude-sonnet-4",
      params: %{max_tokens: 1024},
      messages: [user_message()],
      tools: [Weather]
    }

    assert {:ok, %LlmCall.StreamState{}} =
             LlmCall.init_stream(LlmCall.Dialect.Anthropic.Messages, request, %LlmCall.Config{})
  end
end

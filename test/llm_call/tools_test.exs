defmodule LlmCall.ToolsTest.NeutralCodec do
  def info, do: %LlmCall.Codec.Info{name: :neutral, protocol: :made_up, ir_version: 1}
end

defmodule LlmCall.ToolsTest.OpenAIProvider do
  @moduledoc false

  use LlmCall.Provider,
    base_url: "http://127.0.0.1:1",
    auth: :none,
    codecs: [chat: LlmCall.Dialect.OpenAI.Chat]
end

defmodule LlmCall.ToolsTest do
  use ExUnit.Case, async: true

  alias LlmCall.Dialect.Anthropic.Messages
  alias LlmCall.Error
  alias LlmCall.ToolFixtures.{Weather, WeatherAlias}
  alias LlmCall.Tools
  alias LlmCall.ToolSpec
  alias LlmCall.ToolsTest.{NeutralCodec, OpenAIProvider}

  defp user_message do
    %LlmCall.Message{role: :user, content: [%LlmCall.Content.Text{text: "hi"}]}
  end

  test "passes ToolSpec entries through untouched" do
    spec = %ToolSpec{name: "hand", description: "d", parameters: %{"type" => "object"}}
    assert {:ok, [^spec]} = Tools.expand([spec], Messages)
  end

  test "expands a module into one spec per declared tool" do
    assert {:ok, specs} = Tools.expand([Weather], Messages)
    assert Enum.map(specs, & &1.name) == ["forecast", "conditions", "detailed"]

    assert Enum.map(specs, & &1.description) == [
             "Forecast for a city.",
             "Current conditions.",
             "Detailed forecast for a city."
           ]

    assert Enum.all?(specs, &(&1.parameters["required"] == ["city"]))
  end

  test "accepts the mixed forms in one list" do
    spec = %ToolSpec{name: "hand", parameters: %{"type" => "object"}}
    assert {:ok, specs} = Tools.expand([spec, Weather], Messages)
    assert Enum.map(specs, & &1.name) == ["hand", "forecast", "conditions", "detailed"]
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

  test "OpenAI strict closes the schema and sets the flag inside function" do
    request = %LlmCall.Request{
      model: "gpt-4o",
      messages: [user_message()],
      tools: [{Weather, strict: true}]
    }

    assert {:ok, %LlmCall.EncodedRequest{body: body}} =
             LlmCall.encode(LlmCall.Dialect.OpenAI.Chat, request, %LlmCall.Config{})

    [tool | _] = body["tools"]
    assert tool["function"]["strict"] == true
    assert tool["function"]["parameters"]["additionalProperties"] == false

    detailed = Enum.find(body["tools"], &(&1["function"]["name"] == "detailed"))
    assert detailed["function"]["parameters"]["required"] == ["city", "units"]

    assert detailed["function"]["parameters"]["properties"]["units"]["type"] == [
             "string",
             "null"
           ]
  end

  test "strict: false and an omitted strict leave the optional parameter optional" do
    for tools <- [[Weather], [{Weather, []}], [{Weather, strict: false}]] do
      request = %LlmCall.Request{model: "gpt-4o", messages: [user_message()], tools: tools}

      assert {:ok, %LlmCall.EncodedRequest{body: body}} =
               LlmCall.encode(LlmCall.Dialect.OpenAI.Chat, request, %LlmCall.Config{})

      detailed = Enum.find(body["tools"], &(&1["function"]["name"] == "detailed"))
      refute Map.has_key?(detailed["function"], "strict")
      assert detailed["function"]["parameters"]["required"] == ["city"]
    end
  end

  test "OpenAI Responses carries the strict tuple form onto the declared tool" do
    request = %LlmCall.Request{
      model: "gpt-5",
      messages: [user_message()],
      tools: [{Weather, strict: true}]
    }

    assert {:ok, %LlmCall.EncodedRequest{body: body}} =
             LlmCall.encode(LlmCall.Dialect.OpenAI.Responses, request, %LlmCall.Config{})

    forecast = Enum.find(body["tools"], &(&1["name"] == "forecast"))
    assert forecast["strict"] == true
    assert forecast["parameters"]["additionalProperties"] == false
  end

  test "strict: false is treated as absent, so Gemini accepts the tuple form" do
    request = %LlmCall.Request{
      model: "gemini-2.5-pro",
      messages: [user_message()],
      tools: [{Weather, strict: false}]
    }

    assert {:ok, %LlmCall.EncodedRequest{}} =
             LlmCall.encode(LlmCall.Dialect.Gemini.GenerateContent, request, %LlmCall.Config{})
  end

  test "a codec that does not forward strict rejects it" do
    request = %LlmCall.Request{
      model: "gemini-2.5-pro",
      messages: [user_message()],
      tools: [{Weather, strict: true}]
    }

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.encode(LlmCall.Dialect.Gemini.GenerateContent, request, %LlmCall.Config{})

    assert message =~ "tool strict mode is not supported"
  end

  test "strict must be a boolean or nil" do
    assert {:error, %Error{kind: :validation, message: message}} =
             Tools.expand([{Weather, strict: :fine_tuned}], NeutralCodec)

    assert message =~ "tool strict must be a boolean"
  end

  test "a misspelled tool option is a validation error naming the key" do
    assert {:error, %Error{kind: :validation, message: message}} =
             Tools.expand([{Weather, strikt: true}], NeutralCodec)

    assert message =~ ":strikt"
  end

  test "tool opts must be a keyword list" do
    assert {:error, %Error{kind: :validation, message: message}} =
             Tools.expand([{Weather, ["x"]}], NeutralCodec)

    assert message =~ "tool opts must be a keyword list"
  end

  test "a malformed entry is a validation error, not a FunctionClauseError" do
    for bad <- [123, "forecast", {Weather, :bad_opts}, Enum] do
      assert {:error, %Error{kind: :validation, message: message}} =
               Tools.expand([bad], NeutralCodec)

      assert message =~ "neutral: "
    end
  end

  test "a module that does not use ToolCall is named in the error" do
    assert {:error, %Error{kind: :validation, message: message}} =
             Tools.expand([Enum], NeutralCodec)

    assert message =~ "Enum"
    assert message =~ "does not use ToolCall"
  end

  test "a recursive parameter type on Gemini is a validation error, not a raise" do
    alias LlmCall.ToolFixtures.Recursive

    request = %LlmCall.Request{
      model: "gemini-2.5-pro",
      messages: [user_message()],
      tools: [Recursive]
    }

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.encode(LlmCall.Dialect.Gemini.GenerateContent, request, %LlmCall.Config{})

    assert message =~ "Recursive"
    assert message =~ ~s(tool "store")
  end

  test "an unknown protocol falls back to provider-neutral schemas" do
    assert {:ok, specs} = Tools.expand([Weather], NeutralCodec)
    assert [%ToolSpec{parameters: %{"type" => "object"}} | _] = specs
  end

  test "normalize_request/2 expands the request tools" do
    request = %LlmCall.Request{model: "test-1", messages: [user_message()], tools: [Weather]}

    assert {:ok, %LlmCall.Request{} = normalized} = Tools.normalize_request(request, Messages)
    assert Enum.map(normalized.tools, & &1.name) == ["forecast", "conditions", "detailed"]
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

    assert [_, _, _] = body["tools"]
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

  test "complete/3 expands module tools before the codec" do
    alias LlmCall.TestHTTPServer, as: TestHTTP

    TestHTTP.start()
    on_exit(&TestHTTP.stop/0)

    TestHTTP.put_response(
      {:ok, %{status: 200, headers: [], body: ~s({"choices":[{"message":{"content":"ok"}}]})}}
    )

    client = OpenAIProvider.client(base_url: TestHTTP.url(), api_key: "k")

    request = %LlmCall.Request{model: "gpt-4o", messages: [user_message()], tools: [Weather]}

    assert {:ok, %LlmCall.Response{}} = LlmCall.complete(client, request)
    assert [sent] = TestHTTP.requests()
    assert sent.body =~ ~s("forecast")
  end

  test "validate_request/3 expands module tools before the codec" do
    request = %LlmCall.Request{model: "gpt-4o", messages: [user_message()], tools: [Weather]}

    assert :ok = LlmCall.validate_request(LlmCall.Dialect.OpenAI.Chat, request)
  end

  test "two modules declaring the same tool name are rejected after expansion" do
    request = %LlmCall.Request{
      model: "gpt-4o",
      messages: [user_message()],
      tools: [Weather, WeatherAlias]
    }

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.encode(LlmCall.Dialect.OpenAI.Chat, request, %LlmCall.Config{})

    assert message =~ ~s(tool name "forecast" is declared more than once)
  end
end

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
end

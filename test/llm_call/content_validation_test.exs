defmodule LlmCall.ContentValidationTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Config, Content, Error, Message, Request, ToolCall, ToolResult}

  defp request(role, content) do
    %Request{
      model: "gpt-4o",
      messages: [%Message{role: role, content: content}]
    }
  end

  defp validate(content), do: validate(:user, content)

  defp validate(role, content) do
    LlmCall.Protocol.OpenAI.Chat.validate_request(request(role, content), %Config{})
  end

  defp validate_tools(tools) do
    request = %Request{
      model: "gpt-4o",
      messages: [%Message{role: :user, content: [%Content.Text{text: "hi"}]}],
      tools: tools
    }

    LlmCall.Protocol.OpenAI.Chat.validate_request(request, %Config{})
  end

  test "text parts require a string" do
    assert {:error, %Error{kind: :validation}} = validate([%Content.Text{text: nil}])
  end

  test "image sources require string values" do
    assert {:error, %Error{kind: :validation}} =
             validate([%Content.Image{source: {:base64, nil}, media_type: "image/png"}])

    assert {:error, %Error{kind: :validation}} =
             validate([%Content.Image{source: {:url, nil}}])
  end

  test "tool identifiers are not empty strings" do
    assert {:error, %Error{kind: :validation}} =
             validate(:assistant, [%ToolCall{id: "", name: "f", arguments: %{}}])

    assert {:error, %Error{kind: :validation}} =
             validate(:assistant, [%ToolCall{id: "id", name: "", arguments: %{}}])

    assert {:error, %Error{kind: :validation}} =
             validate([%ToolResult{call_id: "", content: "ok"}])
  end

  test "raw tool arguments are validated even when a decoded map is present" do
    call = %ToolCall{id: "id", name: "f", arguments: %{"ok" => true}, raw_arguments: "not json"}

    assert {:error, %Error{kind: :validation}} = validate(:assistant, [call])
  end

  test "tool specs validate kind, parameters, and strict" do
    for spec <- [
          %LlmCall.ToolSpec{name: "f", kind: :other},
          %LlmCall.ToolSpec{name: "f", parameters: "not-a-map"},
          %LlmCall.ToolSpec{name: "f", strict: "yes"}
        ] do
      assert {:error, %Error{kind: :validation}} = validate_tools([spec])
    end
  end

  test "tool results require a boolean is_error" do
    result = %ToolResult{call_id: "id", content: "ok", is_error: "yes"}

    assert {:error, %Error{kind: :validation}} = validate([result])
  end
end

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
    LlmCall.Dialect.OpenAI.Chat.validate_request(request(role, content), %Config{})
  end

  # Encodes an assistant turn carrying these tool calls, the replay path.
  defp validate_replay(tool_calls) do
    request = %Request{
      model: "gpt-4o",
      messages: [
        %Message{role: :user, content: [%Content.Text{text: "hi"}]},
        %Message{role: :assistant, content: tool_calls}
      ]
    }

    LlmCall.Dialect.OpenAI.Chat.validate_request(request, %Config{})
  end

  defp validate_messages(messages) do
    LlmCall.Dialect.Helpers.validate_messages(messages, :test_codec)
  end

  defp validate_tools(tools) do
    request = %Request{
      model: "gpt-4o",
      messages: [%Message{role: :user, content: [%Content.Text{text: "hi"}]}],
      tools: tools
    }

    LlmCall.Dialect.OpenAI.Chat.validate_request(request, %Config{})
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

  test "a tool call the decoder could not parse is still replayable" do
    # §8.2 pins ToolCall as replayable in every codec. A model does not always
    # generate valid JSON, and the repair is to send the assistant turn back with a
    # tool result saying so — so the *replay* must survive validation here. How the
    # fragment renders is the codec's business: the OpenAI families send it verbatim
    # as a string, while Anthropic and Gemini have object-valued argument fields and
    # send %{}. Both shapes are pinned in the dialect suites.
    malformed = %LlmCall.ToolCall{
      id: "call_1",
      name: "get_weather",
      raw_arguments: ~s({"city":),
      arguments_error: {:invalid_json, "tool arguments are not valid JSON"}
    }

    assert :ok == validate_replay([malformed])

    # A hand-written fragment with no decoder verdict is still rejected: the
    # caller is asserting it is valid, and it is not.
    hand_written = %LlmCall.ToolCall{id: "call_1", name: "f", raw_arguments: ~s({"city":)}

    assert {:error, %Error{kind: :validation, message: message}} =
             validate_replay([hand_written])

    assert message =~ "must decode to an object"
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

  test "a tool name outside the protocol's published class is a validation error" do
    # OpenAI Chat: `^[a-zA-Z0-9_-]{1,64}$`.
    for name <- ["weather.get", "bad name!", "1abc def", String.duplicate("a", 65)] do
      assert {:error, %Error{kind: :validation, message: message}} =
               validate_tools([%LlmCall.ToolSpec{name: name}])

      assert message =~ "tool name"
    end

    assert :ok == validate_tools([%LlmCall.ToolSpec{name: "get_weather"}])
    assert :ok == validate_tools([%LlmCall.ToolSpec{name: "get-weather"}])
  end

  test "a tool result must answer a call in the preceding message" do
    orphan = [
      %LlmCall.Message{role: :user, content: [%Content.Text{text: "hi"}]},
      %LlmCall.Message{
        role: :user,
        content: [%ToolResult{call_id: "call_1", name: "f", content: "r"}]
      }
    ]

    assert {:error, %Error{kind: :validation, message: message}} =
             validate_messages(orphan)

    assert message =~ "tool result for \"call_1\""
    assert message =~ "preceding message declares no tool call"

    paired = [
      %LlmCall.Message{role: :user, content: [%Content.Text{text: "hi"}]},
      %LlmCall.Message{
        role: :assistant,
        content: [%LlmCall.ToolCall{id: "call_1", name: "f", arguments: %{}}]
      },
      %LlmCall.Message{
        role: :user,
        content: [%ToolResult{call_id: "call_1", name: "f", content: "r"}]
      }
    ]

    assert :ok == validate_messages(paired)
  end

  test "an unanswered tool call is left to the protocol" do
    # A truncated turn is the caller's decision: only the protocol can say
    # whether it is recoverable, so the library does not reject it.
    messages = [
      %LlmCall.Message{role: :user, content: [%Content.Text{text: "hi"}]},
      %LlmCall.Message{
        role: :assistant,
        content: [%LlmCall.ToolCall{id: "call_1", name: "f", arguments: %{}}]
      }
    ]

    assert :ok == validate_messages(messages)
  end

  test "a tool result whose call_id is absent is not a pairing error" do
    # Gemini identifies a call by name, so `call_id` is nil there; that shape is
    # the codec's to validate, not the pairing rule's.
    messages = [
      %LlmCall.Message{role: :user, content: [%Content.Text{text: "hi"}]},
      %LlmCall.Message{
        role: :assistant,
        content: [%LlmCall.ToolCall{id: nil, name: "f", arguments: %{}}]
      },
      %LlmCall.Message{
        role: :user,
        content: [%ToolResult{call_id: nil, name: "f", content: "r"}]
      }
    ]

    assert :ok == validate_messages(messages)
  end

  test "a tool_choice naming an undeclared tool is a validation error" do
    tools = [%LlmCall.ToolSpec{name: "get_weather"}]

    request = fn choice ->
      %Request{
        model: "gpt-4o",
        params: %{max_tokens: 100},
        messages: [%Message{role: :user, content: [%Content.Text{text: "hi"}]}],
        tools: tools,
        tool_choice: choice
      }
    end

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.Dialect.OpenAI.Chat.validate_request(
               request.({:tool, "nonexistent"}),
               %Config{}
             )

    assert message =~ "no tool in the request declares"

    assert :ok ==
             LlmCall.Dialect.OpenAI.Chat.validate_request(
               request.({:tool, "get_weather"}),
               %Config{}
             )
  end

  test "a tool name may only be declared once" do
    duplicated = [%LlmCall.ToolSpec{name: "f"}, %LlmCall.ToolSpec{name: "f"}]

    assert {:error, %Error{kind: :validation, message: message}} = validate_tools(duplicated)
    assert message =~ ~s(tool name "f" is declared more than once)

    assert :ok == validate_tools([%LlmCall.ToolSpec{name: "f"}, %LlmCall.ToolSpec{name: "g"}])
  end

  test "tool results require a boolean is_error" do
    result = %ToolResult{call_id: "id", content: "ok", is_error: "yes"}

    assert {:error, %Error{kind: :validation}} = validate([result])
  end

  describe "media parts" do
    test "base64 data must actually be base64" do
      for data <- ["!!!garbage!!!", "A", "a b c", "===="] do
        assert {:error, %Error{kind: :validation, message: message}} =
                 validate([
                   %Content.Image{source: {:base64, data}, media_type: "image/png"}
                 ])

        assert message =~ "base64"
      end
    end

    test "base64 with and without padding is accepted" do
      # Padded and unpadded spellings of the same payload, which the canonical
      # examples use interchangeably.
      for data <- ["aGk=", "AAA", "aGVsbG8=", "AA=="] do
        assert :ok == validate([%Content.Image{source: {:base64, data}, media_type: "image/png"}])
      end
    end

    test "media_type must be a type/subtype, not free text" do
      for media_type <- ["nonsense", "image", "image/", "/png", "image png"] do
        assert {:error, %Error{kind: :validation, message: message}} =
                 validate([
                   %Content.Image{source: {:base64, "aGk="}, media_type: media_type}
                 ])

        assert message =~ "is not a media type"
      end
    end

    test "a well-formed media_type with parameters or charset syntax is accepted" do
      for media_type <- ["image/png", "application/pdf", "video/mp4", "image/svg+xml"] do
        assert :ok ==
                 validate([%Content.Image{source: {:base64, "aGk="}, media_type: media_type}])
      end
    end

    test "a url source does not need a media_type" do
      assert :ok == validate([%Content.Image{source: {:url, "https://example.com/a.png"}}])
      assert :ok == validate([%Content.Image{source: "https://example.com/a.png"}])
    end

    test "video base64 data is validated even before the codec rejects the part" do
      # `validate_part_values/2` runs before the per-codec shape check, so an
      # unsupported video part still reports the base64 problem first.
      assert {:error, %Error{kind: :validation, message: message}} =
               validate([%Content.Video{source: {:base64, "!!"}, media_type: "video/mp4"}])

      assert message =~ "base64"
    end
  end
end

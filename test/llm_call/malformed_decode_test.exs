defmodule LlmCall.MalformedDecodeTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Config, Error}

  test "Anthropic rejects a non-map content block as invalid_response" do
    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.Protocol.Anthropic.Messages.decode_response(
               %{"content" => [nil]},
               %Config{}
             )
  end

  test "Gemini rejects a non-map content part as invalid_response" do
    payload = %{"candidates" => [%{"content" => %{"parts" => [nil]}}]}

    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.Protocol.Gemini.GenerateContent.decode_response(payload, %Config{})
  end

  test "OpenAI Chat rejects a non-list tool_calls value as invalid_response" do
    payload = %{"choices" => [%{"message" => %{"tool_calls" => "not-a-list"}}]}

    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.Protocol.OpenAI.Chat.decode_response(payload, %Config{})
  end

  test "OpenAI Chat rejects a non-map tool call as invalid_response" do
    payload = %{"choices" => [%{"message" => %{"tool_calls" => [1]}}]}

    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.Protocol.OpenAI.Chat.decode_response(payload, %Config{})
  end

  test "OpenAI Images rejects a nil data item as invalid_response" do
    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.Media.Protocol.OpenAI.Images.decode_submit(
               %{"data" => [nil]},
               %Config{}
             )
  end

  test "Anthropic keeps a malformed text block as raw" do
    assert {:ok, %LlmCall.Response{content: [%LlmCall.Content.Raw{type: "text"}]}} =
             LlmCall.Protocol.Anthropic.Messages.decode_response(
               %{"content" => [%{"type" => "text", "text" => nil}]},
               %Config{}
             )
  end

  test "Gemini keeps malformed functionCall args as raw" do
    payload = %{
      "candidates" => [
        %{"content" => %{"parts" => [%{"functionCall" => %{"name" => "f", "args" => "x"}}]}}
      ]
    }

    assert {:ok, %LlmCall.Response{content: [%LlmCall.Content.Raw{data: %{"functionCall" => _}}]}} =
             LlmCall.Protocol.Gemini.GenerateContent.decode_response(payload, %Config{})
  end

  test "Gemini rejects a non-map functionResponse body as invalid_response" do
    payload = %{
      "candidates" => [
        %{
          "content" => %{
            "parts" => [%{"functionResponse" => %{"name" => "f", "response" => "x"}}]
          }
        }
      ]
    }

    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.Protocol.Gemini.GenerateContent.decode_response(payload, %Config{})
  end

  test "Anthropic keeps an invalid tool_use block as raw" do
    payload = %{
      "content" => [
        %{"type" => "tool_use", "id" => "x", "name" => "f", "input" => "not-map"}
      ]
    }

    assert {:ok, %LlmCall.Response{content: [%LlmCall.Content.Raw{type: "tool_use"}]}} =
             LlmCall.Protocol.Anthropic.Messages.decode_response(payload, %Config{})
  end

  test "Gemini keeps an inlineData block without bytes as raw" do
    payload = %{
      "candidates" => [
        %{"content" => %{"parts" => [%{"inlineData" => %{"mimeType" => "image/png"}}]}}
      ]
    }

    assert {:ok, %LlmCall.Response{content: [%LlmCall.Content.Raw{type: "inlineData"}]}} =
             LlmCall.Protocol.Gemini.GenerateContent.decode_response(payload, %Config{})
  end

  test "OpenAI Chat rejects empty tool call names" do
    payload = %{
      "choices" => [
        %{
          "message" => %{
            "tool_calls" => [%{"id" => "id", "function" => %{"name" => "", "arguments" => "{}"}}]
          }
        }
      ]
    }

    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.Protocol.OpenAI.Chat.decode_response(payload, %Config{})
  end

  test "Seedance rejects a succeeded task with non-map content" do
    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.Media.Protocol.Seedance.Video.decode_operation(
               %{"status" => "succeeded", "content" => "x"},
               %Config{}
             )
  end
end

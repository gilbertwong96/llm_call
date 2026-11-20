defmodule LlmCall.MalformedDecodeTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Config, Error}

  test "Anthropic rejects a non-map content block as invalid_response" do
    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.Dialect.Anthropic.Messages.decode_response(
               %{"content" => [nil]},
               %Config{}
             )
  end

  test "Gemini rejects a non-map content part as invalid_response" do
    payload = %{"candidates" => [%{"content" => %{"parts" => [nil]}}]}

    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.Dialect.Gemini.GenerateContent.decode_response(payload, %Config{})
  end

  test "OpenAI Chat rejects a non-list tool_calls value as invalid_response" do
    payload = %{"choices" => [%{"message" => %{"tool_calls" => "not-a-list"}}]}

    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.Dialect.OpenAI.Chat.decode_response(payload, %Config{})
  end

  test "OpenAI Chat rejects a non-map tool call as invalid_response" do
    payload = %{"choices" => [%{"message" => %{"tool_calls" => [1]}}]}

    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.Dialect.OpenAI.Chat.decode_response(payload, %Config{})
  end

  test "OpenAI Images rejects a nil data item as invalid_response" do
    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.Media.Dialect.OpenAI.Images.decode_submit(
               %{"data" => [nil]},
               %Config{}
             )
  end

  test "Anthropic keeps a malformed text block as raw" do
    assert {:ok, %LlmCall.Response{content: [%LlmCall.Content.Raw{type: "text"}]}} =
             LlmCall.Dialect.Anthropic.Messages.decode_response(
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
             LlmCall.Dialect.Gemini.GenerateContent.decode_response(payload, %Config{})
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
             LlmCall.Dialect.Gemini.GenerateContent.decode_response(payload, %Config{})
  end

  test "Anthropic keeps an invalid tool_use block as raw" do
    payload = %{
      "content" => [
        %{"type" => "tool_use", "id" => "x", "name" => "f", "input" => "not-map"}
      ]
    }

    assert {:ok, %LlmCall.Response{content: [%LlmCall.Content.Raw{type: "tool_use"}]}} =
             LlmCall.Dialect.Anthropic.Messages.decode_response(payload, %Config{})
  end

  test "Gemini keeps an inlineData block without bytes as raw" do
    payload = %{
      "candidates" => [
        %{"content" => %{"parts" => [%{"inlineData" => %{"mimeType" => "image/png"}}]}}
      ]
    }

    assert {:ok, %LlmCall.Response{content: [%LlmCall.Content.Raw{type: "inlineData"}]}} =
             LlmCall.Dialect.Gemini.GenerateContent.decode_response(payload, %Config{})
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
             LlmCall.Dialect.OpenAI.Chat.decode_response(payload, %Config{})
  end

  test "OpenAI Chat rejects empty tool call ids" do
    payload = %{
      "choices" => [
        %{
          "message" => %{
            "tool_calls" => [%{"id" => "", "function" => %{"name" => "f", "arguments" => "{}"}}]
          }
        }
      ]
    }

    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.Dialect.OpenAI.Chat.decode_response(payload, %Config{})
  end

  test "Gemini keeps a fileData block without fileUri as raw" do
    payload = %{
      "candidates" => [
        %{"content" => %{"parts" => [%{"fileData" => %{"mimeType" => "image/png"}}]}}
      ]
    }

    assert {:ok, %LlmCall.Response{content: [%LlmCall.Content.Raw{type: "fileData"}]}} =
             LlmCall.Dialect.Gemini.GenerateContent.decode_response(payload, %Config{})
  end

  test "Gemini keeps a thought block without text as raw" do
    payload = %{
      "candidates" => [
        %{"content" => %{"parts" => [%{"thought" => true, "text" => nil}]}}
      ]
    }

    assert {:ok, %LlmCall.Response{content: [%LlmCall.Content.Raw{type: "text"}]}} =
             LlmCall.Dialect.Gemini.GenerateContent.decode_response(payload, %Config{})
  end

  test "Anthropic keeps a thinking block with an invalid signature as raw" do
    payload = %{
      "content" => [%{"type" => "thinking", "thinking" => "x", "signature" => 1}]
    }

    assert {:ok, %LlmCall.Response{content: [%LlmCall.Content.Raw{type: "thinking"}]}} =
             LlmCall.Dialect.Anthropic.Messages.decode_response(payload, %Config{})
  end

  test "Seedance rejects a succeeded task with non-map content" do
    assert {:error, %Error{kind: :invalid_response}} =
             LlmCall.Media.Dialect.Seedance.Video.decode_operation(
               %{"status" => "succeeded", "content" => "x"},
               %Config{}
             )
  end
end

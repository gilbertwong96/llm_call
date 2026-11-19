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
end

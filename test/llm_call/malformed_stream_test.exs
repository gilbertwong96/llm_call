defmodule LlmCall.MalformedStreamTest do
  use ExUnit.Case, async: true

  alias LlmCall.{Config, Content, Error, Message, Request}

  defp request(codec) do
    base = %Request{
      model: "m",
      messages: [%Message{role: :user, content: [%Content.Text{text: "hi"}]}]
    }

    case codec do
      LlmCall.Protocol.Anthropic.Messages -> %{base | model: "claude", params: %{max_tokens: 10}}
      LlmCall.Protocol.Gemini.GenerateContent -> %{base | model: "gemini-2.5-pro"}
      LlmCall.Protocol.OpenAI.Chat -> %{base | model: "gpt-4o"}
    end
  end

  test "built-in stream decoders reject malformed nested fields" do
    cases = [
      {LlmCall.Protocol.Anthropic.Messages, %{"type" => "message_start", "message" => "x"}},
      {LlmCall.Protocol.Anthropic.Messages, %{"type" => "message_delta", "delta" => "x"}},
      {LlmCall.Protocol.Anthropic.Messages,
       %{"type" => "content_block_start", "index" => 0, "content_block" => "x"}},
      {LlmCall.Protocol.Anthropic.Messages,
       %{"type" => "content_block_delta", "index" => 0, "delta" => "x"}},
      {LlmCall.Protocol.Anthropic.Messages,
       %{
         "type" => "content_block_delta",
         "index" => 0,
         "delta" => %{"type" => "text_delta", "text" => nil}
       }},
      {LlmCall.Protocol.Anthropic.Messages,
       %{
         "type" => "content_block_delta",
         "index" => 0,
         "delta" => %{"type" => "thinking_delta", "thinking" => nil}
       }},
      {LlmCall.Protocol.Anthropic.Messages,
       %{
         "type" => "content_block_delta",
         "index" => 0,
         "delta" => %{"type" => "signature_delta", "signature" => 1}
       }},
      {LlmCall.Protocol.OpenAI.Chat, %{"choices" => [%{"delta" => %{"tool_calls" => [1]}}]}},
      {LlmCall.Protocol.OpenAI.Chat,
       %{"choices" => [%{"delta" => %{"tool_calls" => [%{"function" => "x"}]}}]}},
      {LlmCall.Protocol.OpenAI.Chat,
       %{
         "choices" => [
           %{"delta" => %{"tool_calls" => [%{"function" => %{"arguments" => %{}}}]}}
         ]
       }},
      {LlmCall.Protocol.Gemini.GenerateContent,
       %{"candidates" => [%{"content" => %{"parts" => "x"}}]}}
    ]

    for {codec, payload} <- cases do
      assert {:ok, state} = codec.init_stream(request(codec), %Config{})

      assert {:error, %Error{kind: :invalid_response}} =
               codec.decode_stream_event(payload, %Config{}, state)
    end
  end

  test "Gemini ignores a non-map usageMetadata instead of crashing" do
    codec = LlmCall.Protocol.Gemini.GenerateContent
    assert {:ok, state} = codec.init_stream(request(codec), %Config{})

    assert {:ok, _events, %LlmCall.StreamState{data: %{usage: nil}}} =
             codec.decode_stream_event(%{"usageMetadata" => "x"}, %Config{}, state)
  end
end

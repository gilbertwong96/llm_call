defmodule LlmCall.CodecConformanceTest do
  use ExUnit.Case, async: true

  alias LlmCall.Codec.Conformance
  alias LlmCall.{Config, Content, Message, Request}
  alias LlmCall.TestCodec.TextOnly

  defp codecs do
    [
      {LlmCall.Protocol.OpenAI.Chat, "gpt-4o", LlmCall.Fixtures.OpenAIChat.text_response(),
       "/v1/chat/completions"},
      {LlmCall.Protocol.Anthropic.Messages, "claude-sonnet-4-5",
       LlmCall.Fixtures.AnthropicMessages.text_response(), "/v1/messages"},
      {LlmCall.Protocol.Gemini.GenerateContent, "gemini-2.5-pro",
       LlmCall.Fixtures.GeminiGenerateContent.text_response(),
       "/v1beta/models/gemini-2.5-pro:generateContent"}
    ]
  end

  defp request(model, stream) do
    %Request{
      model: model,
      params: %{max_tokens: 64},
      stream: stream,
      messages: [%Message{role: :user, content: [%Content.Text{text: "hi"}]}]
    }
  end

  test "every codec satisfies the conformance contract" do
    for {codec, model, response, path} <- codecs() do
      assert :ok = Conformance.assert_info(codec)
      assert :ok = Conformance.assert_capabilities(codec, request(model, true), %Config{})
      assert :ok = Conformance.assert_path(codec, request(model, false), path)
      assert :ok = Conformance.assert_capture_raw(codec, response)
      assert :ok = Conformance.assert_stream_roundtrip(codec, request(model, true))
      assert :ok = Conformance.assert_stream_state_ownership(codec, TextOnly)
    end
  end
end

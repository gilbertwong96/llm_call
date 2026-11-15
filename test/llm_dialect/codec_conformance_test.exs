defmodule LlmDialect.CodecConformanceTest do
  use ExUnit.Case, async: true

  alias LlmDialect.Codec.Conformance
  alias LlmDialect.{Config, Content, Message, Request}
  alias LlmDialect.TestCodec.TextOnly

  defp codecs do
    [
      {LlmDialect.Protocol.OpenAI.Chat, "gpt-4o", LlmDialect.Fixtures.OpenAIChat.text_response(),
       "/v1/chat/completions"},
      {LlmDialect.Protocol.Anthropic.Messages, "claude-sonnet-4-5",
       LlmDialect.Fixtures.AnthropicMessages.text_response(), "/v1/messages"},
      {LlmDialect.Protocol.Gemini.GenerateContent, "gemini-2.5-pro",
       LlmDialect.Fixtures.GeminiGenerateContent.text_response(),
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

      assert :ok =
               Conformance.assert_stream_state_ownership(codec, TextOnly, request(model, true))
    end
  end

  test "a codec that is not loaded fails with a clear assertion" do
    assert_raise ExUnit.AssertionError, ~r/not loaded/, fn ->
      Conformance.assert_capabilities(
        LlmDialect.TestCodec.DoesNotExist,
        request("gpt-4o", true),
        %Config{}
      )
    end
  end

  test "ownership is checked with the caller's request, so unknown codecs work" do
    assert :ok =
             Conformance.assert_stream_state_ownership(
               LlmDialect.Protocol.OpenAI.Chat,
               LlmDialect.TestCodec.TextOnly,
               request("my-own-model", true)
             )
  end

  test "assert_rejects/3 pins the no-silent-drops promise" do
    request = %LlmDialect.Request{
      model: "gpt-4o",
      messages: [
        %LlmDialect.Message{role: :user, content: [%LlmDialect.Content.Text{text: "hi"}]}
      ],
      params: %{top_k: 5}
    }

    assert :ok = Conformance.assert_rejects(LlmDialect.Protocol.OpenAI.Chat, request, %Config{})

    assert_raise ExUnit.AssertionError, fn ->
      Conformance.assert_rejects(
        LlmDialect.Protocol.OpenAI.Chat,
        %LlmDialect.Request{
          model: "gpt-4o",
          messages: [
            %LlmDialect.Message{role: :user, content: [%LlmDialect.Content.Text{text: "hi"}]}
          ]
        },
        %Config{}
      )
    end
  end

  test "conformance assertions catch a violating codec" do
    codec = LlmDialect.Protocol.OpenAI.Chat

    assert_raise ExUnit.AssertionError, fn ->
      Conformance.assert_path(codec, request("gpt-4o", false), "/wrong")
    end

    assert_raise ExUnit.AssertionError, fn ->
      Conformance.assert_capture_raw(codec, %{"choices" => []})
    end
  end
end

defmodule LlmDialect.CodecConformanceTest do
  use ExUnit.Case, async: true

  alias LlmDialect.Codec.Conformance
  alias LlmDialect.{Config, Content, Message, Request}
  alias LlmDialect.TestCodec.TextOnly

  defp codecs do
    [
      {LlmDialect.Protocol.OpenAI.Chat, "gpt-4o", LlmDialect.Fixtures.OpenAIChat.text_response(),
       "/v1/chat/completions", LlmDialect.Fixtures.OpenAIChat.error_payload(),
       LlmDialect.Fixtures.OpenAIChat.text_chunks(),
       LlmDialect.Fixtures.OpenAIChat.tool_call_chunks()},
      {LlmDialect.Protocol.Anthropic.Messages, "claude-sonnet-4-5",
       LlmDialect.Fixtures.AnthropicMessages.text_response(), "/v1/messages",
       LlmDialect.Fixtures.AnthropicMessages.error_payload(),
       LlmDialect.Fixtures.AnthropicMessages.text_stream(),
       LlmDialect.Fixtures.AnthropicMessages.tool_stream()},
      {LlmDialect.Protocol.Gemini.GenerateContent, "gemini-2.5-pro",
       LlmDialect.Fixtures.GeminiGenerateContent.text_response(),
       "/v1beta/models/gemini-2.5-pro:generateContent",
       LlmDialect.Fixtures.GeminiGenerateContent.error_payload(),
       LlmDialect.Fixtures.GeminiGenerateContent.text_chunks(),
       LlmDialect.Fixtures.GeminiGenerateContent.tool_chunks()}
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
    for {codec, model, response, path, error_payload, chunks, tool_chunks} <- codecs() do
      assert :ok = Conformance.assert_info(codec)
      assert :ok = Conformance.assert_capabilities(codec, request(model, true), %Config{})
      assert :ok = Conformance.assert_path(codec, request(model, false), path)
      assert :ok = Conformance.assert_capture_raw(codec, response)
      assert :ok = Conformance.assert_decode_response(codec, response)
      assert :ok = Conformance.assert_invalid_response(codec, %{"unexpected" => true})
      assert :ok = Conformance.assert_decode_error(codec, error_payload)
      assert :ok = Conformance.assert_stream(codec, request(model, true), chunks)
      assert :ok = Conformance.assert_stream_capture_raw(codec, request(model, true), chunks)

      assert :ok =
               Conformance.assert_tool_call_assembly(
                 codec,
                 request(model, true),
                 tool_chunks,
                 1
               )

      assert :ok =
               Conformance.assert_capability_consistency(codec, request(model, false), %Config{})

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

    assert_raise ExUnit.AssertionError, ~r/text_delta must carry/, fn ->
      LlmDialect.Conformance.assert_stream_event(
        %LlmDialect.StreamEvent{
          type: :text_delta,
          delta: %LlmDialect.StreamDelta.Thinking{text: "hmm"}
        },
        "fake"
      )
    end

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

    assert_raise ExUnit.AssertionError, fn ->
      Conformance.assert_decode_response(codec, %{"unexpected" => true})
    end

    assert_raise ExUnit.AssertionError, fn ->
      Conformance.assert_invalid_response(codec, LlmDialect.Fixtures.OpenAIChat.text_response())
    end

    assert_raise ExUnit.AssertionError, fn ->
      Conformance.assert_decode_error(codec, %{"unexpected" => true})
    end

    assert_raise ExUnit.AssertionError, fn ->
      Conformance.assert_stream(codec, request("gpt-4o", true), [
        %{"error" => %{"message" => "boom"}}
      ])
    end

    assert_raise ExUnit.AssertionError, ~r/tool call/, fn ->
      Conformance.assert_tool_call_assembly(
        codec,
        request("gpt-4o", true),
        LlmDialect.Fixtures.OpenAIChat.tool_call_chunks(),
        2
      )
    end

    assert_raise ExUnit.AssertionError, ~r/declares tools: false/, fn ->
      Conformance.assert_capability_consistency(TextOnly, request("text-only", false), %Config{})
    end
  end
end

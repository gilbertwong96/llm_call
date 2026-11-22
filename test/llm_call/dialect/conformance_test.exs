defmodule LlmCall.Dialect.ConformanceTest do
  @moduledoc """
  Runs the core conformance suite over every reference codec this package ships.

  The suite itself is tested by `LlmCall.CodecConformanceTest` against fake
  codecs; this module is what proves the four reference adapters actually satisfy
  it. A package that cannot pass these is not publishable: they are the same
  assertions `CONTRIBUTING.md` asks an out-of-tree adapter to run.
  """

  use ExUnit.Case, async: true

  alias LlmCall.Codec.Conformance
  alias LlmCall.Config
  alias LlmCall.Content
  alias LlmCall.Fixtures
  alias LlmCall.Message
  alias LlmCall.Request

  # `max_tokens` is above the reasoning budget floor, so a codec that couples
  # `budget_tokens` to it (Anthropic) has a legal budget to accept.
  defp request(model, opts \\ []) do
    %Request{
      model: model,
      params: %{max_tokens: 4096},
      stream: Keyword.get(opts, :stream, false),
      messages: [%Message{role: :user, content: [%Content.Text{text: "hi"}]}]
    }
  end

  # Each codec publishes its own event envelope, so the chunk sequence is a
  # fixture concern: a codec's fixture names the stream it can decode.
  defp codecs do
    [
      {LlmCall.Dialect.OpenAI.Chat, "gpt-4o", Fixtures.OpenAIChat,
       %{
         text: &Fixtures.OpenAIChat.text_chunks/0,
         tools: &Fixtures.OpenAIChat.tool_call_chunks/0
       }},
      {LlmCall.Dialect.OpenAI.Responses, "gpt-5", Fixtures.OpenAIResponses,
       %{
         text: &Fixtures.OpenAIResponses.text_stream/0,
         tools: &Fixtures.OpenAIResponses.tool_call_stream/0
       }},
      {LlmCall.Dialect.Anthropic.Messages, "claude-sonnet-4-5", Fixtures.AnthropicMessages,
       %{
         text: &Fixtures.AnthropicMessages.text_stream/0,
         tools: &Fixtures.AnthropicMessages.tool_stream/0
       }},
      {LlmCall.Dialect.Gemini.GenerateContent, "gemini-2.5-flash", Fixtures.GeminiGenerateContent,
       %{
         text: &Fixtures.GeminiGenerateContent.text_chunks/0,
         tools: &Fixtures.GeminiGenerateContent.tool_chunks/0
       }}
    ]
  end

  test "every reference codec satisfies the metadata contract" do
    for {codec, model, _fixtures, _chunks} <- codecs() do
      assert :ok = Conformance.assert_info(codec)
      assert :ok = Conformance.assert_capabilities(codec, request(model), %Config{})
    end
  end

  test "every reference codec declares capabilities its validation honours" do
    for {codec, model, _fixtures, _chunks} <- codecs() do
      assert :ok = Conformance.assert_capability_consistency(codec, request(model), %Config{})
    end
  end

  test "every reference codec asks its provider to stream" do
    for {codec, model, _fixtures, _chunks} <- codecs() do
      assert :ok = Conformance.assert_stream_request(codec, request(model))
    end
  end

  test "every reference codec decodes a provider response and error" do
    for {codec, model, fixtures, _chunks} <- codecs() do
      assert :ok = Conformance.assert_decode_response(codec, fixtures.text_response())
      assert :ok = Conformance.assert_decode_error(codec, fixtures.error_payload())
      assert :ok = Conformance.assert_invalid_response(codec, %{"not" => "a response"})
      assert :ok = Conformance.assert_stream_roundtrip(codec, request(model, stream: true))
    end
  end

  test "every reference codec streams text events" do
    for {codec, model, _fixtures, chunks} <- codecs() do
      streaming = request(model, stream: true)
      text = chunks.text.()

      assert :ok = Conformance.assert_stream(codec, streaming, text)

      assert :ok = Conformance.assert_stream_capture_raw(codec, streaming, text)
    end
  end

  test "every reference codec assembles streamed tool calls" do
    for {codec, model, _fixtures, chunks} <- codecs() do
      assert :ok =
               Conformance.assert_tool_call_assembly(
                 codec,
                 request(model, stream: true),
                 chunks.tools.(),
                 1
               )
    end
  end
end

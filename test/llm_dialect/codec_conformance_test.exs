defmodule LlmDialect.TestCodec.IllegalStreamReturn do
  @moduledoc "Returns `:ok` from `decode_stream_event/3`, which is outside the callback contract."

  @behaviour LlmDialect.Codec

  alias LlmDialect.{Capabilities, Codec, EncodedRequest, Error, Response, StreamState}

  @impl true
  def info,
    do: %Codec.Info{name: :illegal_stream_return, protocol: :illegal_stream_return, ir_version: 1}

  @impl true
  def validate_request(_request, _config), do: :ok

  @impl true
  def encode_request(_request, _config),
    do: {:ok, %EncodedRequest{path: "/illegal-stream-return"}}

  @impl true
  def decode_response(%{"text" => text}, _config) do
    {:ok, %Response{content: [%LlmDialect.Content.Text{text: text}]}}
  end

  def decode_response(_term, _config),
    do: {:error, %Error{kind: :invalid_response, message: "illegal_stream_return"}}

  @impl true
  def decode_error(_term, _config),
    do: %Error{kind: :provider, message: "illegal_stream_return"}

  @impl true
  def capabilities(_request, _config), do: %Capabilities{streaming: true}

  @impl true
  def init_stream(_request, _config), do: {:ok, StreamState.new(__MODULE__, %{})}

  @impl true
  def decode_stream_event(_term, _config, _state), do: :ok

  @impl true
  def finish_stream(state, _config), do: {:ok, [], state}
end

defmodule LlmDialect.TestCodec.UsageAfterDone do
  @moduledoc "Flushes usage and a terminal event from `finish_stream/2` after `{:done, state}`, which is legal."

  @behaviour LlmDialect.Codec

  alias LlmDialect.{
    Capabilities,
    Codec,
    EncodedRequest,
    Error,
    Response,
    StreamEvent,
    StreamState
  }

  alias LlmDialect.StreamDelta

  @impl true
  def info,
    do: %Codec.Info{name: :usage_after_done, protocol: :usage_after_done, ir_version: 1}

  @impl true
  def validate_request(_request, _config), do: :ok

  @impl true
  def encode_request(_request, _config),
    do: {:ok, %EncodedRequest{path: "/usage-after-done"}}

  @impl true
  def decode_response(%{"text" => text}, _config) do
    {:ok, %Response{content: [%LlmDialect.Content.Text{text: text}]}}
  end

  def decode_response(_term, _config),
    do: {:error, %Error{kind: :invalid_response, message: "usage_after_done"}}

  @impl true
  def decode_error(_term, _config), do: %Error{kind: :provider, message: "usage_after_done"}

  @impl true
  def capabilities(_request, _config), do: %Capabilities{streaming: true}

  @impl true
  def init_stream(_request, _config), do: {:ok, StreamState.new(__MODULE__, %{})}

  @impl true
  def decode_stream_event(_term, _config, state), do: {:done, state}

  @impl true
  def finish_stream(state, _config) do
    usage = %LlmDialect.Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}

    {:ok,
     [
       %StreamEvent{
         type: :message_delta,
         delta: %StreamDelta.MessageDelta{usage: usage}
       },
       %StreamEvent{type: :message_stop}
     ], state}
  end
end

defmodule LlmDialect.TestCodec.DoneThenContent do
  @moduledoc "Emits content from `finish_stream/2` after `{:done, state}`, so conformance must catch it."

  @behaviour LlmDialect.Codec

  alias LlmDialect.{
    Capabilities,
    Codec,
    EncodedRequest,
    Error,
    Response,
    StreamEvent,
    StreamState
  }

  alias LlmDialect.StreamDelta

  @impl true
  def info,
    do: %Codec.Info{name: :done_then_content, protocol: :done_then_content, ir_version: 1}

  @impl true
  def validate_request(_request, _config), do: :ok

  @impl true
  def encode_request(_request, _config),
    do: {:ok, %EncodedRequest{path: "/done-then-content"}}

  @impl true
  def decode_response(%{"text" => text}, _config) do
    {:ok, %Response{content: [%LlmDialect.Content.Text{text: text}]}}
  end

  def decode_response(_term, _config),
    do: {:error, %Error{kind: :invalid_response, message: "done_then_content"}}

  @impl true
  def decode_error(_term, _config),
    do: %Error{kind: :provider, message: "done_then_content"}

  @impl true
  def capabilities(_request, _config), do: %Capabilities{streaming: true}

  @impl true
  def init_stream(_request, _config), do: {:ok, StreamState.new(__MODULE__, %{})}

  @impl true
  def decode_stream_event(_term, _config, state), do: {:done, state}

  @impl true
  def finish_stream(state, _config) do
    event = %StreamEvent{type: :text_delta, delta: %StreamDelta.Text{text: "late"}}
    {:ok, [event], state}
  end
end

defmodule LlmDialect.TestCodec.StreamWithoutSignal do
  @moduledoc "Encodes stream: true differently but never signals streaming, so conformance must catch it."

  @behaviour LlmDialect.Codec

  alias LlmDialect.{Capabilities, Codec, EncodedRequest, Error, Response, StreamState}

  @impl true
  def info,
    do: %Codec.Info{name: :stream_without_signal, protocol: :stream_without_signal, ir_version: 1}

  @impl true
  def validate_request(_request, _config), do: :ok

  @impl true
  def encode_request(request, _config) do
    {:ok,
     %EncodedRequest{
       method: :post,
       path: "/v1/no-signal",
       body: %{"model" => request.model, "transport" => request.stream}
     }}
  end

  @impl true
  def decode_response(%{"text" => text}, _config) do
    {:ok, %Response{content: [%LlmDialect.Content.Text{text: text}]}}
  end

  def decode_response(_term, _config),
    do: {:error, %Error{kind: :invalid_response, message: "stream_without_signal"}}

  @impl true
  def decode_error(_term, _config),
    do: %Error{kind: :provider, message: "stream_without_signal"}

  @impl true
  def capabilities(_request, _config), do: %Capabilities{streaming: true}

  @impl true
  def init_stream(_request, _config), do: {:ok, StreamState.new(__MODULE__, %{})}

  @impl true
  def decode_stream_event(_term, _config, state), do: {:done, state}

  @impl true
  def finish_stream(state, _config), do: {:ok, [], state}
end

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
      assert :ok = Conformance.assert_stream_request(codec, request(model, false))
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

  test "an unmapped provider field is a Raw message delta, not a contract violation" do
    {:ok, state} = LlmDialect.Protocol.OpenAI.Chat.init_stream(request("gpt-4o", true), %Config{})

    chunk = %{
      "choices" => [
        %{"index" => 0, "delta" => %{"refusal" => "no"}, "finish_reason" => nil}
      ]
    }

    assert {:ok, [event], _state} =
             LlmDialect.Protocol.OpenAI.Chat.decode_stream_event(chunk, %Config{}, state)

    assert event.type == :message_delta
    assert %LlmDialect.StreamDelta.Raw{} = event.delta
    assert :ok = LlmDialect.Conformance.assert_stream_event(event, "openai")
  end

  test "assert_stream/3 allows a usage flush after {:done, state}" do
    assert :ok =
             Conformance.assert_stream(
               LlmDialect.TestCodec.UsageAfterDone,
               request("usage-1", true),
               [%{}]
             )
  end

  test "assert_stream/3 catches content emitted after {:done, state}" do
    assert_raise ExUnit.AssertionError, ~r/only flush metadata/, fn ->
      Conformance.assert_stream(
        LlmDialect.TestCodec.DoneThenContent,
        request("done-1", true),
        [%{}]
      )
    end
  end

  test "assert_stream_request/3 catches a codec that never asks to stream" do
    assert_raise ExUnit.AssertionError, ~r/never asked to stream/, fn ->
      Conformance.assert_stream_request(LlmDialect.TestCodec.Fake, request("fake-1", false))
    end

    assert_raise ExUnit.AssertionError, ~r/does not signal streaming/, fn ->
      Conformance.assert_stream_request(
        LlmDialect.TestCodec.StreamWithoutSignal,
        request("no-signal-1", false)
      )
    end
  end

  test "assert_stream_request/3 accepts a custom streaming marker" do
    assert :ok =
             Conformance.assert_stream_request(
               LlmDialect.TestCodec.StreamWithoutSignal,
               request("no-signal-1", false),
               marker: fn encoded -> encoded.body["transport"] == true end
             )
  end

  test "the reference codecs signal streaming in their own way" do
    openai = LlmDialect.Protocol.OpenAI.Chat.encode_request(request("gpt-4o", true), %Config{})
    assert {:ok, %{body: %{"stream" => true}}} = openai

    anthropic =
      LlmDialect.Protocol.Anthropic.Messages.encode_request(
        request("claude-sonnet-4-5", true),
        %Config{}
      )

    assert {:ok, %{body: %{"stream" => true}}} = anthropic

    gemini =
      LlmDialect.Protocol.Gemini.GenerateContent.encode_request(
        request("gemini-2.5-pro", true),
        %Config{}
      )

    assert {:ok, %{query: %{"alt" => "sse"}, path: path}} = gemini
    assert path =~ "streamGenerateContent"
  end

  test "assert_stream_request/3 names a non-streamable base request" do
    assert_raise ExUnit.AssertionError, ~r/cannot encode this request with stream: true/, fn ->
      Conformance.assert_stream_request(
        LlmDialect.Protocol.Gemini.GenerateContent,
        %{request("gemini-2.5-pro", false) | modalities: [:text, :image]}
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

    assert_raise ExUnit.AssertionError, ~r/must return/, fn ->
      Conformance.assert_stream(
        LlmDialect.TestCodec.IllegalStreamReturn,
        request("illegal-1", true),
        [%{}]
      )
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

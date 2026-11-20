defmodule LlmCall.TestCodec.IllegalStreamReturn do
  @moduledoc "Returns `:ok` from `decode_stream_event/3`, which is outside the callback contract."

  @behaviour LlmCall.Codec

  alias LlmCall.{Capabilities, Codec, EncodedRequest, Error, Response, StreamState}

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
    {:ok, %Response{content: [%LlmCall.Content.Text{text: text}]}}
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

defmodule LlmCall.TestCodec.UsageAfterDone do
  @moduledoc "Flushes usage and a terminal event from `finish_stream/2` after `{:done, state}`, which is legal."

  @behaviour LlmCall.Codec

  alias LlmCall.{
    Capabilities,
    Codec,
    EncodedRequest,
    Error,
    Response,
    StreamEvent,
    StreamState
  }

  alias LlmCall.StreamDelta

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
    {:ok, %Response{content: [%LlmCall.Content.Text{text: text}]}}
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
    usage = %LlmCall.Usage{input_tokens: 1, output_tokens: 1, total_tokens: 2}

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

defmodule LlmCall.TestCodec.DoneThenContent do
  @moduledoc "Emits content from `finish_stream/2` after `{:done, state}`, so conformance must catch it."

  @behaviour LlmCall.Codec

  alias LlmCall.{
    Capabilities,
    Codec,
    EncodedRequest,
    Error,
    Response,
    StreamEvent,
    StreamState
  }

  alias LlmCall.StreamDelta

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
    {:ok, %Response{content: [%LlmCall.Content.Text{text: text}]}}
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

defmodule LlmCall.TestCodec.StreamWithoutSignal do
  @moduledoc "Encodes stream: true differently but never signals streaming, so conformance must catch it."

  @behaviour LlmCall.Codec

  alias LlmCall.{Capabilities, Codec, EncodedRequest, Error, Response, StreamState}

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
    {:ok, %Response{content: [%LlmCall.Content.Text{text: text}]}}
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

defmodule LlmCall.TestCodec.NoStreamAtAll do
  @moduledoc "Declares `streaming: false` and rejects a streaming request, to check the diagnosis."

  @behaviour LlmCall.Codec

  alias LlmCall.{Capabilities, Codec, EncodedRequest, Error, Response, StreamState}

  @impl true
  def info,
    do: %Codec.Info{name: :no_stream_at_all, protocol: :no_stream_at_all, ir_version: 1}

  @impl true
  def validate_request(_request, _config), do: :ok

  @impl true
  def encode_request(%{stream: true}, _config) do
    {:error, %Error{kind: :validation, message: "no_stream_at_all: no streaming"}}
  end

  def encode_request(request, _config) do
    {:ok, %EncodedRequest{method: :post, path: "/no-stream", body: %{"model" => request.model}}}
  end

  @impl true
  def decode_response(%{"text" => text}, _config) do
    {:ok, %Response{content: [%LlmCall.Content.Text{text: text}]}}
  end

  def decode_response(_term, _config),
    do: {:error, %Error{kind: :invalid_response, message: "no_stream_at_all"}}

  @impl true
  def decode_error(_term, _config),
    do: %Error{kind: :provider, message: "no_stream_at_all"}

  @impl true
  def capabilities(_request, _config), do: %Capabilities{streaming: false}

  @impl true
  def init_stream(_request, _config), do: {:ok, StreamState.new(__MODULE__, %{})}

  @impl true
  def decode_stream_event(_term, _config, state), do: {:done, state}

  @impl true
  def finish_stream(state, _config), do: {:ok, [], state}
end

defmodule LlmCall.CodecConformanceTest do
  use ExUnit.Case, async: true

  alias LlmCall.Codec.Conformance
  alias LlmCall.{Config, Content, Message, Request}
  alias LlmCall.Fixtures.OpenAIResponses, as: Responses
  alias LlmCall.TestCodec.TextOnly

  defp codecs do
    [
      {LlmCall.Dialect.OpenAI.Chat, "gpt-4o", LlmCall.Fixtures.OpenAIChat.text_response(),
       "/v1/chat/completions", LlmCall.Fixtures.OpenAIChat.error_payload(),
       LlmCall.Fixtures.OpenAIChat.text_chunks(), LlmCall.Fixtures.OpenAIChat.tool_call_chunks()},
      {LlmCall.Dialect.OpenAI.Responses, "gpt-4.1", Responses.text_response(), "/v1/responses",
       Responses.error_payload(), responses_text_chunks(), responses_tool_chunks()},
      {LlmCall.Dialect.Anthropic.Messages, "claude-sonnet-4-5",
       LlmCall.Fixtures.AnthropicMessages.text_response(), "/v1/messages",
       LlmCall.Fixtures.AnthropicMessages.error_payload(),
       LlmCall.Fixtures.AnthropicMessages.text_stream(),
       LlmCall.Fixtures.AnthropicMessages.tool_stream()},
      {LlmCall.Dialect.Gemini.GenerateContent, "gemini-2.5-pro",
       LlmCall.Fixtures.GeminiGenerateContent.text_response(),
       "/v1beta/models/gemini-2.5-pro:generateContent",
       LlmCall.Fixtures.GeminiGenerateContent.error_payload(),
       LlmCall.Fixtures.GeminiGenerateContent.text_chunks(),
       LlmCall.Fixtures.GeminiGenerateContent.tool_chunks()}
    ]
  end

  defp responses_text_chunks do
    [
      Responses.created(),
      Responses.output_item_added(%{"type" => "message", "role" => "assistant"}, 0),
      Responses.content_part_added(%{"type" => "output_text", "text" => ""}, 0),
      Responses.text_delta("hello", 0),
      Responses.text_done("hello", 0),
      Responses.content_part_done(%{"type" => "output_text", "text" => "hello"}, 0),
      Responses.output_item_done(
        Responses.message_item("msg_1", [%{"type" => "output_text", "text" => "hello"}]),
        0
      ),
      Responses.completed()
    ]
  end

  defp responses_tool_chunks do
    [
      Responses.created(),
      Responses.output_item_added(
        %{
          "type" => "function_call",
          "id" => "fc_1",
          "call_id" => "call_1",
          "name" => "get_weather"
        },
        0
      ),
      Responses.arguments_delta(~s({"city":), 0),
      Responses.arguments_done(~s({"city":"Oslo"}), 0)
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

  test "every codec pins which decoded parts it accepts back in a request" do
    for {codec, request} <- replay_cases() do
      assert :ok = Conformance.assert_replays(codec, request, replay_expectations(codec))
    end
  end

  defp replay_cases do
    [
      {LlmCall.Dialect.OpenAI.Chat, request("gpt-4o", false)},
      {LlmCall.Dialect.OpenAI.Responses, request("gpt-4.1", false)},
      {LlmCall.Dialect.Anthropic.Messages, request("claude-sonnet-4-5", false)},
      {LlmCall.Dialect.Gemini.GenerateContent, request("gemini-2.5-pro", false)}
    ]
  end

  defp replay_expectations(LlmCall.Dialect.OpenAI.Chat) do
    [
      text: :ok,
      tool_call: :ok,
      thinking: :rejected,
      thinking_without_signature: :rejected,
      raw: :rejected
    ]
  end

  defp replay_expectations(LlmCall.Dialect.OpenAI.Responses) do
    [
      text: :ok,
      tool_call: :ok,
      thinking: :rejected,
      thinking_without_signature: :rejected,
      raw: :rejected
    ]
  end

  defp replay_expectations(LlmCall.Dialect.Anthropic.Messages) do
    [text: :ok, tool_call: :ok, thinking: :ok, thinking_without_signature: :rejected, raw: :ok]
  end

  defp replay_expectations(LlmCall.Dialect.Gemini.GenerateContent) do
    [text: :ok, tool_call: :ok, thinking: :ok, thinking_without_signature: :ok, raw: :ok]
  end

  test "a codec that is not loaded fails with a clear assertion" do
    assert_raise ExUnit.AssertionError, ~r/not loaded/, fn ->
      Conformance.assert_capabilities(
        LlmCall.TestCodec.DoesNotExist,
        request("gpt-4o", true),
        %Config{}
      )
    end
  end

  test "ownership is checked with the caller's request, so unknown codecs work" do
    assert :ok =
             Conformance.assert_stream_state_ownership(
               LlmCall.Dialect.OpenAI.Chat,
               LlmCall.TestCodec.TextOnly,
               request("my-own-model", true)
             )
  end

  test "assert_rejects/3 pins the no-silent-drops promise" do
    request = %LlmCall.Request{
      model: "gpt-4o",
      messages: [
        %LlmCall.Message{role: :user, content: [%LlmCall.Content.Text{text: "hi"}]}
      ],
      params: %{top_k: 5}
    }

    assert :ok = Conformance.assert_rejects(LlmCall.Dialect.OpenAI.Chat, request, %Config{})

    assert_raise ExUnit.AssertionError, ~r/text_delta must carry/, fn ->
      LlmCall.Conformance.assert_stream_event(
        %LlmCall.StreamEvent{
          type: :text_delta,
          delta: %LlmCall.StreamDelta.Thinking{text: "hmm"}
        },
        "fake"
      )
    end

    assert_raise ExUnit.AssertionError, fn ->
      Conformance.assert_rejects(
        LlmCall.Dialect.OpenAI.Chat,
        %LlmCall.Request{
          model: "gpt-4o",
          messages: [
            %LlmCall.Message{role: :user, content: [%LlmCall.Content.Text{text: "hi"}]}
          ]
        },
        %Config{}
      )
    end
  end

  test "an unmapped provider field is a Raw message delta, not a contract violation" do
    {:ok, state} = LlmCall.Dialect.OpenAI.Chat.init_stream(request("gpt-4o", true), %Config{})

    chunk = %{
      "choices" => [
        %{"index" => 0, "delta" => %{"refusal" => "no"}, "finish_reason" => nil}
      ]
    }

    assert {:ok, [event], _state} =
             LlmCall.Dialect.OpenAI.Chat.decode_stream_event(chunk, %Config{}, state)

    assert event.type == :message_delta
    assert %LlmCall.StreamDelta.Raw{} = event.delta
    assert :ok = LlmCall.Conformance.assert_stream_event(event, "openai")
  end

  test "assert_stream/3 allows a usage flush after {:done, state}" do
    assert :ok =
             Conformance.assert_stream(
               LlmCall.TestCodec.UsageAfterDone,
               request("usage-1", true),
               [%{}]
             )
  end

  test "assert_stream/3 catches content emitted after {:done, state}" do
    assert_raise ExUnit.AssertionError, ~r/only flush metadata/, fn ->
      Conformance.assert_stream(
        LlmCall.TestCodec.DoneThenContent,
        request("done-1", true),
        [%{}]
      )
    end
  end

  test "assert_stream_request/3 ignores a model id that contains \"stream\"" do
    assert :ok =
             Conformance.assert_stream_request(
               LlmCall.Dialect.Gemini.GenerateContent,
               request("my-stream-model", false)
             )
  end

  test "assert_stream_request/3 pins a signal a protocol cannot lose" do
    assert :ok =
             Conformance.assert_stream_request(
               LlmCall.Dialect.Gemini.GenerateContent,
               request("gemini-2.5-pro", false),
               require: [query: %{"alt" => "sse"}]
             )

    assert_raise ExUnit.AssertionError, ~r/streaming query must carry/, fn ->
      Conformance.assert_stream_request(
        LlmCall.Dialect.OpenAI.Chat,
        request("gpt-4o", false),
        require: [query: %{"alt" => "sse"}]
      )
    end
  end

  test "assert_stream_request/3 names a codec that declares streaming: false" do
    assert_raise ExUnit.AssertionError, ~r/declares streaming: false/, fn ->
      Conformance.assert_stream_request(
        LlmCall.TestCodec.NoStreamAtAll,
        request("no-stream-1", false)
      )
    end
  end

  test "assert_decode_error/3 pins the normalized code and retryable hint" do
    payload = %{"error" => %{"message" => "slow down", "code" => "rate_limit_exceeded"}}

    assert_raise ExUnit.AssertionError, ~r/normalize code/, fn ->
      Conformance.assert_decode_error(LlmCall.Dialect.OpenAI.Chat, payload, code: "nope")
    end

    assert :ok =
             Conformance.assert_decode_error(LlmCall.Dialect.OpenAI.Chat, payload,
               code: "rate_limit_exceeded",
               retryable?: true
             )
  end

  test "assert_reserved_options/4 pins the no-silent-override promise" do
    request = %{request("gpt-4o", false) | tool_choice: :auto}

    assert :ok =
             Conformance.assert_reserved_options(
               LlmCall.Dialect.OpenAI.Chat,
               request,
               %Config{},
               [%{openai: %{"model" => "evil"}}, %{openai: %{"messages" => []}}]
             )

    assert_raise ExUnit.AssertionError, fn ->
      Conformance.assert_reserved_options(
        LlmCall.Dialect.OpenAI.Chat,
        request,
        %Config{},
        [%{openai: %{"logprobs" => true}}]
      )
    end
  end

  test "assert_stream_request/3 catches a codec that never asks to stream" do
    assert_raise ExUnit.AssertionError, ~r/never asked to stream/, fn ->
      Conformance.assert_stream_request(LlmCall.TestCodec.Fake, request("fake-1", false))
    end

    assert_raise ExUnit.AssertionError, ~r/does not signal streaming/, fn ->
      Conformance.assert_stream_request(
        LlmCall.TestCodec.StreamWithoutSignal,
        request("no-signal-1", false)
      )
    end
  end

  test "assert_stream_request/3 accepts a custom streaming marker" do
    assert :ok =
             Conformance.assert_stream_request(
               LlmCall.TestCodec.StreamWithoutSignal,
               request("no-signal-1", false),
               marker: fn encoded -> encoded.body["transport"] == true end
             )
  end

  test "the reference codecs signal streaming in their own way" do
    openai = LlmCall.Dialect.OpenAI.Chat.encode_request(request("gpt-4o", true), %Config{})
    assert {:ok, %{body: %{"stream" => true}}} = openai

    anthropic =
      LlmCall.Dialect.Anthropic.Messages.encode_request(
        request("claude-sonnet-4-5", true),
        %Config{}
      )

    assert {:ok, %{body: %{"stream" => true}}} = anthropic

    gemini =
      LlmCall.Dialect.Gemini.GenerateContent.encode_request(
        request("gemini-2.5-pro", true),
        %Config{}
      )

    assert {:ok, %{query: %{"alt" => "sse"}, path: path}} = gemini
    assert path =~ "streamGenerateContent"
  end

  test "assert_stream_request/3 names a non-streamable base request" do
    assert_raise ExUnit.AssertionError, ~r/cannot encode this request with stream: true/, fn ->
      Conformance.assert_stream_request(
        LlmCall.Dialect.Gemini.GenerateContent,
        %{request("gemini-2.5-pro", false) | modalities: [:text, :image]}
      )
    end
  end

  test "conformance assertions catch a violating codec" do
    codec = LlmCall.Dialect.OpenAI.Chat

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
      Conformance.assert_invalid_response(codec, LlmCall.Fixtures.OpenAIChat.text_response())
    end

    assert_raise ExUnit.AssertionError, fn ->
      Conformance.assert_decode_error(codec, %{"unexpected" => true})
    end

    assert_raise ExUnit.AssertionError, ~r/must return/, fn ->
      Conformance.assert_stream(
        LlmCall.TestCodec.IllegalStreamReturn,
        request("illegal-1", true),
        [%{}]
      )
    end

    assert_raise ExUnit.AssertionError, ~r/tool call/, fn ->
      Conformance.assert_tool_call_assembly(
        codec,
        request("gpt-4o", true),
        LlmCall.Fixtures.OpenAIChat.tool_call_chunks(),
        2
      )
    end

    assert_raise ExUnit.AssertionError, ~r/declares tools: false/, fn ->
      Conformance.assert_capability_consistency(TextOnly, request("text-only", false), %Config{})
    end
  end

  describe "assert_error/2" do
    test "accepts a transport error with its status" do
      error = %LlmCall.Error{
        kind: :transport,
        message: "HTTP 500",
        status: 500,
        retryable?: false
      }

      assert :ok == LlmCall.Conformance.assert_error(error, "probe")
    end

    test "rejects a status on a codec error" do
      error = %LlmCall.Error{
        kind: :invalid_response,
        message: "bad",
        status: 500,
        retryable?: false
      }

      assert_raise ExUnit.AssertionError, ~r/only the transport knows/, fn ->
        LlmCall.Conformance.assert_error(error, "probe")
      end
    end

    test "rejects a non-integer transport status" do
      error = %LlmCall.Error{kind: :transport, message: "HTTP", status: "500", retryable?: false}

      assert_raise ExUnit.AssertionError, ~r/status must be an integer/, fn ->
        LlmCall.Conformance.assert_error(error, "probe")
      end
    end

    test "accepts a structured transport reason" do
      for reason <- [:econnrefused, :timeout, {:unknown_pool, MyPool}, {:tls_alert, "bad"}] do
        error = %LlmCall.Error{kind: :transport, message: "boom", reason: reason}

        assert :ok == LlmCall.Conformance.assert_error(error, "probe")
      end
    end

    test "rejects a reason on a codec error" do
      error = %LlmCall.Error{kind: :provider, message: "bad", reason: :econnrefused}

      assert_raise ExUnit.AssertionError, ~r/only the transport knows/, fn ->
        LlmCall.Conformance.assert_error(error, "probe")
      end
    end

    test "rejects a non-atom, non-tuple transport reason" do
      error = %LlmCall.Error{kind: :transport, message: "boom", reason: "econnrefused"}

      assert_raise ExUnit.AssertionError, ~r/reason must be an atom/, fn ->
        LlmCall.Conformance.assert_error(error, "probe")
      end
    end
  end
end

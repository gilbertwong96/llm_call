defmodule LlmDialect.ApiTest do
  use ExUnit.Case, async: true

  alias LlmDialect.{
    Capabilities,
    Config,
    Content,
    Error,
    Message,
    Request,
    StreamEvent,
    StreamState
  }

  alias LlmDialect.TestCodec.{Fake, TextOnly}

  defp request do
    %Request{
      model: "test-1",
      messages: [%Message{role: :user, content: [%Content.Text{text: "hi"}]}]
    }
  end

  test "encode/3 delegates to the codec" do
    assert {:ok, encoded} = LlmDialect.encode(Fake, request())
    assert encoded.path == "/fake"
    assert encoded.body == %{"model" => "test-1"}
  end

  test "encode/3 surfaces codec validation errors" do
    assert {:error, %Error{kind: :validation}} = LlmDialect.encode(Fake, %Request{})
  end

  test "decode_response/3 honors capture_raw" do
    assert {:ok, %LlmDialect.Response{raw: nil}} =
             LlmDialect.decode_response(Fake, %{"text" => "hi"})

    config = %Config{capture_raw: :response}

    assert {:ok, %LlmDialect.Response{raw: %{"text" => "hi"}}} =
             LlmDialect.decode_response(Fake, %{"text" => "hi"}, config)
  end

  test "decode_response/3 returns a typed error on a bad payload" do
    assert {:error, %Error{kind: :invalid_response, message: "fake: bad payload"}} =
             LlmDialect.decode_response(Fake, %{"nope" => 1})
  end

  test "decode_error/3 returns an Error struct" do
    assert %Error{kind: :provider, message: "boom", raw: %{"error" => %{"message" => "boom"}}} =
             LlmDialect.decode_error(Fake, %{"error" => %{"message" => "boom"}})
  end

  test "validate_request/3 and capabilities/3 delegate" do
    assert :ok = LlmDialect.validate_request(Fake, request())

    assert {:ok, %Capabilities{tools: true, streaming: true}} =
             LlmDialect.capabilities(Fake, request())
  end

  test "capabilities/3 works for a codec without a request model" do
    assert {:ok, %Capabilities{streaming: false}} = LlmDialect.capabilities(TextOnly, %Request{})
  end

  test "completion dispatch rejects a media codec instead of raising" do
    for fun <- [:encode, :decode_response, :validate_request, :capabilities] do
      assert {:error, %Error{kind: :validation, message: message}} =
               apply(LlmDialect, fun, [LlmDialect.TestCodec.FakeMedia, request()])

      assert message =~ "does not support"
    end
  end

  test "streaming round trip through the public API" do
    config = %Config{capture_raw: :all}
    assert {:ok, %StreamState{} = state} = LlmDialect.init_stream(Fake, request(), config)
    assert StreamState.codec(state) == Fake

    assert {:ok,
            [
              %StreamEvent{
                type: :text_delta,
                delta: %LlmDialect.StreamDelta.Text{text: "a"},
                raw: raw
              }
            ], state} =
             LlmDialect.decode_stream_event(Fake, %{"delta" => "a"}, config, state)

    assert raw == %{"delta" => "a"}
    assert {:done, %StreamState{}} = LlmDialect.decode_stream_event(Fake, "[DONE]", config, state)

    assert {:ok, [%StreamEvent{type: :message_stop}], %StreamState{}} =
             LlmDialect.finish_stream(Fake, state, config)
  end

  test "a state from another codec is a typed error, not a crash" do
    {:ok, state} = LlmDialect.init_stream(Fake, request())

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmDialect.decode_stream_event(TextOnly, %{"delta" => "a"}, %Config{}, state)

    assert message =~ "stream state"

    assert {:error, %Error{kind: :validation}} =
             LlmDialect.finish_stream(TextOnly, state, %Config{})

    text_state = StreamState.new(TextOnly, %{})

    assert {:error, %Error{kind: :validation}} =
             LlmDialect.decode_stream_event(Fake, %{"delta" => "a"}, %Config{}, text_state)
  end

  test "a codec without streaming callbacks returns a typed error" do
    assert {:error, %Error{kind: :validation, message: message}} =
             LlmDialect.init_stream(TextOnly, request())

    assert message =~ "does not support"
    assert message =~ "init_stream/2"

    {:ok, state} = LlmDialect.init_stream(Fake, request())
    assert {:ok, [%StreamEvent{type: :message_stop}], _} = LlmDialect.finish_stream(Fake, state)
  end

  test "capture_raw :none does not retain stream payloads" do
    {:ok, state} = LlmDialect.init_stream(Fake, request())

    assert {:ok, [%StreamEvent{raw: nil}], _state} =
             LlmDialect.decode_stream_event(Fake, %{"delta" => "a"}, %Config{}, state)
  end
end

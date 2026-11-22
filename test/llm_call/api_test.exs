defmodule LlmCall.ApiTest do
  use ExUnit.Case, async: true

  alias LlmCall.{
    Capabilities,
    Config,
    Content,
    EncodedRequest,
    Error,
    Message,
    Operation,
    Request,
    StreamEvent,
    StreamState
  }

  alias LlmCall.TestCodec.{Fake, TextOnly}

  defmodule EncodeOnly do
    @moduledoc false

    def validate_request(_request, _config), do: :ok

    def encode_request(request, _config) do
      {:ok, %LlmCall.EncodedRequest{path: "/only", body: %{"model" => request.model}}}
    end

    def capabilities(_request, _config), do: %LlmCall.Capabilities{}
  end

  defmodule EncodeOnlyProvider do
    @moduledoc false

    use LlmCall.Provider,
      base_url: "http://127.0.0.1:1",
      auth: :none,
      codecs: [chat: EncodeOnly]
  end

  defmodule SubmitOnly do
    @moduledoc false

    def validate_request(_request, _config), do: :ok

    def encode_submit(request, _config) do
      {:ok, %LlmCall.EncodedRequest{path: "/submit", body: %{"prompt" => request.prompt}}}
    end
  end

  defmodule SubmitOnlyProvider do
    @moduledoc false

    use LlmCall.Provider,
      base_url: "http://127.0.0.1:1",
      auth: :none,
      codecs: [images: SubmitOnly]
  end

  defp request do
    %Request{
      model: "test-1",
      messages: [%Message{role: :user, content: [%Content.Text{text: "hi"}]}]
    }
  end

  test "encode/3 delegates to the codec" do
    assert {:ok, encoded} = LlmCall.encode(Fake, request())
    assert encoded.path == "/fake"
    assert encoded.body == %{"model" => "test-1"}
  end

  test "encode/3 surfaces codec validation errors" do
    assert {:error, %Error{kind: :validation}} = LlmCall.encode(Fake, %Request{})
  end

  test "decode_response/3 honors capture_raw" do
    assert {:ok, %LlmCall.Response{raw: nil}} =
             LlmCall.decode_response(Fake, %{"text" => "hi"})

    config = %Config{capture_raw: :response}

    assert {:ok, %LlmCall.Response{raw: %{"text" => "hi"}}} =
             LlmCall.decode_response(Fake, %{"text" => "hi"}, config)
  end

  test "decode_response/3 returns a typed error on a bad payload" do
    assert {:error, %Error{kind: :invalid_response, message: "fake: bad payload"}} =
             LlmCall.decode_response(Fake, %{"nope" => 1})
  end

  test "decode_error/3 returns an Error struct" do
    assert %Error{kind: :provider, message: "boom", raw: %{"error" => %{"message" => "boom"}}} =
             LlmCall.decode_error(Fake, %{"error" => %{"message" => "boom"}})
  end

  test "decode_error/3 returns a typed error when the codec has no callback" do
    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.decode_error(EncodeOnly, %{"error" => %{"message" => "boom"}})

    assert message =~ "does not export decode_error/2"
  end

  test "validate_request/3 and capabilities/3 delegate" do
    assert :ok = LlmCall.validate_request(Fake, request())

    assert {:ok, %Capabilities{tools: true, streaming: true}} =
             LlmCall.capabilities(Fake, request())
  end

  test "capabilities/3 works for a codec without a request model" do
    assert {:ok, %Capabilities{streaming: false}} = LlmCall.capabilities(TextOnly, %Request{})
  end

  test "completion dispatch rejects a media codec instead of raising" do
    for fun <- [:encode, :decode_response, :validate_request, :capabilities] do
      assert {:error, %Error{kind: :validation, message: message}} =
               apply(LlmCall, fun, [LlmCall.TestCodec.FakeMedia, request()])

      assert message =~ "does not export"
    end
  end

  test "streaming round trip through the public API" do
    config = %Config{capture_raw: :all}
    assert {:ok, %StreamState{} = state} = LlmCall.init_stream(Fake, request(), config)
    assert StreamState.codec(state) == Fake

    assert {:ok,
            [
              %StreamEvent{
                type: :text_delta,
                delta: %LlmCall.StreamDelta.Text{text: "a"},
                raw: raw
              }
            ], state} =
             LlmCall.decode_stream_event(Fake, %{"delta" => "a"}, config, state)

    assert raw == %{"delta" => "a"}
    assert {:done, %StreamState{}} = LlmCall.decode_stream_event(Fake, "[DONE]", config, state)

    assert {:ok, [%StreamEvent{type: :message_stop}], %StreamState{}} =
             LlmCall.finish_stream(Fake, state, config)
  end

  test "a state from another codec is a typed error, not a crash" do
    {:ok, state} = LlmCall.init_stream(Fake, request())

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.decode_stream_event(TextOnly, %{"delta" => "a"}, %Config{}, state)

    assert message =~ "stream state"

    assert {:error, %Error{kind: :validation}} =
             LlmCall.finish_stream(TextOnly, state, %Config{})

    text_state = StreamState.new(TextOnly, %{})

    assert {:error, %Error{kind: :validation}} =
             LlmCall.decode_stream_event(Fake, %{"delta" => "a"}, %Config{}, text_state)
  end

  test "an unknown codec module is a typed error" do
    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.encode(LlmCall.TestCodec.DoesNotExist, request())

    assert message =~ "does not export"
  end

  test "a codec without streaming callbacks returns a typed error" do
    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.init_stream(TextOnly, request())

    assert message =~ "does not export"
    assert message =~ "init_stream/2"

    {:ok, state} = LlmCall.init_stream(Fake, request())
    assert {:ok, [%StreamEvent{type: :message_stop}], _} = LlmCall.finish_stream(Fake, state)
  end

  test "capture_raw :none does not retain stream payloads" do
    {:ok, state} = LlmCall.init_stream(Fake, request())

    assert {:ok, [%StreamEvent{raw: nil}], _state} =
             LlmCall.decode_stream_event(Fake, %{"delta" => "a"}, %Config{}, state)
  end

  test "fetch/2 rejects an operation without a next request" do
    client = LlmCall.TestProvider.client(api_key: "k", base_url: "http://127.0.0.1:1")

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.fetch(client, %Operation{})

    assert message =~ "no next request"
  end

  test "fetch/2 rejects a poll operation instead of returning its raw body" do
    client = LlmCall.TestProvider.client(api_key: "k", base_url: "http://127.0.0.1:1")

    operation = %Operation{
      next_kind: :poll,
      next: %EncodedRequest{method: :get, path: "/poll"}
    }

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.fetch(client, operation)

    assert message =~ "poll/3"
  end

  test "complete/3 rejects a codec without decode_response/2 before sending" do
    LlmCall.TestHTTPServer.start()
    on_exit(&LlmCall.TestHTTPServer.stop/0)

    LlmCall.TestHTTPServer.put_response({:ok, %{status: 200, headers: [], body: "{}"}})

    client = EncodeOnlyProvider.client(base_url: LlmCall.TestHTTPServer.url())

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.complete(client, request())

    assert message =~ "decode_response/2"
    assert LlmCall.TestHTTPServer.requests() == []
  end

  test "generate/3 rejects a media codec without decode_submit/2 before sending" do
    LlmCall.TestHTTPServer.start()
    on_exit(&LlmCall.TestHTTPServer.stop/0)

    LlmCall.TestHTTPServer.put_response({:ok, %{status: 200, headers: [], body: "{}"}})

    client = SubmitOnlyProvider.client(base_url: LlmCall.TestHTTPServer.url())

    media = %LlmCall.Media.Request{modality: :image, model: "m", prompt: "p"}

    assert {:error, %Error{kind: :validation, message: message}} =
             LlmCall.generate(client, media, codec: :images)

    assert message =~ "decode_submit/2"
    assert LlmCall.TestHTTPServer.requests() == []
  end

  describe "a wrong request shape is a tagged error, not a crash" do
    test "encode/3 and capabilities/3" do
      for fun <- [&LlmCall.encode/3, &LlmCall.capabilities/3] do
        assert {:error, %Error{kind: :validation, message: message}} =
                 fun.(Fake, %{"model" => "gpt-4o"}, %Config{})

        assert message =~ "%LlmCall.Request{}"
      end
    end

    test "encode_media/3 and media_capabilities/3" do
      for fun <- [&LlmCall.encode_media/3, &LlmCall.media_capabilities/3] do
        assert {:error, %Error{kind: :validation, message: message}} =
                 fun.(LlmCall.Media.Dialect.OpenAI.Images, %{"model" => "m"}, %Config{})

        assert message =~ "%LlmCall.Media.Request{}"
      end
    end

    test "the dispatch functions that take a stream state" do
      state = %LlmCall.StreamState{codec: Fake, data: %{}}

      assert {:error, %Error{kind: :validation, message: message}} =
               LlmCall.validate_request(Fake, %{model: "x"}, %Config{})

      assert message =~ "%LlmCall.Request{}"

      assert {:error, %Error{message: message}} = LlmCall.init_stream(Fake, %{model: "x"})
      assert message =~ "%LlmCall.Request{}"

      assert {:error, %Error{message: message}} = LlmCall.finish_stream(Fake, %{}, %Config{})
      assert message =~ "%LlmCall.StreamState{}"

      assert {:error, %Error{message: message}} =
               LlmCall.decode_stream_event(Fake, %{}, %Config{}, %{})

      assert message =~ "%LlmCall.StreamState{}"

      # A real state still reaches the codec.
      assert {:ok, _events, %LlmCall.StreamState{}} =
               LlmCall.decode_stream_event(Fake, %{}, %Config{}, state)
    end

    test "the top-level calls name the argument that did not match" do
      client = LlmCall.TestProvider.client(api_key: "k", base_url: "https://x.test")

      request = %Request{
        model: "fake-1",
        messages: [%Message{role: :user, content: [%Content.Text{text: "hi"}]}]
      }

      assert {:error, %Error{kind: :validation, message: message}} =
               LlmCall.complete(client, %{model: "x"})

      assert message =~ "%LlmCall.Request{}"

      assert {:error, %Error{message: message}} =
               LlmCall.complete(Map.from_struct(client), request)

      assert message =~ "%LlmCall.Client{}"

      assert {:error, %Error{kind: :validation}} = LlmCall.stream(client, %{model: "x"})
      assert {:error, %Error{kind: :validation}} = LlmCall.execute(client, %{})
      assert {:error, %Error{kind: :validation}} = LlmCall.fetch(client, %{})
      assert {:error, %Error{kind: :validation}} = LlmCall.poll(client, %{})
    end

    test "the arity-2 form still applies the default config" do
      assert {:error, %Error{kind: :validation}} = LlmCall.encode(Fake, %{model: "x"})
      assert {:error, %Error{kind: :validation}} = LlmCall.capabilities(Fake, %{model: "x"})
    end
  end
end

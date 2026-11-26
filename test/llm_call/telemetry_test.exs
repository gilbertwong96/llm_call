defmodule LlmCall.TelemetryTest do
  # `:telemetry.attach_many/4` is global to the node and a handler sees every event of
  # that name, so these tests must not run beside another module's calls. The `model`
  # filter is a second guard: it keeps a stray event from another sync test out of the
  # assertions without making the suite order-dependent.
  use ExUnit.Case, async: false

  alias LlmCall.{Capabilities, Codec, Content, EncodedRequest, Error, Message, Request, Usage}
  alias LlmCall.TestHTTPServer, as: TestHTTP

  @request_events [
    [:llm_call, :request, :start],
    [:llm_call, :request, :stop],
    [:llm_call, :request, :exception]
  ]
  @stream_events [
    [:llm_call, :stream, :start],
    [:llm_call, :stream, :first_event],
    [:llm_call, :stream, :first_text],
    [:llm_call, :stream, :stop],
    [:llm_call, :stream, :exception]
  ]
  @events @request_events ++ @stream_events

  defmodule UsageCodec do
    @moduledoc false

    @behaviour LlmCall.Codec

    @impl true
    def info, do: %Codec.Info{name: :usage, protocol: :usage, ir_version: 1}

    @impl true
    def validate_request(_request, _config), do: :ok

    @impl true
    def encode_request(_request, _config), do: {:ok, %EncodedRequest{path: "/usage", body: %{}}}

    @impl true
    def decode_response(%{"usage" => usage}, _config) do
      {:ok,
       %LlmCall.Response{
         stop_reason: :max_tokens,
         usage: %Usage{
           input_tokens: usage["in"],
           output_tokens: usage["out"],
           total_tokens: usage["total"],
           cache_read_tokens: usage["cache_read"]
         }
       }}
    end

    def decode_response(_term, _config),
      do: {:error, %Error{kind: :invalid_response, message: "bad"}}

    @impl true
    def decode_error(%{"error" => %{"message" => message}}, _config),
      do: %Error{kind: :provider, message: message}

    def decode_error(_term, _config),
      do: %Error{kind: :invalid_response, message: "bad"}

    @impl true
    def capabilities(_request, _config), do: %Capabilities{}
  end

  defmodule RaisingCodec do
    @moduledoc false

    @behaviour LlmCall.Codec

    @impl true
    def info, do: %Codec.Info{name: :raising, protocol: :raising, ir_version: 1}

    @impl true
    def validate_request(_request, _config), do: :ok

    @impl true
    def encode_request(_request, _config), do: {:ok, %EncodedRequest{path: "/raising", body: %{}}}

    @impl true
    def decode_response(_term, _config), do: raise("decode failed")

    @impl true
    def decode_error(_term, _config), do: %Error{kind: :invalid_response, message: "bad"}

    @impl true
    def capabilities(_request, _config), do: %Capabilities{}
  end

  defmodule UsageProvider do
    @moduledoc false

    use LlmCall.Provider,
      base_url: "http://127.0.0.1:1",
      auth: :bearer,
      codecs: [chat: UsageCodec]
  end

  defmodule RaisingProvider do
    @moduledoc false

    use LlmCall.Provider,
      base_url: "http://127.0.0.1:1",
      auth: :bearer,
      codecs: [chat: RaisingCodec]
  end

  defmodule SkeletonCodec do
    @moduledoc "Emits a skeleton event before any text, as real providers do."

    @behaviour LlmCall.Codec

    alias LlmCall.{
      Capabilities,
      Codec,
      EncodedRequest,
      Error,
      StreamDelta,
      StreamEvent,
      StreamState
    }

    @impl true
    def info, do: %Codec.Info{name: :skeleton, protocol: :skeleton, ir_version: 1}

    @impl true
    def validate_request(_request, _config), do: :ok

    @impl true
    def encode_request(_request, _config),
      do: {:ok, %EncodedRequest{path: "/skeleton", body: %{}}}

    @impl true
    def decode_response(_term, _config),
      do: {:error, %Error{kind: :invalid_response, message: "skeleton"}}

    @impl true
    def decode_error(_term, _config),
      do: %Error{kind: :invalid_response, message: "skeleton"}

    @impl true
    def capabilities(_request, _config), do: %Capabilities{streaming: true}

    @impl true
    def init_stream(_request, _config), do: {:ok, StreamState.new(__MODULE__, %{})}

    @impl true
    def decode_stream_event(%{"start" => true}, _config, state),
      do: {:ok, [%StreamEvent{type: :message_start}], state}

    def decode_stream_event(%{"text" => text}, _config, state) do
      event = %StreamEvent{type: :text_delta, delta: %StreamDelta.Text{text: text}}
      {:ok, [event], state}
    end

    def decode_stream_event("[DONE]", _config, state), do: {:done, state}
    def decode_stream_event(_term, _config, state), do: {:ok, [], state}

    @impl true
    def finish_stream(state, _config), do: {:ok, [], state}
  end

  defmodule SkeletonProvider do
    @moduledoc "Emits a skeleton event before the first text, as Anthropic and OpenAI do."

    use LlmCall.Provider,
      base_url: "http://127.0.0.1:1",
      auth: :bearer,
      codecs: [chat: SkeletonCodec]
  end

  setup do
    TestHTTP.start()
    on_exit(&TestHTTP.stop/0)
    :ok
  end

  defp request(model) do
    %Request{
      model: model,
      messages: [%Message{role: :user, content: [%Content.Text{text: "hi"}]}]
    }
  end

  defp sse(payload), do: "data: #{payload}\n\n"

  defp attach(model) do
    handler = {__MODULE__, make_ref()}
    :telemetry.attach_many(handler, @events, &__MODULE__.handle_event/4, {self(), model})
    on_exit(fn -> :telemetry.detach(handler) end)
  end

  @doc false
  def handle_event(event, measurements, metadata, {test, model}) do
    if metadata[:model] == model,
      do: send(test, {:telemetry, event, measurements, metadata})
  end

  defp emitted(acc \\ []) do
    receive do
      {:telemetry, event, measurements, metadata} ->
        emitted([{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "complete/3 emits :start then :stop, carrying the call identity and the token counts" do
    model = "telemetry-complete"
    attach(model)

    TestHTTP.put_response(
      {:ok, %{status: 200, headers: [], body: ~s({"usage":{"in":11,"out":3,"total":14}})}}
    )

    client = UsageProvider.client(api_key: "k", base_url: TestHTTP.url())
    assert {:ok, _response} = LlmCall.complete(client, request(model))

    assert [
             {[:llm_call, :request, :start], start_measurements, start_metadata},
             {[:llm_call, :request, :stop], stop_measurements, stop_metadata}
           ] = emitted()

    assert is_integer(start_measurements.system_time)

    assert %{
             operation: :complete,
             provider: UsageProvider,
             codec: UsageCodec,
             model: ^model
           } = start_metadata

    assert %{input_tokens: 11, output_tokens: 3, total_tokens: 14} = stop_measurements
    assert is_integer(stop_measurements.duration) and stop_measurements.duration >= 0
    assert %{outcome: :ok, stop_reason: :max_tokens} = stop_metadata
  end

  test "a token count the provider did not report is omitted, not zeroed" do
    model = "telemetry-absent-usage"
    attach(model)
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"usage":{"in":11}})}})

    client = UsageProvider.client(api_key: "k", base_url: TestHTTP.url())
    assert {:ok, _response} = LlmCall.complete(client, request(model))

    {[:llm_call, :request, :stop], measurements, _metadata} = List.last(emitted())

    assert measurements.input_tokens == 11
    refute Map.has_key?(measurements, :output_tokens)
    refute Map.has_key?(measurements, :cache_read_tokens)
  end

  test "a provider error is a :stop, not an :exception" do
    model = "telemetry-error"
    attach(model)

    TestHTTP.put_response(
      {:ok,
       %{
         status: 429,
         headers: [{"retry-after", "3"}],
         body: ~s({"error":{"message":"slow down"}})
       }}
    )

    client = UsageProvider.client(api_key: "k", base_url: TestHTTP.url())
    assert {:error, %Error{kind: :provider}} = LlmCall.complete(client, request(model))

    assert [
             {[:llm_call, :request, :start], _start_measurements, _start_metadata},
             {[:llm_call, :request, :stop], measurements, metadata}
           ] = emitted()

    refute Map.has_key?(measurements, :input_tokens)

    assert %{
             outcome: :error,
             error_kind: :provider,
             status: 429,
             retryable: true,
             retry_after_ms: 3000
           } = metadata
  end

  # Metadata reaches a third-party tracing backend, where every attribute is stored and
  # indexed; an `Inspect` exception stays in a log. One key in the wrong place is a
  # credential in someone's dashboard.
  test "metadata carries no credential, no header and no body" do
    model = "telemetry-secret"
    attach(model)
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: ~s({"usage":{"in":1}})}})

    client = UsageProvider.client(api_key: "sk-must-not-appear", base_url: TestHTTP.url())
    assert {:ok, _response} = LlmCall.complete(client, request(model))

    emitted_metadata = emitted() |> Enum.map(&elem(&1, 2))
    assert [_start, _stop] = emitted_metadata

    for metadata <- emitted_metadata do
      refute Enum.any?(Map.keys(metadata), &(&1 in [:headers, :query, :credentials, :body, :raw]))
      refute inspect(metadata) =~ "sk-must-not-appear"
    end
  end

  test "a raise is an :exception, and it still reaches the caller" do
    model = "telemetry-raise"
    attach(model)

    client = RaisingProvider.client(api_key: "k", base_url: TestHTTP.url())
    TestHTTP.put_response({:ok, %{status: 200, headers: [], body: "{}"}})

    assert_raise RuntimeError, "decode failed", fn -> LlmCall.complete(client, request(model)) end

    assert [
             {[:llm_call, :request, :start], _measurements, _metadata},
             {[:llm_call, :request, :exception], exception_measurements, metadata}
           ] = emitted()

    assert is_integer(exception_measurements.duration)
    assert %{kind: :error, reason: %RuntimeError{message: "decode failed"}} = metadata
    assert is_list(metadata.stacktrace)
  end

  test "a stream emits :start, one :first_event, then :stop when it finishes" do
    model = "telemetry-stream"
    attach(model)

    TestHTTP.put_events([
      {:status, 200},
      {:data, sse(~s({"delta":"a"}))},
      {:data, sse(~s({"delta":"b"}))},
      {:data, sse("[DONE]")}
    ])

    client = LlmCall.TestProvider.client(api_key: "k", base_url: TestHTTP.url())
    assert {:ok, stream} = LlmCall.stream(client, request(model))

    # `[DONE]` is the second delta's stop: two deltas plus the codec's finishing event.
    assert [_, _, _] = Enum.to_list(stream)

    assert [
             {[:llm_call, :stream, :start], start_measurements, start_metadata},
             {[:llm_call, :stream, :first_event], first_measurements, _first_metadata},
             {[:llm_call, :stream, :first_text], text_measurements, _text_metadata},
             {[:llm_call, :stream, :stop], stop_measurements, stop_metadata}
           ] = emitted()

    assert is_integer(start_measurements.system_time)
    assert %{operation: :stream, provider: LlmCall.TestProvider, model: ^model} = start_metadata
    assert is_integer(first_measurements.duration) and first_measurements.duration >= 0
    assert text_measurements.duration >= first_measurements.duration
    assert is_integer(stop_measurements.duration) and stop_measurements.duration >= 0
    assert %{outcome: :done, status: 200, events: 3} = stop_metadata
  end

  # The gap between the two is the provider's skeleton frames: a slow first text on a
  # fast first event is the provider, not the network.
  test "a stream separates the first event from the first text" do
    model = "telemetry-first-text"
    attach(model)

    TestHTTP.put_events([
      {:status, 200},
      {:data, sse(~s({"start":true}))},
      {:data, sse(~s({"text":"hi"}))},
      {:data, sse("[DONE]")}
    ])

    client = SkeletonProvider.client(api_key: "k", base_url: TestHTTP.url())
    assert {:ok, stream} = LlmCall.stream(client, request(model))
    assert [_, _] = Enum.to_list(stream)

    assert [
             {[:llm_call, :stream, :start], _start_measurements, _start_metadata},
             {[:llm_call, :stream, :first_event], first_measurements, _first_metadata},
             {[:llm_call, :stream, :first_text], text_measurements, _text_metadata},
             {[:llm_call, :stream, :stop], _stop_measurements, stop_metadata}
           ] = emitted()

    assert text_measurements.duration >= first_measurements.duration
    assert %{outcome: :done, events: 2} = stop_metadata
  end

  test "a stream with no text delta emits no :first_text" do
    model = "telemetry-no-text"
    attach(model)

    TestHTTP.put_events([
      {:status, 200},
      {:data, sse(~s({"start":true}))},
      {:data, sse("[DONE]")}
    ])

    client = SkeletonProvider.client(api_key: "k", base_url: TestHTTP.url())
    assert {:ok, stream} = LlmCall.stream(client, request(model))
    assert [_] = Enum.to_list(stream)

    names = emitted() |> Enum.map(&elem(&1, 0))
    assert [:llm_call, :stream, :first_event] in names
    refute [:llm_call, :stream, :first_text] in names
  end

  test "a reducer that halts stops the stream with outcome :halted" do
    model = "telemetry-halt"
    attach(model)

    TestHTTP.put_events([
      {:status, 200},
      {:data, sse(~s({"delta":"a"}))},
      {:data, sse(~s({"delta":"b"}))}
    ])

    client = LlmCall.TestProvider.client(api_key: "k", base_url: TestHTTP.url())
    assert {:ok, stream} = LlmCall.stream(client, request(model))

    assert [_first] = Enum.take(stream, 1)

    assert [
             {[:llm_call, :stream, :start], _start_measurements, _start_metadata},
             {[:llm_call, :stream, :first_event], _first_measurements, _first_metadata},
             {[:llm_call, :stream, :first_text], _text_measurements, _text_metadata},
             {[:llm_call, :stream, :stop], _stop_measurements, stop_metadata}
           ] = emitted()

    assert %{outcome: :halted, events: 1} = stop_metadata
  end

  # A stream is a description: building one issues no request, so nothing is emitted.
  test "a stream that is never reduced emits nothing" do
    model = "telemetry-unreduced"
    attach(model)

    client = LlmCall.TestProvider.client(api_key: "k", base_url: TestHTTP.url())
    assert {:ok, _stream} = LlmCall.stream(client, request(model))

    assert emitted() == []
  end

  test "a stream that raises emits :exception and no :stop" do
    model = "telemetry-stream-raise"
    attach(model)

    TestHTTP.put_events([{:status, 200}, {:data, sse("{not json")}])
    client = LlmCall.TestProvider.client(api_key: "k", base_url: TestHTTP.url())
    assert {:ok, stream} = LlmCall.stream(client, request(model))

    assert_raise LlmCall.HTTP.Error, fn -> Enum.to_list(stream) end

    assert [
             {[:llm_call, :stream, :start], _start_measurements, _start_metadata},
             {[:llm_call, :stream, :exception], _measurements, metadata}
           ] = emitted()

    assert %{kind: :error, reason: %LlmCall.HTTP.Error{}} = metadata
  end
end

defmodule LlmCall.Codec.Conformance do
  @moduledoc """
  Fixture-based assertions for codec authors.

  These are test support, not a runtime dependency: a third-party codec can call
  them from its own suite to check the parts of the behaviour that are easy to
  get subtly wrong. Every function returns `:ok` or raises an
  `ExUnit.AssertionError` naming the failed expectation.

      test "my codec conforms" do
        Conformance.assert_info(MyCodec)
        Conformance.assert_path(MyCodec, request, "/v1/my-endpoint")
      end
  """

  import ExUnit.Assertions

  alias LlmCall.{Capabilities, Codec, Config, EncodedRequest, StreamEvent, StreamState}
  alias LlmCall.StreamDelta

  @credential_headers ["authorization", "x-api-key", "api-key"]

  @spec assert_info(module()) :: :ok
  def assert_info(codec) do
    info = codec.info()

    assert %Codec.Info{name: name, protocol: protocol, version: version, ir_version: 1} = info,
           "#{inspect(codec)}.info/0 must return %LlmCall.Codec.Info{} with ir_version 1"

    assert is_atom(name), "#{inspect(codec)}.info/0 name must be an atom"
    assert is_atom(protocol), "#{inspect(codec)}.info/0 protocol must be an atom"

    assert is_nil(version) or is_binary(version),
           "#{inspect(codec)}.info/0 version must be a string or nil"

    :ok
  end

  @spec assert_capabilities(module(), LlmCall.Request.t(), Config.t()) :: :ok
  def assert_capabilities(codec, request, config) do
    assert Code.ensure_loaded?(codec), "#{inspect(codec)} is not loaded"
    capabilities = codec.capabilities(request, config)

    assert %Capabilities{streaming: streaming} = capabilities,
           "#{inspect(codec)}.capabilities/2 must return %LlmCall.Capabilities{}"

    streaming_callbacks = [:init_stream, :decode_stream_event, :finish_stream]

    if streaming do
      for {function, arity} <- Enum.zip(streaming_callbacks, [2, 3, 2]) do
        assert function_exported?(codec, function, arity),
               "#{inspect(codec)} declares streaming: true but does not export #{function}/#{arity}"
      end
    else
      for {function, arity} <- Enum.zip(streaming_callbacks, [2, 3, 2]) do
        refute function_exported?(codec, function, arity),
               "#{inspect(codec)} declares streaming: false but exports #{function}/#{arity}"
      end
    end

    :ok
  end

  @spec assert_path(module(), LlmCall.Request.t(), String.t()) :: :ok
  def assert_path(codec, request, expected_path) do
    result = codec.encode_request(request, %Config{})

    assert match?({:ok, %EncodedRequest{}}, result),
           "#{inspect(codec)}.encode_request/2 must return {:ok, %LlmCall.EncodedRequest{}}, got: #{inspect(result)}"

    {:ok, %EncodedRequest{} = encoded} = result

    assert encoded.method == :post
    assert encoded.path == expected_path
    assert is_map(encoded.body)
    assert is_map(encoded.query)
    assert is_list(encoded.headers)

    names = Enum.map(encoded.headers, fn {name, _value} -> String.downcase(name) end)

    for forbidden <- @credential_headers do
      refute forbidden in names,
             "#{inspect(codec)} encoded request contains a credential header #{inspect(forbidden)}"
    end

    :ok
  end

  @spec assert_capture_raw(module(), LlmCall.wire_value()) :: :ok
  def assert_capture_raw(codec, provider_payload) do
    for {capture, expected} <- [none: nil, response: provider_payload, all: provider_payload] do
      case codec.decode_response(provider_payload, %Config{capture_raw: capture}) do
        {:ok, %{raw: raw}} ->
          assert raw == expected,
                 "#{inspect(codec)} raw must be #{inspect(expected)} with capture_raw: #{inspect(capture)}, " <>
                   "got: #{inspect(raw)}"

        other ->
          flunk(
            "#{inspect(codec)}.decode_response/2 must succeed with capture_raw: #{inspect(capture)}, " <>
              "got: #{inspect(other)}"
          )
      end
    end

    :ok
  end

  @spec assert_stream_roundtrip(module(), LlmCall.Request.t()) :: :ok
  def assert_stream_roundtrip(codec, request) do
    assert {:ok, %StreamState{} = state} = codec.init_stream(request, %Config{}),
           "#{inspect(codec)}.init_stream/2 must return {:ok, %LlmCall.StreamState{}}"

    assert StreamState.codec(state) == codec

    assert {:ok, events, %StreamState{} = closed} = codec.finish_stream(state, %Config{})

    assert is_list(events), "#{inspect(codec)}.finish_stream/2 must return a list of events"
    Enum.each(events, &assert_event/1)

    assert {:ok, [], _state} = codec.finish_stream(closed, %Config{}),
           "#{inspect(codec)}.finish_stream/2 must be idempotent"

    :ok
  end

  @spec assert_stream_state_ownership(module(), module(), LlmCall.Request.t()) :: :ok
  def assert_stream_state_ownership(codec, other_codec, request) do
    assert {:ok, state} = codec.init_stream(request, %Config{})

    assert {:error, %LlmCall.Error{kind: :validation}} =
             LlmCall.decode_stream_event(other_codec, %{}, %Config{}, state),
           "a #{inspect(codec)} stream state passed to #{inspect(other_codec)} must be a validation error"

    assert {:error, %LlmCall.Error{kind: :validation}} =
             LlmCall.finish_stream(other_codec, state, %Config{}),
           "a #{inspect(codec)} stream state passed to #{inspect(other_codec)} must be a validation error"

    :ok
  end

  defp assert_event(%StreamEvent{type: type, delta: delta}) do
    assert is_atom(type), "stream event type must be an atom"

    assert is_nil(delta) or is_struct(delta, StreamDelta.Text) or
             is_struct(delta, StreamDelta.ToolCall) or is_struct(delta, StreamDelta.Thinking) or
             is_struct(delta, StreamDelta.MessageDelta) or is_struct(delta, StreamDelta.Raw),
           "stream event delta must be nil or one of the canonical StreamDelta structs, got: #{inspect(delta)}"
  end
end

defmodule LlmDialect.Codec.Conformance do
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

  The assertions take the caller's fixtures, so an out-of-tree codec supplies its
  own payloads: nothing here assumes a specific provider.
  """

  import ExUnit.Assertions

  alias LlmDialect.{
    Capabilities,
    Config,
    Content,
    EncodedRequest,
    Error,
    Message,
    Reasoning,
    ReasoningCapabilities,
    StreamAssembler,
    StreamState,
    ToolCall,
    ToolSpec
  }

  alias LlmDialect.Conformance, as: Shared

  @reasoning_levels [:none, :minimal, :low, :medium, :high, :xhigh, :max]

  @doc "Asserts well-formed `info/0` metadata (see `LlmDialect.Conformance`)."
  @spec assert_info(module()) :: :ok
  def assert_info(codec), do: Shared.assert_info(codec)

  @spec assert_capabilities(module(), LlmDialect.Request.t(), Config.t()) :: :ok
  def assert_capabilities(codec, request, config) do
    assert Code.ensure_loaded?(codec), "#{inspect(codec)} is not loaded"
    capabilities = codec.capabilities(request, config)

    assert %Capabilities{streaming: streaming} = capabilities,
           "#{inspect(codec)}.capabilities/2 must return %LlmDialect.Capabilities{}"

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

  @spec assert_path(module(), LlmDialect.Request.t(), String.t()) :: :ok
  def assert_path(codec, request, expected_path) do
    result = codec.encode_request(request, %Config{})

    assert match?({:ok, %EncodedRequest{}}, result),
           "#{inspect(codec)}.encode_request/2 must return {:ok, %LlmDialect.EncodedRequest{}}, got: #{inspect(result)}"

    {:ok, %EncodedRequest{} = encoded} = result

    assert encoded.method == :post
    assert encoded.path == expected_path
    assert is_map(encoded.body)
    assert is_map(encoded.query)
    assert is_list(encoded.headers)

    names = Enum.map(encoded.headers, fn {name, _value} -> String.downcase(name) end)

    for forbidden <- Shared.credential_headers() do
      refute forbidden in names,
             "#{inspect(codec)} encoded request contains a credential header #{inspect(forbidden)}"
    end

    :ok
  end

  @spec assert_capture_raw(module(), LlmDialect.wire_value()) :: :ok
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

  @doc """
  Asserts that a successful payload decodes to a canonical response.

  Checks the IR boundary: canonical parts, a stop reason from the closed union,
  canonical usage, and `raw` as a map or `nil`. Provider-specific shapes leaking
  through `content` fail here.
  """
  @spec assert_decode_response(module(), LlmDialect.wire_value()) :: :ok
  def assert_decode_response(codec, provider_payload) do
    label = inspect(codec)

    case codec.decode_response(provider_payload, %Config{}) do
      {:ok, response} -> Shared.assert_response(response, label)
      other -> flunk("#{label}.decode_response/2 must succeed, got: #{inspect(other)}")
    end
  end

  @doc """
  Asserts that a malformed payload is a typed error, never a raise and never a
  fabricated response.

  Call it with a payload the codec cannot decode — `%{}` for most protocols.
  """
  @spec assert_invalid_response(module(), LlmDialect.wire_value()) :: :ok
  def assert_invalid_response(codec, provider_payload) do
    label = inspect(codec)
    result = decode_without_raising(codec, provider_payload)

    case result do
      {:error, %Error{kind: :invalid_response} = error} ->
        Shared.assert_error(error, label)

      {:error, %Error{} = error} ->
        flunk(
          "#{label}.decode_response/2 must report a payload it cannot decode as " <>
            "kind: :invalid_response, got: #{inspect(error)}"
        )

      other ->
        flunk(
          "#{label}.decode_response/2 must return {:error, %LlmDialect.Error{}} for a " <>
            "malformed payload, got: #{inspect(other)}"
        )
    end
  end

  @doc """
  Asserts that a provider error envelope decodes to a canonical `%Error{}`.

  The payload must be the codec's own error shape, so the assertion can check the
  normalized `code` and `retryable?` rather than a hard-coded message.
  """
  @spec assert_decode_error(module(), LlmDialect.wire_value()) :: :ok
  def assert_decode_error(codec, provider_payload) do
    label = inspect(codec)

    case codec.decode_error(provider_payload, %Config{}) do
      %Error{kind: :provider} = error ->
        Shared.assert_error(error, label)

      %Error{} = error ->
        flunk("#{label}.decode_error/2 must report kind: :provider, got: #{inspect(error)}")

      other ->
        flunk("#{label}.decode_error/2 must return a %LlmDialect.Error{}, got: #{inspect(other)}")
    end
  end

  @doc """
  Asserts that a codec rejects a request it cannot represent in full.

  The core promise is that an unrepresentable canonical field is a validation
  error, never a silent drop. This is the assertion a package uses to prove it,
  and the one that pins a protocol's unsupported fields as a test rather than a
  convention.
  """
  @spec assert_rejects(module(), LlmDialect.Request.t(), Config.t()) :: :ok
  def assert_rejects(codec, request, config) do
    result = codec.encode_request(request, config)

    assert match?({:error, %LlmDialect.Error{kind: :validation}}, result),
           "#{inspect(codec)} must reject a request with a field it cannot express, " <>
             "got: #{inspect(result)}"

    :ok
  end

  @spec assert_stream_roundtrip(module(), LlmDialect.Request.t()) :: :ok
  def assert_stream_roundtrip(codec, request) do
    assert {:ok, %StreamState{} = state} = codec.init_stream(request, %Config{}),
           "#{inspect(codec)}.init_stream/2 must return {:ok, %LlmDialect.StreamState{}}"

    assert StreamState.codec(state) == codec

    assert {:ok, events, %StreamState{} = closed} = codec.finish_stream(state, %Config{})

    assert is_list(events), "#{inspect(codec)}.finish_stream/2 must return a list of events"
    Enum.each(events, &Shared.assert_stream_event(&1, inspect(codec)))

    assert {:ok, [], _state} = codec.finish_stream(closed, %Config{}),
           "#{inspect(codec)}.finish_stream/2 must be idempotent"

    :ok
  end

  @doc """
  Asserts that a stream state is bound to the codec that created it.

  Passing one codec's state to another must be a validation error, so a caller
  cannot mix two protocols' stream state by accident.
  """
  @spec assert_stream_state_ownership(module(), module(), LlmDialect.Request.t()) :: :ok
  def assert_stream_state_ownership(codec, other_codec, request) do
    assert {:ok, state} = codec.init_stream(request, %Config{})

    assert {:error, %LlmDialect.Error{kind: :validation}} =
             LlmDialect.decode_stream_event(other_codec, %{}, %Config{}, state),
           "a #{inspect(codec)} stream state passed to #{inspect(other_codec)} must be a validation error"

    assert {:error, %LlmDialect.Error{kind: :validation}} =
             LlmDialect.finish_stream(other_codec, state, %Config{}),
           "a #{inspect(codec)} stream state passed to #{inspect(other_codec)} must be a validation error"

    :ok
  end

  @doc """
  Drives a codec's stream over the caller's chunks and asserts event shape and
  order.

  Order rules: `:message_start` at most once and before any delta;
  `:message_stop`/`:error` at most once and terminal. A `{:done, state}` result
  stops the stream, and `finish_stream/2` afterwards must not resurrect content.
  """
  @spec assert_stream(module(), LlmDialect.Request.t(), [LlmDialect.wire_value()]) :: :ok
  def assert_stream(codec, request, chunks) do
    label = inspect(codec)
    {events, done?} = collect_stream(codec, request, chunks, label)

    assert events != [] or not done?,
           "#{label} returned {:done, state} without emitting any event"

    Enum.each(events, &Shared.assert_stream_event(&1, label))
    assert_event_order(events, label)

    :ok
  end

  @doc """
  Asserts that a streamed tool-call sequence assembles into complete calls.

  Runs the events through `LlmDialect.StreamAssembler`, so a codec fails here if
  it fragments arguments in a way the assembler cannot key by index, or invents
  arguments the provider never sent.

  `expected_calls` pins the count; pass `json_decoder:` to supply a decoder other
  than `:json` (the assembler never decodes JSON itself).
  """
  @spec assert_tool_call_assembly(
          module(),
          LlmDialect.Request.t(),
          [LlmDialect.wire_value()],
          pos_integer(),
          keyword()
        ) :: :ok
  def assert_tool_call_assembly(codec, request, chunks, expected_calls, opts \\ []) do
    label = inspect(codec)
    decoder = Keyword.get_lazy(opts, :json_decoder, fn -> &default_decoder/1 end)
    {events, _done?} = collect_stream(codec, request, chunks, label)

    assembler = StreamAssembler.new(json_decoder: decoder)

    {assembler, calls} =
      Enum.reduce(events, {assembler, []}, fn event, {assembler, calls} ->
        {:ok, assembler, completed} = StreamAssembler.feed(assembler, event)
        {assembler, calls ++ completed}
      end)

    {:ok, _assembler, final} = StreamAssembler.finish(assembler)

    calls = calls ++ final

    assert length(calls) == expected_calls,
           "#{label} must assemble #{expected_calls} tool call(s), got: #{inspect(calls)}"

    for call <- calls, do: assert_assembled_call(call, label)

    :ok
  end

  @doc """
  Asserts that `capabilities/2` and `validate_request/2` agree, in both
  directions.

  A declared capability must accept a minimal representative: `tools`,
  `tool_choice`, `structured_output`, `modalities`, `image_input`, `file_input`,
  and each `reasoning` axis. An undeclared one must be a validation error. The
  base request must otherwise be valid for the codec.
  """
  @spec assert_capability_consistency(module(), LlmDialect.Request.t(), Config.t()) :: :ok
  def assert_capability_consistency(codec, request, config) do
    assert Code.ensure_loaded?(codec), "#{inspect(codec)} is not loaded"

    assert %Capabilities{} = capabilities = codec.capabilities(request, config)

    check_tools(codec, request, config, capabilities)
    check_tool_choice(codec, request, config, capabilities)
    check_output(codec, request, config, capabilities.structured_output)
    check_modalities(codec, request, config, capabilities.modalities)

    check_part_support(
      codec,
      request,
      config,
      capabilities.image_input,
      %Content.Image{source: {:url, "https://example.com/i.png"}},
      "image_input"
    )

    check_part_support(
      codec,
      request,
      config,
      capabilities.file_input,
      %Content.File{source: {:url, "https://example.com/d.pdf"}},
      "file_input"
    )

    check_reasoning(codec, request, config, capabilities.reasoning)

    :ok
  end

  defp check_tools(codec, request, config, %Capabilities{tools: true}) do
    assert :ok == codec.validate_request(with_field(request, :tools, [minimal_tool()]), config),
           "#{inspect(codec)} declares tools: true but rejects a minimal function tool"

    :ok
  end

  defp check_tools(codec, request, config, %Capabilities{tools: false}) do
    expect_rejection(
      codec,
      with_field(request, :tools, [minimal_tool()]),
      config,
      "declares tools: false but accepts a function tool"
    )
  end

  defp check_tool_choice(codec, request, config, %Capabilities{tool_choice: true}) do
    request =
      request |> with_field(:tools, [minimal_tool()]) |> with_field(:tool_choice, :required)

    assert :ok == codec.validate_request(request, config),
           "#{inspect(codec)} declares tool_choice: true but rejects tool_choice: :required"

    :ok
  end

  defp check_tool_choice(codec, request, config, %Capabilities{tool_choice: false}) do
    request =
      request |> with_field(:tools, [minimal_tool()]) |> with_field(:tool_choice, :required)

    expect_rejection(codec, request, config, "declares tool_choice: false but accepts :required")
  end

  defp check_output(codec, request, config, :none) do
    expect_rejection(
      codec,
      with_field(request, :output, :json_object),
      config,
      "declares structured_output: :none but accepts output: :json_object"
    )

    expect_rejection(
      codec,
      with_field(request, :output, json_schema()),
      config,
      "declares structured_output: :none but accepts a json_schema output"
    )
  end

  defp check_output(codec, request, config, :json_object) do
    assert :ok == codec.validate_request(with_field(request, :output, :json_object), config),
           "#{inspect(codec)} declares structured_output: :json_object but rejects it"

    expect_rejection(
      codec,
      with_field(request, :output, json_schema()),
      config,
      "declares structured_output: :json_object but accepts a json_schema output"
    )
  end

  defp check_output(codec, request, config, :json_schema) do
    for output <- [:json_object, json_schema()] do
      assert :ok == codec.validate_request(with_field(request, :output, output), config),
             "#{inspect(codec)} declares structured_output: :json_schema but rejects #{inspect(output)}"
    end

    :ok
  end

  defp check_modalities(codec, request, config, declared) do
    for modality <- declared do
      request = request |> with_field(:modalities, [modality]) |> with_field(:stream, false)

      assert :ok == codec.validate_request(request, config),
             "#{inspect(codec)} declares modality #{inspect(modality)} but rejects it"
    end

    for modality <- [:text, :image, :video] -- declared do
      request = request |> with_field(:modalities, [modality]) |> with_field(:stream, false)

      expect_rejection(
        codec,
        request,
        config,
        "does not declare modality #{inspect(modality)} but accepts it"
      )
    end

    :ok
  end

  defp check_part_support(codec, request, config, true, part, label) do
    assert :ok == codec.validate_request(with_part(request, part), config),
           "#{inspect(codec)} declares #{label}: true but rejects #{inspect(part)}"

    :ok
  end

  defp check_part_support(codec, request, config, false, part, label) do
    expect_rejection(
      codec,
      with_part(request, part),
      config,
      "declares #{label}: false but accepts #{inspect(part)}"
    )
  end

  defp check_reasoning(codec, request, config, nil) do
    expect_rejection(
      codec,
      with_field(request, :reasoning, %Reasoning{effort: :high}),
      config,
      "declares no reasoning support but accepts a reasoning hint"
    )
  end

  defp check_reasoning(codec, request, config, %ReasoningCapabilities{supported: false}) do
    expect_rejection(
      codec,
      with_field(request, :reasoning, %Reasoning{effort: :high}),
      config,
      "declares reasoning.supported: false but accepts a reasoning hint"
    )
  end

  defp check_reasoning(codec, request, config, %ReasoningCapabilities{} = capabilities) do
    for effort <- capabilities.efforts do
      assert :ok ==
               codec.validate_request(
                 with_field(request, :reasoning, %Reasoning{effort: effort}),
                 config
               ),
             "#{inspect(codec)} declares reasoning effort #{inspect(effort)} but rejects it"
    end

    case Enum.find(@reasoning_levels, &(&1 not in capabilities.efforts)) do
      nil ->
        :ok

      undeclared ->
        expect_rejection(
          codec,
          with_field(request, :reasoning, %Reasoning{effort: undeclared}),
          config,
          "does not declare reasoning effort #{inspect(undeclared)} but accepts it"
        )
    end

    check_reasoning_flag(
      codec,
      request,
      config,
      capabilities.budget_tokens,
      %Reasoning{budget_tokens: 1024},
      "reasoning.budget_tokens"
    )

    check_reasoning_summary(codec, request, config, capabilities.summary)
  end

  defp check_reasoning_flag(codec, request, config, true, reasoning, label) do
    assert :ok == codec.validate_request(with_field(request, :reasoning, reasoning), config),
           "#{inspect(codec)} declares #{label}: true but rejects #{inspect(reasoning)}"

    :ok
  end

  defp check_reasoning_flag(codec, request, config, false, reasoning, label) do
    expect_rejection(
      codec,
      with_field(request, :reasoning, reasoning),
      config,
      "declares #{label}: false but accepts #{inspect(reasoning)}"
    )
  end

  defp check_reasoning_summary(codec, request, config, []),
    do:
      check_reasoning_flag(
        codec,
        request,
        config,
        false,
        %Reasoning{summary: :auto},
        "reasoning.summary"
      )

  defp check_reasoning_summary(codec, request, config, [summary | _rest]) do
    assert :ok ==
             codec.validate_request(
               with_field(request, :reasoning, %Reasoning{summary: summary}),
               config
             ),
           "#{inspect(codec)} declares reasoning summary #{inspect(summary)} but rejects it"

    :ok
  end

  defp assert_assembled_call(%ToolCall{} = call, label) do
    assert is_nil(call.name) or (is_binary(call.name) and call.name != ""),
           "#{label} assembled a tool call with an invalid name: #{inspect(call.name)}"

    assert is_nil(call.arguments) or is_map(call.arguments),
           "#{label} assembled tool call arguments must be a map or nil, " <>
             "got: #{inspect(call.arguments)}"

    assert is_nil(call.raw_arguments) or is_binary(call.raw_arguments),
           "#{label} assembled tool call raw_arguments must be a string or nil, " <>
             "got: #{inspect(call.raw_arguments)}"

    if is_nil(call.arguments_error) and is_binary(call.raw_arguments) do
      assert is_map(call.arguments),
             "#{label} assembled a tool call with raw_arguments but no decoded arguments"
    end

    :ok
  end

  defp assert_assembled_call(other, label) do
    flunk(
      "#{label} StreamAssembler must produce %LlmDialect.ToolCall{} structs, got: #{inspect(other)}"
    )
  end

  defp collect_stream(codec, request, chunks, label) do
    assert {:ok, %StreamState{} = state} = codec.init_stream(request, %Config{}),
           "#{label}.init_stream/2 must return {:ok, %LlmDialect.StreamState{}}"

    {events, state, done?} =
      chunks
      |> Enum.with_index()
      |> Enum.reduce({[], state, false}, fn {chunk, position}, {events, state, done?} ->
        case codec.decode_stream_event(chunk, %Config{}, state) do
          {:ok, new_events, %StreamState{} = next} when is_list(new_events) ->
            {events ++ new_events, next, done?}

          {:done, %StreamState{} = next} ->
            {events, next, true}

          other ->
            flunk(
              "#{label}.decode_stream_event/3 must return {:ok, events, state} or " <>
                "{:done, state} for chunk #{position}, got: #{inspect(other)}"
            )
        end
      end)

    assert {:ok, tail, %StreamState{}} = codec.finish_stream(state, %Config{}),
           "#{label}.finish_stream/2 must return {:ok, events, state}"

    {events ++ tail, done?}
  end

  defp assert_event_order(events, label) do
    types = Enum.map(events, & &1.type)

    assert Enum.count(types, &(&1 == :message_start)) <= 1,
           "#{label} emitted :message_start more than once: #{inspect(types)}"

    if :message_start in types do
      first_delta = Enum.find_index(types, &(&1 != :message_start))
      start = Enum.find_index(types, &(&1 == :message_start))

      assert is_nil(first_delta) or start < first_delta,
             "#{label} emitted :message_start after other events: #{inspect(types)}"
    end

    for terminal <- [:message_stop, :error] do
      assert Enum.count(types, &(&1 == terminal)) <= 1,
             "#{label} emitted #{inspect(terminal)} more than once: #{inspect(types)}"

      if terminal in types do
        assert List.last(types) == terminal or terminal == :error,
               "#{label} emitted #{inspect(terminal)} before the end of the stream: #{inspect(types)}"
      end
    end

    :ok
  end

  defp decode_without_raising(codec, payload) do
    codec.decode_response(payload, %Config{})
  rescue
    error ->
      flunk(
        "#{inspect(codec)}.decode_response/2 raised #{inspect(error.__struct__)} for a " <>
          "malformed payload; it must return {:error, %LlmDialect.Error{}}"
      )
  end

  defp default_decoder(raw) do
    case :json.decode(raw) do
      %{} = decoded -> {:ok, decoded}
      _not_an_object -> {:error, raw}
    end
  rescue
    _decode_error -> {:error, raw}
  end

  defp expect_rejection(codec, request, config, message) do
    result = codec.validate_request(request, config)

    assert match?({:error, %Error{kind: :validation}}, result),
           "#{inspect(codec)} #{message}, got: #{inspect(result)}"

    :ok
  end

  defp minimal_tool, do: %ToolSpec{name: "f", parameters: %{"type" => "object"}}

  defp json_schema, do: {:json_schema, "result", %{"type" => "object"}, nil}

  defp with_field(request, field, value), do: Map.put(request, field, value)

  defp with_part(request, part) do
    message = %Message{role: :user, content: [part]}
    with_field(request, :messages, request.messages ++ [message])
  end
end

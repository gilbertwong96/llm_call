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

  The assertions take the caller's fixtures, so an out-of-tree codec supplies its
  own payloads: nothing here assumes a specific provider.
  """

  import ExUnit.Assertions

  alias LlmCall.{
    Capabilities,
    Config,
    Content,
    EncodedRequest,
    Error,
    Message,
    Reasoning,
    StreamAssembler,
    StreamState,
    ToolCall,
    ToolSpec
  }

  alias LlmCall.Capabilities.Input
  alias LlmCall.Conformance, as: Shared
  alias LlmCall.Reasoning.Capabilities, as: ReasoningCapabilities

  # One representative per source kind. A base64 part needs its media_type, and
  # Converse needs a document name, so the samples carry both.
  @input_samples %{
    image: %{
      inline: %Content.Image{source: {:base64, "AA=="}, media_type: "image/png"},
      url: %Content.Image{source: {:url, "https://example.com/i.png"}},
      uri: %Content.Image{source: {:uri, "s3://bucket/i.png"}, media_type: "image/png"},
      file: %Content.Image{source: {:file_id, "file-abc"}}
    },
    file: %{
      inline: %Content.File{
        source: {:base64, "AA=="},
        media_type: "application/pdf",
        filename: "d.pdf"
      },
      url: %Content.File{source: {:url, "https://example.com/d.pdf"}},
      uri: %Content.File{
        source: {:uri, "s3://bucket/d.pdf"},
        media_type: "application/pdf",
        filename: "d.pdf"
      },
      file: %Content.File{source: {:file_id, "file-abc"}}
    }
  }

  @reasoning_levels [:none, :minimal, :low, :medium, :high, :xhigh, :max]
  @reasoning_summaries [:auto, :concise, :detailed]

  @doc "Asserts well-formed `info/0` metadata (see `LlmCall.Conformance`)."
  @spec assert_info(module()) :: :ok
  def assert_info(codec), do: Shared.assert_info(codec)

  @doc """
  Couples `capabilities.streaming` to the streaming callbacks.

  `streaming: true` requires all three callbacks; `streaming: false` requires
  none of them. Capabilities are per codec, not per request, so a protocol that
  streams only for some models cannot express that here — declare `true` and
  reject the other requests in `validate_request/2`.
  """
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

  @doc """
  Asserts the encoded request's method, path, body shape, and credential-free
  headers.

  `method` defaults to `:post`. A codec that uses `encode: false` for a
  per-request method passes the one it produces.
  """
  @spec assert_path(module(), LlmCall.Request.t(), String.t(), :post | :get) :: :ok
  def assert_path(codec, request, expected_path, method \\ :post) do
    result = codec.encode_request(request, %Config{})

    assert match?({:ok, %EncodedRequest{}}, result),
           "#{inspect(codec)}.encode_request/2 must return {:ok, %LlmCall.EncodedRequest{}}, got: #{inspect(result)}"

    {:ok, %EncodedRequest{} = encoded} = result

    assert encoded.method == method,
           "#{inspect(codec)} encoded method must be #{inspect(method)}, got: #{inspect(encoded.method)}"

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

  @doc """
  Asserts that a streaming request actually asks the provider to stream.

  This is the encoding-side counterpart to `assert_stream/3`. A codec can
  implement every streaming callback and still never request SSE, in which case
  the transport receives a buffered response and the decoders are dead code.

  Three things must hold:

    * `stream: true` and `stream: false` must encode to different requests, so the
      flag reaches the wire at all;
    * the streaming request must carry a streaming signal: `body["stream"] == true`,
      an SSE query value (`alt=sse`), a `stream` query flag, or a path that differs
      from the non-streaming one and names the streaming endpoint;
    * the non-streaming request must not carry that signal.

  A signal is a disjunction, so this cannot tell you that a protocol needs *all*
  of its signals (Gemini needs both `alt=sse` and the streaming path). Pass
  `require: [query: %{"alt" => "sse"}]` or `require: [body: %{...}]` to pin the
  ones your protocol cannot lose.

  Pass `marker:` (1-arity, receives the streaming request) when the protocol
  signals streaming some other way, and `config:` when the codec needs a
  non-default `LlmCall.Config` to encode. The base request must be streamable:
  forcing `stream: true` on a request the codec rejects (Gemini with an image
  modality, say) is reported as such, and a codec that declares
  `streaming: false` is named as the cause.
  """
  @spec assert_stream_request(module(), LlmCall.Request.t(), keyword()) :: :ok
  def assert_stream_request(codec, request, opts \\ []) do
    label = inspect(codec)
    marker = Keyword.get(opts, :marker)
    config = Keyword.get(opts, :config, %Config{})

    streaming = encode_for_stream(codec, %{request | stream: true}, config, label, true)
    plain = encode_for_stream(codec, %{request | stream: false}, config, label, false)

    assert streaming != plain,
           "#{label} encodes the same request with stream: true and stream: false, " <>
             "so the provider is never asked to stream"

    assert signal?(streaming, plain, marker),
           "#{label} does not signal streaming on the encoded request: no " <>
             "body[\"stream\"], no SSE query, no streaming path: #{inspect(streaming)}"

    refute signal?(plain, plain, marker),
           "#{label} signals streaming even with stream: false: #{inspect(plain)}"

    assert_required_signals(streaming, Keyword.get(opts, :require, []), label)
    assert_credential_free(streaming, label)

    :ok
  end

  @spec assert_reserved_options(module(), LlmCall.Request.t(), Config.t(), [map()]) :: :ok
  def assert_reserved_options(codec, request, config, reserved_options) do
    for options <- reserved_options do
      assert_rejects(codec, %{request | provider_options: options}, config)
    end

    :ok
  end

  @doc """
  Asserts which decoded content parts a codec accepts back in an assistant message.

  A response the caller can decode but not replay makes a tool loop impossible, so
  the accept/reject boundary is part of the contract rather than an implementation
  detail. Pass the rule per part and the assertion builds the assistant turn itself:

      Conformance.assert_replays(codec, request,
        text: :ok,
        tool_call: :ok,
        thinking: :rejected,
        thinking_without_signature: :rejected,
        raw: :rejected
      )

  `:ok` means `encode_request/2` succeeds with that part in an assistant message;
  `:rejected` means it is a `:validation` error that names the part — never a silent
  drop. A part the caller omits is not checked: a protocol that cannot express it at
  all has no rule to pin.

  The parts are `:text`, `:thinking`, `:thinking_without_signature`, `:tool_call`, and
  `:raw`. What each codec answers is the table in `docs/design.md` §8.3.
  """
  @spec assert_replays(module(), LlmCall.Request.t(), keyword()) :: :ok
  def assert_replays(codec, request, expectations) do
    label = inspect(codec)

    unless Keyword.keyword?(expectations) do
      flunk("#{label} replay expectations must be a keyword list, got: #{inspect(expectations)}")
    end

    for {part, expected} <- expectations do
      assert_replay(codec, request, part, expected, label)
    end

    :ok
  end

  defp assert_replay(codec, request, part, expected, label) do
    request = %{
      request
      | messages: [replay_user_message(), replay_assistant_message(part, label)]
    }

    result = codec.encode_request(request, %Config{})
    assert_replay_result(expected, result, part, label)
  end

  defp assert_replay_result(:ok, {:ok, %EncodedRequest{}}, _part, _label), do: :ok

  defp assert_replay_result(:ok, other, part, label) do
    flunk(
      "#{label} must accept #{inspect(part)} back in an assistant message, got: #{inspect(other)}"
    )
  end

  defp assert_replay_result(
         :rejected,
         {:error, %Error{kind: :validation, message: message}},
         _part,
         _label
       )
       when is_binary(message),
       do: :ok

  defp assert_replay_result(:rejected, other, part, label) do
    flunk(
      "#{label} must reject #{inspect(part)} in an assistant message with a " <>
        ":validation error, got: #{inspect(other)}"
    )
  end

  defp assert_replay_result(other, _result, part, label) do
    flunk(
      "#{label} replay expectation for #{inspect(part)} must be :ok or :rejected, " <>
        "got: #{inspect(other)}"
    )
  end

  defp replay_user_message do
    %Message{role: :user, content: [%Content.Text{text: "hi"}]}
  end

  defp replay_assistant_message(:text, _label) do
    %Message{role: :assistant, content: [%Content.Text{text: "answer"}]}
  end

  defp replay_assistant_message(:thinking, _label) do
    %Message{role: :assistant, content: [%Content.Thinking{text: "step", signature: "sig"}]}
  end

  defp replay_assistant_message(:thinking_without_signature, _label) do
    %Message{role: :assistant, content: [%Content.Thinking{text: "step"}]}
  end

  defp replay_assistant_message(:tool_call, _label) do
    %Message{
      role: :assistant,
      content: [%ToolCall{id: "call_1", name: "get_weather", arguments: %{"city" => "Oslo"}}]
    }
  end

  defp replay_assistant_message(:raw, _label) do
    %Message{
      role: :assistant,
      content: [%Content.Raw{type: "reasoning", data: %{"type" => "reasoning"}}]
    }
  end

  defp replay_assistant_message(other, label) do
    flunk(
      "#{label} has no replay fixture for #{inspect(other)}; " <>
        "expected one of :text, :thinking, :thinking_without_signature, :tool_call, :raw"
    )
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

  @doc """
  Asserts that a successful payload decodes to a canonical response.

  Checks the IR boundary: canonical parts, a stop reason from the closed union,
  canonical usage, and `raw` as a map or `nil`. Provider-specific shapes leaking
  through `content` fail here.
  """
  @spec assert_decode_response(module(), LlmCall.wire_value()) :: :ok
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
  @spec assert_invalid_response(module(), LlmCall.wire_value()) :: :ok
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
          "#{label}.decode_response/2 must return {:error, %LlmCall.Error{}} for a " <>
            "malformed payload, got: #{inspect(other)}"
        )
    end
  end

  @doc """
  Asserts that a provider error envelope decodes to a canonical `%Error{}`.

  Pass `code:` and `retryable?:` to pin the normalization: without them the
  assertion only sees that the result is a provider error, and a codec that
  ignores the payload entirely would pass.
  """
  @spec assert_decode_error(module(), LlmCall.wire_value(), keyword()) :: :ok
  def assert_decode_error(codec, provider_payload, opts \\ []) do
    label = inspect(codec)

    case codec.decode_error(provider_payload, %Config{}) do
      %Error{kind: :provider} = error ->
        Shared.assert_error(error, label)
        assert_error_field(error, :code, Keyword.get(opts, :code, :any), label)
        assert_error_field(error, :retryable?, Keyword.get(opts, :retryable?, :any), label)
        assert_error_capture_raw(codec, provider_payload, label)

        :ok

      %Error{} = error ->
        flunk("#{label}.decode_error/2 must report kind: :provider, got: #{inspect(error)}")

      other ->
        flunk("#{label}.decode_error/2 must return a %LlmCall.Error{}, got: #{inspect(other)}")
    end
  end

  # `capture_raw` covers every payload the codec keeps, the error envelope
  # included: `:none` promises no provider payload at all.
  defp assert_error_capture_raw(codec, provider_payload, label) do
    for {capture_raw, expected} <- [none: nil, response: provider_payload] do
      error = codec.decode_error(provider_payload, %Config{capture_raw: capture_raw})

      assert error.raw == expected,
             "#{label}.decode_error/2 raw must be #{inspect(expected)} with " <>
               "capture_raw: #{inspect(capture_raw)}, got: #{inspect(error.raw)}"
    end

    :ok
  end

  defp assert_error_field(_error, _field, :any, _label), do: :ok

  defp assert_error_field(error, field, expected, label) do
    actual = Map.fetch!(error, field)

    assert actual === expected,
           "#{label}.decode_error/2 must normalize #{field} to #{inspect(expected)}, " <>
             "got: #{inspect(actual)}"

    :ok
  end

  @doc """
  Asserts that a codec rejects a request it cannot represent in full.

  The core promise is that an unrepresentable canonical field is a validation
  error, never a silent drop. This is the assertion a package uses to prove it,
  and the one that pins a protocol's unsupported fields as a test rather than a
  convention.
  """
  @spec assert_rejects(module(), LlmCall.Request.t(), Config.t()) :: :ok
  def assert_rejects(codec, request, config) do
    result = codec.encode_request(request, config)

    assert match?({:error, %LlmCall.Error{kind: :validation}}, result),
           "#{inspect(codec)} must reject a request with a field it cannot express, " <>
             "got: #{inspect(result)}"

    :ok
  end

  @spec assert_stream_roundtrip(module(), LlmCall.Request.t()) :: :ok
  def assert_stream_roundtrip(codec, request) do
    assert {:ok, %StreamState{} = state} = codec.init_stream(request, %Config{}),
           "#{inspect(codec)}.init_stream/2 must return {:ok, %LlmCall.StreamState{}}"

    assert StreamState.codec(state) == codec

    # A codec whose protocol has no terminator flushes a tail here; one that has a
    # terminator rejects a stream that never carried it. Both are legal, and both must
    # be idempotent.
    case codec.finish_stream(state, %Config{}) do
      {:ok, events, %StreamState{} = closed} ->
        assert is_list(events), "#{inspect(codec)}.finish_stream/2 must return a list of events"
        Enum.each(events, &Shared.assert_stream_event(&1, inspect(codec)))

        assert {:ok, [], _state} = codec.finish_stream(closed, %Config{}),
               "#{inspect(codec)}.finish_stream/2 must be idempotent"

      {:error, %Error{} = error} ->
        Shared.assert_error(error, inspect(codec))

        assert {:error, %Error{}} = codec.finish_stream(state, %Config{}),
               "#{inspect(codec)}.finish_stream/2 must be idempotent"

      other ->
        flunk(
          "#{inspect(codec)}.finish_stream/2 must return {:ok, events, state} or " <>
            "{:error, %LlmCall.Error{}}, got: #{inspect(other)}"
        )
    end

    :ok
  end

  @doc """
  Asserts that a stream state is bound to the codec that created it.

  Passing one codec's state to another must be a validation error, so a caller
  cannot mix two protocols' stream state by accident.
  """
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

  @doc """
  Drives a codec's stream over the caller's chunks and asserts event shape and
  order.

  Order rules: `:message_start` at most once and before any delta;
  `:message_stop`/`:error` at most once and terminal. A `{:done, state}` result
  stops the stream, and `finish_stream/2` afterwards must not emit content.
  """
  @spec assert_stream(module(), LlmCall.Request.t(), [LlmCall.wire_value()]) :: :ok
  def assert_stream(codec, request, chunks) do
    label = inspect(codec)
    {events, tail, done?} = collect_stream(codec, request, chunks, label)

    Enum.each(events, &Shared.assert_stream_event(&1, label))
    assert_event_order(events, label)

    if done? do
      allowed = [:content_stop, :message_delta, :message_stop, :tool_call_stop]

      assert Enum.all?(tail, &(&1.type in allowed)),
             "#{label} may only flush metadata or close a block after {:done, state}, got: " <>
               inspect(Enum.map(tail, & &1.type))
    end

    :ok
  end

  @doc """
  Asserts that `StreamEvent.raw` follows the `capture_raw` policy.

  `:none` and `:response` keep no provider event; `:all` keeps at least one, and
  every retained payload is a map. A codec that copies provider chunks into every
  event regardless of the policy fails here.
  """
  @spec assert_stream_capture_raw(module(), LlmCall.Request.t(), [LlmCall.wire_value()]) ::
          :ok
  def assert_stream_capture_raw(codec, request, chunks) do
    label = inspect(codec)

    for {capture, expect_payloads?} <- [none: false, response: false, all: true] do
      config = %Config{capture_raw: capture}
      {events, _tail, _done?} = collect_stream(codec, request, chunks, label, config)

      raw = Enum.map(events, & &1.raw)

      assert Enum.all?(raw, &(is_nil(&1) or is_map(&1))),
             "#{label} StreamEvent.raw must be a map or nil with " <>
               "capture_raw: #{inspect(capture)}, got: #{inspect(raw)}"

      if expect_payloads? do
        assert Enum.any?(raw, &is_map/1),
               "#{label} capture_raw: :all must retain at least one provider event on " <>
                 "StreamEvent.raw"
      else
        assert Enum.all?(raw, &is_nil/1),
               "#{label} capture_raw: #{inspect(capture)} must not retain provider events, " <>
                 "got: #{inspect(Enum.reject(raw, &is_nil/1))}"
      end
    end

    :ok
  end

  @doc """
  Asserts that a streamed tool-call sequence assembles into complete calls.

  Runs the events through `LlmCall.StreamAssembler`, so a codec fails here if
  it fragments arguments in a way the assembler cannot key by index, or invents
  arguments the provider never sent.

  `expected_calls` pins the count; pass `json_decoder:` to supply a decoder other
  than `:json` (the assembler never decodes JSON itself), and `max_argument_bytes:`
  to pin the assembler's argument cap — a codec whose fragments exceed it produces
  `{:too_large, bytes}` rather than a decoded map.
  """
  @spec assert_tool_call_assembly(
          module(),
          LlmCall.Request.t(),
          [LlmCall.wire_value()],
          pos_integer(),
          keyword()
        ) :: :ok
  def assert_tool_call_assembly(codec, request, chunks, expected_calls, opts \\ []) do
    label = inspect(codec)
    decoder = Keyword.get_lazy(opts, :json_decoder, fn -> &default_decoder/1 end)
    {events, _tail, _done?} = collect_stream(codec, request, chunks, label)

    assembler =
      StreamAssembler.new([json_decoder: decoder] ++ Keyword.take(opts, [:max_argument_bytes]))

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
  `reasoning.supported`, every declared `efforts` level, `budget_tokens`, and
  `summary`. An undeclared one must be a validation error. The base request must
  otherwise be valid for the codec.

  `reasoning.adaptive`, `reasoning.default_effort`, `parallel_tool_calls`,
  `streaming_tool_calls`, `prompt_cache`, and `stateful` are declarations only:
  the canonical IR has no request field that expresses them, so there is nothing
  to check in either direction. `prompt_cache` and `stateful` are reporting
  capabilities — accounting in `Usage`, server-side continuation through
  `provider_options` — so no request can exercise them.

  The `budget_tokens` sample is derived from the request's `params.max_tokens`,
  because a protocol may couple the two (Anthropic requires
  `1024 <= budget_tokens < max_tokens`). A request whose `max_tokens` leaves no
  legal budget skips that one check rather than reporting a failure the codec is
  not responsible for: raise `max_tokens` above 1024 to exercise it.
  """
  @spec assert_capability_consistency(module(), LlmCall.Request.t(), Config.t()) :: :ok
  def assert_capability_consistency(codec, request, config) do
    assert Code.ensure_loaded?(codec), "#{inspect(codec)} is not loaded"

    assert %Capabilities{} = capabilities = codec.capabilities(request, config)

    check_tools(codec, request, config, capabilities)
    check_builtin_tools(codec, request, config, capabilities.builtin_tools)
    check_tool_choice(codec, request, config, capabilities)
    check_output(codec, request, config, capabilities.structured_output)
    check_modalities(codec, request, config, capabilities.modalities)

    check_input_sources(codec, request, config, capabilities.image_input, :image, "image_input")
    check_input_sources(codec, request, config, capabilities.file_input, :file, "file_input")

    check_reasoning(codec, request, config, capabilities.reasoning)

    :ok
  end

  defp check_tools(codec, request, config, %Capabilities{tools: true}) do
    assert :ok ==
             codec.validate_request(with_field(request, :tools, [minimal_tool(codec)]), config),
           "#{inspect(codec)} declares tools: true but rejects a minimal function tool"

    :ok
  end

  defp check_tools(codec, request, config, %Capabilities{tools: false}) do
    expect_rejection(
      codec,
      with_field(request, :tools, [minimal_tool(codec)]),
      config,
      "declares tools: false but accepts a function tool"
    )
  end

  defp check_tools(_codec, _request, _config, %Capabilities{tools: other}) do
    flunk("Capabilities.tools must be a boolean, got: #{inspect(other)}")
  end

  defp check_builtin_tools(codec, request, config, false) do
    expect_rejection(
      codec,
      with_field(request, :tools, [builtin_tool("web_search")]),
      config,
      "declares builtin_tools: false but accepts a hosted tool"
    )
  end

  defp check_builtin_tools(codec, request, config, :passthrough) do
    assert :ok ==
             codec.validate_request(
               with_field(request, :tools, [builtin_tool("any_vendor_tool_id")]),
               config
             ),
           "#{inspect(codec)} declares builtin_tools: :passthrough but rejects a hosted tool"

    :ok
  end

  defp check_builtin_tools(codec, request, config, declared) when is_list(declared) do
    for name <- declared do
      assert :ok ==
               codec.validate_request(with_field(request, :tools, [builtin_tool(name)]), config),
             "#{inspect(codec)} declares builtin tool #{inspect(name)} but rejects it"
    end

    undeclared = "not_in_#{inspect(declared)}"

    expect_rejection(
      codec,
      with_field(request, :tools, [builtin_tool(undeclared)]),
      config,
      "does not declare the builtin tool #{inspect(undeclared)} but accepts it"
    )
  end

  defp check_builtin_tools(_codec, _request, _config, other) do
    flunk(
      "Capabilities.builtin_tools must be false, :passthrough or a list, " <>
        "got: #{inspect(other)}"
    )
  end

  defp check_tool_choice(codec, request, config, %Capabilities{tool_choice: true}) do
    request =
      request |> with_field(:tools, [minimal_tool(codec)]) |> with_field(:tool_choice, :required)

    assert :ok == codec.validate_request(request, config),
           "#{inspect(codec)} declares tool_choice: true but rejects tool_choice: :required"

    :ok
  end

  defp check_tool_choice(codec, request, config, %Capabilities{tool_choice: false}) do
    request =
      request |> with_field(:tools, [minimal_tool(codec)]) |> with_field(:tool_choice, :required)

    expect_rejection(codec, request, config, "declares tool_choice: false but accepts :required")
  end

  defp check_tool_choice(_codec, _request, _config, %Capabilities{tool_choice: other}) do
    flunk("Capabilities.tool_choice must be a boolean, got: #{inspect(other)}")
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
      with_field(request, :output, json_schema(codec)),
      config,
      "declares structured_output: :none but accepts a json_schema output"
    )
  end

  defp check_output(codec, request, config, :json_object) do
    assert :ok == codec.validate_request(with_field(request, :output, :json_object), config),
           "#{inspect(codec)} declares structured_output: :json_object but rejects it"

    expect_rejection(
      codec,
      with_field(request, :output, json_schema(codec)),
      config,
      "declares structured_output: :json_object but accepts a json_schema output"
    )
  end

  defp check_output(codec, request, config, :json_schema) do
    for output <- [:json_object, json_schema(codec)] do
      assert :ok == codec.validate_request(with_field(request, :output, output), config),
             "#{inspect(codec)} declares structured_output: :json_schema but rejects #{inspect(output)}"
    end

    :ok
  end

  defp check_output(_codec, _request, _config, other) do
    flunk(
      "Capabilities.structured_output must be :none, :json_object or :json_schema, " <>
        "got: #{inspect(other)}"
    )
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

  defp check_input_sources(codec, request, config, %Input{} = declaration, kind, label) do
    for source_kind <- Input.kinds(%Input{inline: true, url: true, uri: true, file: true}) do
      declared? = source_kind in Input.kinds(declaration)

      check_part_support(
        codec,
        request,
        config,
        declared?,
        @input_samples[kind][source_kind],
        "#{label}.#{source_kind}"
      )
    end

    :ok
  end

  defp check_input_sources(_codec, _request, _config, other, _kind, label) do
    flunk("Capabilities.#{label} must be an LlmCall.Capabilities.Input, got: #{inspect(other)}")
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

  defp check_part_support(_codec, _request, _config, other, _part, label) do
    flunk("Capabilities.#{label} must be a boolean, got: #{inspect(other)}")
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

    for effort <- Enum.reject(@reasoning_levels, &(&1 in capabilities.efforts)) do
      expect_rejection(
        codec,
        with_field(request, :reasoning, %Reasoning{effort: effort}),
        config,
        "does not declare reasoning effort #{inspect(effort)} but accepts it"
      )
    end

    case budget_sample(request) do
      nil ->
        :ok

      budget ->
        check_reasoning_flag(
          codec,
          request,
          config,
          capabilities.budget_tokens,
          %Reasoning{budget_tokens: budget},
          "reasoning.budget_tokens"
        )
    end

    check_reasoning_summary(codec, request, config, capabilities.summary)
  end

  defp check_reasoning(_codec, _request, _config, other) do
    flunk(
      "Capabilities.reasoning must be nil or a %LlmCall.Reasoning.Capabilities{}, " <>
        "got: #{inspect(other)}"
    )
  end

  # A protocol may couple `budget_tokens` to another field (Anthropic requires
  # `1024 <= budget_tokens < params.max_tokens`), so a hardcoded sample can
  # contradict the request the caller passed in. The sample is derived from that
  # request instead: the smallest budget the contract allows. `nil` means the
  # request leaves no legal budget at all, which is a gap in the base request
  # rather than a codec defect, so the check is skipped.
  @budget_floor 1024

  defp budget_sample(%LlmCall.Request{params: params}) when is_map(params) do
    case params[:max_tokens] do
      max_tokens when is_integer(max_tokens) and max_tokens > @budget_floor + 1 ->
        @budget_floor

      max_tokens when is_integer(max_tokens) and max_tokens > 1 and max_tokens > @budget_floor ->
        max_tokens - 1

      max_tokens when is_integer(max_tokens) ->
        nil

      _absent ->
        @budget_floor
    end
  end

  defp budget_sample(_request), do: @budget_floor

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

  defp check_reasoning_flag(_codec, _request, _config, other, _reasoning, label) do
    flunk("ReasoningCapabilities.#{label} must be a boolean, got: #{inspect(other)}")
  end

  defp check_reasoning_summary(codec, request, config, declared) when is_list(declared) do
    for summary <- declared do
      assert :ok ==
               codec.validate_request(
                 with_field(request, :reasoning, %Reasoning{summary: summary}),
                 config
               ),
             "#{inspect(codec)} declares reasoning summary #{inspect(summary)} but rejects it"
    end

    for summary <- Enum.reject(@reasoning_summaries, &(&1 in declared)) do
      expect_rejection(
        codec,
        with_field(request, :reasoning, %Reasoning{summary: summary}),
        config,
        "does not declare reasoning summary #{inspect(summary)} but accepts it"
      )
    end

    :ok
  end

  defp check_reasoning_summary(_codec, _request, _config, other) do
    flunk("ReasoningCapabilities.summary must be a list, got: #{inspect(other)}")
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

    assert_arguments_error(call, label)
  end

  defp assert_assembled_call(other, label) do
    flunk(
      "#{label} StreamAssembler must produce %LlmCall.ToolCall{} structs, got: #{inspect(other)}"
    )
  end

  defp assert_arguments_error(%ToolCall{arguments_error: nil}, _label), do: :ok

  defp assert_arguments_error(%ToolCall{arguments_error: :no_json_decoder} = call, label) do
    assert is_nil(call.arguments),
           "#{label} reported :no_json_decoder but decoded arguments anyway"
  end

  defp assert_arguments_error(%ToolCall{arguments_error: {:invalid_json, reason}} = call, label) do
    assert is_binary(reason),
           "#{label} ToolCall.arguments_error must carry a reason string, " <>
             "got: #{inspect(reason)}"

    assert is_nil(call.arguments),
           "#{label} reported invalid_json but decoded arguments anyway"
  end

  defp assert_arguments_error(
         %ToolCall{arguments: nil, arguments_error: {:too_large, bytes}},
         _label
       )
       when is_integer(bytes) and bytes > 0,
       do: :ok

  defp assert_arguments_error(%ToolCall{arguments_error: {:too_large, bytes}}, label)
       when is_integer(bytes) and bytes > 0 do
    flunk("#{label} reported too_large but decoded arguments anyway")
  end

  defp assert_arguments_error(%ToolCall{arguments_error: other}, label) do
    flunk(
      "#{label} ToolCall.arguments_error must be nil, :no_json_decoder, " <>
        "{:invalid_json, reason}, or {:too_large, bytes}, got: #{inspect(other)}"
    )
  end

  defp encode_for_stream(codec, request, config, label, stream?) do
    case codec.encode_request(request, config) do
      {:ok, %EncodedRequest{} = encoded} ->
        encoded

      {:error, %Error{kind: :validation, message: message}} ->
        flunk(encode_failure(codec, request, config, label, stream?, message))

      other ->
        flunk(
          "#{label}.encode_request/2 must succeed with stream: #{stream?}, " <>
            "got: #{inspect(other)}"
        )
    end
  end

  defp encode_failure(codec, request, config, label, true, message) do
    if codec.capabilities(request, config).streaming do
      "#{label} cannot encode this request with stream: true (#{message}); " <>
        "pass a base request the codec accepts for both values"
    else
      "#{label}.capabilities/2 declares streaming: false, so stream: true cannot " <>
        "encode (#{message})"
    end
  end

  defp encode_failure(_codec, _request, _config, label, false, message) do
    "#{label} cannot encode this request at all (#{message})"
  end

  defp signal?(streaming, plain, nil), do: streaming_signal?(streaming, plain)
  defp signal?(streaming, _plain, marker), do: marker.(streaming)

  defp streaming_signal?(%EncodedRequest{} = streaming, %EncodedRequest{} = plain) do
    (is_map(streaming.body) and Map.get(streaming.body, "stream") == true) or
      query_signal?(streaming.query) or
      path_signal?(streaming.path, plain.path)
  end

  defp path_signal?(path, baseline) do
    is_binary(path) and path != baseline and String.contains?(path, "stream")
  end

  defp query_signal?(query) when is_map(query) do
    Enum.any?(query, fn
      {key, value} -> sse_value?(value) or stream_flag?(key, value)
      _entry -> false
    end)
  end

  defp query_signal?(_query), do: false

  defp sse_value?(value) when is_binary(value), do: String.downcase(value) == "sse"
  defp sse_value?(_value), do: false

  defp stream_flag?(key, value) do
    is_binary(key) and String.downcase(key) == "stream" and value in [true, "true", 1]
  end

  defp assert_required_signals(_streaming, [], _label), do: :ok

  defp assert_required_signals(streaming, required, label) do
    for {field, expected} <- required, is_map(expected) do
      actual = streaming |> Map.get(field) |> Map.take(Map.keys(expected))

      assert actual == expected,
             "#{label} streaming #{field} must carry #{inspect(expected)}, " <>
               "got: #{inspect(actual)}"
    end

    :ok
  end

  defp assert_credential_free(%EncodedRequest{headers: headers}, label) do
    names = Enum.map(headers || [], fn {name, _value} -> String.downcase(name) end)

    for forbidden <- Shared.credential_headers() do
      refute forbidden in names,
             "#{label} streaming request contains a credential header #{inspect(forbidden)}"
    end

    :ok
  end

  defp collect_stream(codec, request, chunks, label, config \\ %Config{}) do
    assert {:ok, %StreamState{} = state} = codec.init_stream(request, config),
           "#{label}.init_stream/2 must return {:ok, %LlmCall.StreamState{}}"

    {events, state, done?, halted?} =
      chunks
      |> Enum.with_index()
      |> Enum.reduce_while({[], state, false, false}, fn {chunk, position},
                                                         {events, state, _done, _halted} ->
        case codec.decode_stream_event(chunk, config, state) do
          {:ok, new_events, %StreamState{} = next} when is_list(new_events) ->
            {:cont, {events ++ new_events, next, false, false}}

          {:done, %StreamState{} = next} ->
            {:halt, {events, next, true, false}}

          {:error, %Error{} = error} ->
            Shared.assert_error(error, label)
            {:halt, {events, state, true, true}}

          other ->
            flunk(
              "#{label}.decode_stream_event/3 must return {:ok, events, state}, " <>
                "{:done, state}, or {:error, %LlmCall.Error{}} for chunk #{position}, " <>
                "got: #{inspect(other)}"
            )
        end
      end)

    if halted? do
      {events, [], done?}
    else
      # A protocol with a terminator may reject a body that never carried it, so an
      # error here is a legal answer; anything else is a contract violation.
      case codec.finish_stream(state, config) do
        {:ok, tail, %StreamState{}} when is_list(tail) ->
          {events ++ tail, tail, done?}

        {:error, %Error{} = error} ->
          Shared.assert_error(error, label)
          {events, [], done?}

        other ->
          flunk(
            "#{label}.finish_stream/2 must return {:ok, events, state} or " <>
              "{:error, %LlmCall.Error{}}, got: #{inspect(other)}"
          )
      end
    end
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
        assert List.last(types) == terminal,
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
          "malformed payload; it must return {:error, %LlmCall.Error{}}"
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

  defp minimal_tool(codec), do: %ToolSpec{name: "f", parameters: minimal_schema(codec)}

  defp builtin_tool(name), do: %ToolSpec{kind: :builtin, name: name}

  defp json_schema(codec), do: {:json_schema, "result", minimal_schema(codec), nil}

  defp minimal_schema(LlmCall.Dialect.Gemini.GenerateContent), do: %{"type" => "OBJECT"}
  defp minimal_schema(_codec), do: %{"type" => "object"}

  defp with_field(request, field, value), do: Map.put(request, field, value)

  defp with_part(request, part) do
    case List.last(request.messages) do
      %Message{role: :user, content: content} when is_list(content) ->
        message = %Message{role: :user, content: content ++ [part]}
        with_field(request, :messages, List.replace_at(request.messages, -1, message))

      _other ->
        with_field(
          request,
          :messages,
          request.messages ++ [%Message{role: :user, content: [part]}]
        )
    end
  end
end

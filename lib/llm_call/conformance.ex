defmodule LlmCall.Conformance do
  @moduledoc """
  Assertions shared by `LlmCall.Codec.Conformance` and
  `LlmCall.MediaConformance`.

  Test support, not a runtime dependency: it imports `ExUnit.Assertions` and is
  meant to be called from a test.
  """

  import ExUnit.Assertions

  alias LlmCall.{Codec, Content, Error, Response, StreamDelta, StreamEvent, Usage}

  @credential_headers ["authorization", "x-api-key", "api-key"]

  @error_kinds [:protocol, :validation, :invalid_response, :provider]

  @stop_reasons [
    :end_turn,
    :tool_calls,
    :max_tokens,
    :stop_sequence,
    :content_filter,
    :error,
    :unknown
  ]

  @usage_fields Enum.sort(Map.keys(%Usage{}) -- [:__struct__])

  @part_modules [
    Content.Text,
    Content.Image,
    Content.File,
    Content.Video,
    Content.Thinking,
    Content.Raw,
    LlmCall.ToolCall,
    LlmCall.ToolResult
  ]

  @delta_for %{
    text_delta: [StreamDelta.Text],
    thinking_delta: [StreamDelta.Thinking],
    tool_call_start: [StreamDelta.ToolCall],
    tool_call_delta: [StreamDelta.ToolCall],
    tool_call_stop: [StreamDelta.ToolCall],
    message_delta: [StreamDelta.MessageDelta, StreamDelta.Raw]
  }

  @delta_free [:message_start, :content_start, :content_stop, :message_stop]

  @delta_any [:error]

  @event_types Enum.sort(@delta_free ++ Map.keys(@delta_for) ++ @delta_any)

  @doc """
  Asserts that `info/0` returns well-formed codec metadata.

  `ir_version` must be `1`; `version` is a wire version string or `nil`.
  """
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

  @doc "The header names a codec must never emit (the transport adds them)."
  @spec credential_headers() :: [String.t()]
  def credential_headers, do: @credential_headers

  @doc """
  Asserts that a decoded error is a canonical `LlmCall.Error`.

  The status is always `nil` — only the transport knows the HTTP status — and a
  provider code is normalized to a string or `nil`, whatever the wire type was.
  """
  @spec assert_error(Error.t() | term(), String.t()) :: :ok
  def assert_error(%Error{} = error, label) do
    assert error.kind in @error_kinds,
           "#{label} error kind must be one of #{inspect(@error_kinds)}, got: #{inspect(error.kind)}"

    assert is_binary(error.message) and error.message != "",
           "#{label} error message must be a non-empty string, got: #{inspect(error.message)}"

    assert is_nil(error.code) or is_binary(error.code),
           "#{label} error code must be a string or nil, got: #{inspect(error.code)}"

    assert is_nil(error.status),
           "#{label} must not set error status: only the transport knows the HTTP status, " <>
             "got: #{inspect(error.status)}"

    assert is_boolean(error.retryable?),
           "#{label} error retryable? must be a boolean, got: #{inspect(error.retryable?)}"

    assert is_nil(error.raw) or is_map(error.raw),
           "#{label} error raw must be a map or nil, got: #{inspect(error.raw)}"

    :ok
  end

  def assert_error(other, label) do
    flunk("#{label} must return a %LlmCall.Error{}, got: #{inspect(other)}")
  end

  @doc "Asserts that usage is `nil` or canonical, with non-negative integer counts."
  @spec assert_usage(Usage.t() | term(), String.t()) :: :ok
  def assert_usage(nil, _label), do: :ok

  def assert_usage(%Usage{} = usage, label) do
    for field <- @usage_fields do
      value = Map.fetch!(usage, field)

      assert is_nil(value) or (is_integer(value) and value >= 0),
             "#{label} usage #{field} must be a non-negative integer or nil, " <>
               "got: #{inspect(value)}"
    end

    :ok
  end

  def assert_usage(other, label) do
    flunk("#{label} usage must be a %LlmCall.Usage{} or nil, got: #{inspect(other)}")
  end

  @doc """
  Asserts that every part is a canonical content struct.

  A provider-specific map in `content` means the codec leaked its wire shape into
  the IR instead of mapping it.
  """
  @spec assert_content_parts([Content.part()], String.t()) :: :ok
  def assert_content_parts(parts, label) when is_list(parts) do
    for part <- parts do
      assert is_struct(part) and part.__struct__ in @part_modules,
             "#{label} content part must be one of #{inspect(@part_modules)}, " <>
               "got: #{inspect(part)}"
    end

    :ok
  end

  def assert_content_parts(other, label) do
    flunk("#{label} content must be a list of canonical parts, got: #{inspect(other)}")
  end

  @doc """
  Asserts that a decoded completion response is canonical.

  `content` holds canonical parts, `stop_reason` is in the closed union, `usage`
  is canonical or `nil`, and `raw` is a map or `nil` — never a second response
  model.
  """
  @spec assert_response(Response.t() | term(), String.t()) :: :ok
  def assert_response(%Response{} = response, label) do
    assert is_nil(response.id) or is_binary(response.id),
           "#{label} response id must be a string or nil, got: #{inspect(response.id)}"

    assert is_nil(response.model) or is_binary(response.model),
           "#{label} response model must be a string or nil, got: #{inspect(response.model)}"

    assert_content_parts(response.content, label)

    assert response.stop_reason in @stop_reasons,
           "#{label} response stop_reason must be one of #{inspect(@stop_reasons)}, " <>
             "got: #{inspect(response.stop_reason)}"

    assert_usage(response.usage, label)

    assert is_nil(response.raw) or is_map(response.raw),
           "#{label} response raw must be a map or nil, got: #{inspect(response.raw)}"

    :ok
  end

  def assert_response(other, label) do
    flunk("#{label} must return a %LlmCall.Response{}, got: #{inspect(other)}")
  end

  @doc """
  Asserts that a stream event uses the canonical type union and its matching delta.

  The index is a non-negative integer or `nil`. A content event carries the delta
  its type names (`:text_delta` → `StreamDelta.Text`, and so on); a
  `:message_delta` carries either the normalized delta or `StreamDelta.Raw` for an
  unmapped provider field, which is how a codec preserves unknown data. A
  structural event carries none.
  """
  @spec assert_stream_event(StreamEvent.t() | term(), String.t()) :: :ok
  def assert_stream_event(%StreamEvent{type: type, index: index, delta: delta}, label) do
    assert type in @event_types,
           "#{label} stream event type must be one of #{inspect(@event_types)}, " <>
             "got: #{inspect(type)}"

    assert is_nil(index) or (is_integer(index) and index >= 0),
           "#{label} stream event index must be a non-negative integer or nil, " <>
             "got: #{inspect(index)}"

    assert_delta(type, delta, label)

    :ok
  end

  def assert_stream_event(other, label) do
    flunk("#{label} must emit %LlmCall.StreamEvent{} structs, got: #{inspect(other)}")
  end

  defp assert_delta(type, delta, label) do
    cond do
      modules = @delta_for[type] ->
        assert Enum.any?(modules, &is_struct(delta, &1)),
               "#{label} #{inspect(type)} must carry one of #{inspect(modules)}, " <>
                 "got: #{inspect(delta)}"

      type in @delta_free ->
        assert is_nil(delta),
               "#{label} #{inspect(type)} is structural and must not carry a delta, " <>
                 "got: #{inspect(delta)}"

      true ->
        :ok
    end
  end
end

defmodule LlmDialect do
  @moduledoc """
  Wire-protocol codec for LLM APIs.

  `LlmDialect` turns a provider-neutral request into the request body, path, and
  protocol headers a provider expects, and turns provider response terms into a
  provider-neutral response.

  It owns no transport, authentication, model discovery, tool execution,
  approvals, retries, or agent loop. A codec returns JSON-compatible Elixir
  terms; the caller's HTTP stack performs the request and the JSON encoding.

      {:ok, encoded} = LlmDialect.encode(LlmDialect.Protocol.Anthropic.Messages, request)
      # transport: POST base_url <> encoded.path with encoded.body
      {:ok, response} = LlmDialect.decode_response(LlmDialect.Protocol.Anthropic.Messages, payload)

  See `docs/design.md` for the canonical IR contract and the list of protocol
  adapters.
  """

  @type model :: String.t()

  @type capture_raw :: :none | :response | :all

  @type modality :: :text | :image | :video

  @type wire_value ::
          nil
          | boolean()
          | number()
          | String.t()
          | [wire_value()]
          | %{optional(String.t()) => wire_value()}

  @type stop_reason ::
          :end_turn
          | :tool_calls
          | :max_tokens
          | :stop_sequence
          | :content_filter
          | :error
          | :unknown

  alias LlmDialect.{Config, Error, StreamState}

  @doc "Encodes a canonical request into one protocol's wire request."
  @spec encode(module(), LlmDialect.Request.t(), Config.t()) ::
          {:ok, LlmDialect.EncodedRequest.t()} | {:error, Error.t()}
  def encode(codec, %LlmDialect.Request{} = request, config \\ %Config{}) do
    with :ok <- require_callback(codec, :encode_request, 2) do
      codec.encode_request(request, config)
    end
  end

  @doc "Decodes one provider response term into a canonical response."
  @spec decode_response(module(), LlmDialect.wire_value(), Config.t()) ::
          {:ok, LlmDialect.Response.t()} | {:error, Error.t()}
  def decode_response(codec, term, config \\ %Config{}) do
    with :ok <- require_callback(codec, :decode_response, 2) do
      codec.decode_response(term, config)
    end
  end

  @doc "Normalizes a provider error payload."
  @spec decode_error(module(), LlmDialect.wire_value(), Config.t()) :: Error.t()
  def decode_error(codec, term, config \\ %Config{}) do
    codec.decode_error(term, config)
  end

  @doc "Checks a request against the fields a codec can represent."
  @spec validate_request(module(), LlmDialect.Request.t(), Config.t()) ::
          :ok | {:error, Error.t()}
  def validate_request(codec, %LlmDialect.Request{} = request, config \\ %Config{}) do
    with :ok <- require_callback(codec, :encode_request, 2) do
      codec.validate_request(request, config)
    end
  end

  @doc """
  Describes what a completion codec supports.

  Capabilities are protocol-level, not model-level; see
  `LlmDialect.Capabilities`. Returns a typed error when the module implements the
  media behaviour instead.
  """
  @spec capabilities(module(), LlmDialect.Request.t(), Config.t()) ::
          {:ok, LlmDialect.Capabilities.t()} | {:error, Error.t()}
  def capabilities(codec, %LlmDialect.Request{} = request, config \\ %Config{}) do
    with :ok <- require_callback(codec, :encode_request, 2) do
      {:ok, codec.capabilities(request, config)}
    end
  end

  @doc "Starts a stream, or returns a typed error when the codec has no streaming."
  @spec init_stream(module(), LlmDialect.Request.t(), Config.t()) ::
          {:ok, StreamState.t()} | {:error, Error.t()}
  def init_stream(codec, %LlmDialect.Request{} = request, config \\ %Config{}) do
    with :ok <- require_callback(codec, :init_stream, 2) do
      codec.init_stream(request, config)
    end
  end

  @doc "Decodes one provider stream event into zero or more normalized events."
  @spec decode_stream_event(module(), LlmDialect.wire_value(), Config.t(), StreamState.t()) ::
          {:ok, [LlmDialect.StreamEvent.t()], StreamState.t()}
          | {:done, StreamState.t()}
          | {:error, Error.t()}
  def decode_stream_event(codec, term, config, %StreamState{} = state) do
    with :ok <- require_owner(codec, state),
         :ok <- require_callback(codec, :decode_stream_event, 3) do
      codec.decode_stream_event(term, config, state)
    end
  end

  @doc """
  Flushes whatever the protocol does not emit itself when the stream ends.

  Gemini has no stream terminator, so its accumulated usage and `:message_stop`
  arrive only here. Calling it more than once is safe.
  """
  @spec finish_stream(module(), StreamState.t(), Config.t()) ::
          {:ok, [LlmDialect.StreamEvent.t()], StreamState.t()} | {:error, Error.t()}
  def finish_stream(codec, %StreamState{} = state, config \\ %Config{}) do
    with :ok <- require_owner(codec, state),
         :ok <- require_callback(codec, :finish_stream, 2) do
      codec.finish_stream(state, config)
    end
  end

  @doc """
  Encodes a media generation request, or starts a long-running job.

  The codec validates first; a knob it cannot express is a typed error.
  """
  @spec encode_media(module(), LlmDialect.Media.Request.t(), Config.t()) ::
          {:ok, LlmDialect.EncodedRequest.t()} | {:error, Error.t()}
  def encode_media(codec, %LlmDialect.Media.Request{} = request, config \\ %Config{}) do
    with :ok <- require_callback(codec, :encode_submit, 2) do
      codec.encode_submit(request, config)
    end
  end

  @doc "Decodes a media generation response, sync assets or an operation."
  @spec decode_media(module(), LlmDialect.wire_value(), Config.t()) ::
          {:ok, LlmDialect.Media.Response.t()} | {:error, Error.t()}
  def decode_media(codec, term, config \\ %Config{}) do
    with :ok <- require_callback(codec, :decode_submit, 2) do
      codec.decode_submit(term, config)
    end
  end

  @doc """
  Decodes the next state of a long-running job.

  Returns a typed `:validation` error when the codec has no
  `decode_operation/2`.
  """
  @spec decode_operation(module(), LlmDialect.wire_value(), Config.t()) ::
          {:ok, LlmDialect.Operation.t()} | {:error, Error.t()}
  def decode_operation(codec, term, config \\ %Config{}) do
    with :ok <- require_callback(codec, :decode_operation, 2) do
      codec.decode_operation(term, config)
    end
  end

  @doc "Checks a media request against the fields a codec can represent."
  @spec validate_media(module(), LlmDialect.Media.Request.t(), Config.t()) ::
          :ok | {:error, Error.t()}
  def validate_media(codec, %LlmDialect.Media.Request{} = request, config \\ %Config{}) do
    with :ok <- require_callback(codec, :encode_submit, 2) do
      codec.validate_request(request, config)
    end
  end

  @doc """
  Describes the media surface a codec declares.

  Returns a typed error when the module implements the completion behaviour
  instead.
  """
  @spec media_capabilities(module(), LlmDialect.Media.Request.t(), Config.t()) ::
          {:ok, LlmDialect.Media.Capabilities.t()} | {:error, Error.t()}
  def media_capabilities(codec, %LlmDialect.Media.Request{} = request, config \\ %Config{}) do
    with :ok <- require_callback(codec, :encode_submit, 2) do
      {:ok, codec.capabilities(request, config)}
    end
  end

  defp require_owner(codec, %StreamState{codec: codec}), do: :ok

  defp require_owner(codec, %StreamState{codec: owner}) do
    {:error,
     %Error{
       kind: :validation,
       message: "stream state belongs to #{inspect(owner)}, not #{inspect(codec)}"
     }}
  end

  defp require_callback(codec, function, arity) do
    Code.ensure_loaded!(codec)

    if function_exported?(codec, function, arity) do
      :ok
    else
      {:error,
       %Error{
         kind: :validation,
         message: "#{inspect(codec)} does not support #{function}/#{arity}"
       }}
    end
  end
end

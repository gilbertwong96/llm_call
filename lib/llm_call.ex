defmodule LlmCall do
  @moduledoc """
  Wire-protocol codec for LLM APIs.

  `LlmCall` turns a provider-neutral request into the request body, path, and
  protocol headers a provider expects, and turns provider response terms into a
  provider-neutral response.

  It ships a one-call client (`complete/3`, `stream/3`, `generate/3`, `poll/3`) on
  top of replaceable HTTP, JSON and tool layers, and keeps the encode/decode
  functions for callers that already own a transport.

      client = MyApp.Anthropic.client(api_key: System.fetch_env!("ANTHROPIC_API_KEY"))
      {:ok, response} = LlmCall.complete(client, request)

  It still owns no model discovery, approvals, retries, or agent loop. A codec
  returns JSON-compatible Elixir terms; the client performs the request and the
  JSON encoding with the modules configured in `LlmCall.Config` and
  `LlmCall.Client`.

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

  alias LlmCall.{Client, Config, EncodedRequest, Error, StreamState}
  alias LlmCall.HTTP

  @default_codec :chat

  @doc """
  Calls a provider: encode, send, decode.

  `opts`: `codec:` names an entry in the provider's `codecs` map (`:chat` by
  default). A request with `stream: true` is rejected — use `stream/3`.

  Non-`2xx` responses are decoded by the codec and carry the HTTP `status`; a
  body the configured JSON module cannot parse is `:invalid_response`; a network
  failure is `:transport`.
  """
  @spec complete(Client.t(), LlmCall.Request.t(), keyword()) ::
          {:ok, LlmCall.Response.t()} | {:error, Error.t()}
  def complete(%Client{} = client, %LlmCall.Request{} = request, opts \\ []) do
    with :ok <- reject_streaming(request),
         {:ok, codec} <- fetch_codec(client, opts),
         :ok <- require_callback(codec, :encode_request, 2),
         {:ok, encoded} <- codec.encode_request(request, client.config) do
      call_and_decode(client, encoded, codec, &codec.decode_response(&1, client.config))
    end
  end

  @doc """
  Starts a streaming call.

  Encodes the request with `stream: true` and starts the codec's stream state
  eagerly, so an invalid request is a tagged error; the HTTP request itself starts
  when the returned `%LlmCall.Stream{}` is reduced.

  `codec:` names an entry in the provider's `codecs` map (`:chat` by default).
  Events are yielded as `LlmCall.StreamEvent` structs; a failure while reading the
  body raises `LlmCall.HTTP.Error`, because an `Enumerable` cannot return a tuple.
  """
  @spec stream(Client.t(), LlmCall.Request.t(), keyword()) ::
          {:ok, LlmCall.Stream.t()} | {:error, Error.t()}
  def stream(%Client{} = client, %LlmCall.Request{} = request, opts \\ []) do
    request = %{request | stream: true}

    with {:ok, codec} <- fetch_codec(client, opts),
         :ok <- require_callback(codec, :init_stream, 2),
         {:ok, encoded} <- codec.encode_request(request, client.config),
         {:ok, body} <- encode_body(client, encoded.body),
         {:ok, state} <- codec.init_stream(request, client.config) do
      {:ok,
       %LlmCall.Stream{
         client: client,
         codec: codec,
         http_request: build_http_request(client, encoded, body),
         state: state
       }}
    end
  end

  @doc """
  Submits a media generation request.

  `codec:` is required and names an entry in the provider's `codecs` map (for
  example `:images`, `:predict`, `:video`). The codec validates and encodes the
  submit, and decodes the response into `%LlmCall.Media.Response{}` — assets, or a
  queued `%LlmCall.Operation{}` whose `next` is the request to run with `poll/3`.
  """
  @spec generate(Client.t(), LlmCall.Media.Request.t(), keyword()) ::
          {:ok, LlmCall.Media.Response.t()} | {:error, Error.t()}
  def generate(%Client{} = client, %LlmCall.Media.Request{} = request, opts \\ []) do
    with {:ok, codec} <- fetch_media_codec(client, opts),
         :ok <- require_callback(codec, :encode_submit, 2),
         {:ok, encoded} <- codec.encode_submit(request, client.config) do
      call_and_decode(client, encoded, codec, &codec.decode_submit(&1, client.config))
    end
  end

  @doc """
  Advances a media operation.

  Accepts a `%LlmCall.Operation{}` (its `next` is executed) or the
  `%LlmCall.EncodedRequest{}` to run, decodes the body with the codec's
  `decode_operation/2`, and returns the next operation state. `codec:` is
  required, because an operation does not carry it.
  """
  @spec poll(Client.t(), LlmCall.Operation.t() | EncodedRequest.t(), keyword()) ::
          {:ok, LlmCall.Operation.t()} | {:error, Error.t()}
  def poll(client, operation_or_encoded, opts \\ [])

  def poll(%Client{} = client, %LlmCall.Operation{} = operation, opts) do
    case operation.next do
      %EncodedRequest{} = encoded ->
        poll(client, encoded, opts)

      nil ->
        {:error, invalid("the operation has no next request", :validation)}
    end
  end

  def poll(%Client{} = client, %EncodedRequest{} = encoded, opts) do
    with {:ok, codec} <- fetch_media_codec(client, opts),
         :ok <- require_callback(codec, :decode_operation, 2) do
      call_and_decode(client, encoded, codec, &codec.decode_operation(&1, client.config))
    end
  end

  @doc """
  Performs a request the caller already encoded.

  Transport-level: a `2xx` body is JSON-decoded into `body`, anything else is
  `:transport` with the status. Use `complete/3` when you want the codec to decode
  a provider error envelope.
  """
  @spec execute(Client.t(), EncodedRequest.t(), keyword()) ::
          {:ok, %{status: non_neg_integer(), headers: list(), body: term()}}
          | {:error, Error.t()}
  def execute(%Client{} = client, %EncodedRequest{} = encoded, _opts \\ []) do
    case perform(client, encoded) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        decode_json_body(client, response)

      {:ok, %{status: status}} ->
        {:error, transport_error("HTTP #{status}", status)}

      {:error, %Error{}} = error ->
        error
    end
  end

  @doc """
  Performs a request and returns the body bytes, without JSON decoding.

  For `Operation.next_kind: :asset`, where the body is media.
  """
  @spec fetch(Client.t(), EncodedRequest.t(), keyword()) ::
          {:ok, %{status: non_neg_integer(), headers: list(), body: binary()}}
          | {:error, Error.t()}
  def fetch(%Client{} = client, %EncodedRequest{} = encoded, _opts \\ []) do
    case perform(client, encoded) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %{status: status}} ->
        {:error, transport_error("HTTP #{status}", status)}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp perform(%Client{} = client, %EncodedRequest{} = encoded) do
    with {:ok, body} <- encode_body(client, encoded.body) do
      request = build_http_request(client, encoded, body)
      normalize(client, client.http.request(request, client.http_opts))
    end
  end

  defp build_http_request(%Client{} = client, %EncodedRequest{} = encoded, body) do
    url = client.base_url <> encoded.path <> encode_query(encoded.query)
    headers = client.headers ++ encoded.headers

    HTTP.Request.post(url, headers, body, client.timeout)
  end

  defp encode_body(_client, nil), do: {:ok, ""}

  defp encode_body(%Client{config: %Config{json: json}}, body) do
    case json.encode(body) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _reason} -> {:error, invalid("request body is not JSON-encodable", :validation)}
    end
  end

  defp normalize(_client, {:ok, %{status: status, headers: headers, body: body}}) do
    {:ok, %{status: status, headers: headers, body: body}}
  end

  defp normalize(_client, {:error, reason}) do
    {:error, transport_error("transport error: #{inspect(reason)}", nil)}
  end

  defp call_and_decode(%Client{} = client, encoded, codec, decode_fun) do
    case perform(client, encoded) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        with {:ok, %{body: body}} <- decode_json_body(client, response) do
          decode_fun.(body)
        end

      {:ok, response} ->
        decode_failure(client, codec, response)

      {:error, %Error{}} = error ->
        error
    end
  end

  defp decode_failure(%Client{} = client, codec, %{status: status, body: raw}) do
    payload =
      case client.config.json.decode(raw) do
        {:ok, term} -> term
        {:error, _reason} -> nil
      end

    if is_map(payload) do
      case codec.decode_error(payload, client.config) do
        %Error{} = error -> {:error, %{error | status: status}}
      end
    else
      {:error, transport_error("HTTP #{status}: body is not JSON", status)}
    end
  end

  defp decode_json_body(%Client{config: %Config{json: json}}, %{body: raw} = response) do
    case json.decode(raw) do
      {:ok, term} -> {:ok, %{response | body: term}}
      {:error, _reason} -> {:error, invalid("response body is not JSON", :invalid_response)}
    end
  end

  defp fetch_codec(%Client{} = client, opts) do
    name = Keyword.get(opts, :codec, @default_codec)

    case Client.codec(client, name) do
      nil -> {:error, undeclared(client, name)}
      codec -> {:ok, codec}
    end
  end

  defp fetch_media_codec(%Client{} = client, opts) do
    case Keyword.fetch(opts, :codec) do
      {:ok, name} ->
        case Client.codec(client, name) do
          nil -> {:error, undeclared(client, name)}
          codec -> {:ok, codec}
        end

      :error ->
        {:error,
         invalid("a media call requires codec: (for example codec: :images)", :validation)}
    end
  end

  defp undeclared(%Client{} = client, name) do
    invalid(
      "#{inspect(client.provider)} does not declare a #{inspect(name)} codec; " <>
        "declared: #{inspect(Map.keys(client.codecs))}",
      :validation
    )
  end

  defp reject_streaming(%LlmCall.Request{stream: true}) do
    {:error, invalid("stream: true belongs to stream/3", :validation)}
  end

  defp reject_streaming(_request), do: :ok

  defp encode_query(query) when query == %{}, do: ""

  defp encode_query(query) do
    "?" <> URI.encode_query(query)
  end

  defp invalid(message, kind), do: %Error{kind: kind, message: message}

  defp transport_error(message, status) do
    %Error{kind: :transport, message: message, status: status}
  end

  @doc "Encodes a canonical request into one protocol's wire request."
  @spec encode(module(), LlmCall.Request.t(), Config.t()) ::
          {:ok, LlmCall.EncodedRequest.t()} | {:error, Error.t()}
  def encode(codec, %LlmCall.Request{} = request, config \\ Config.new()) do
    with :ok <- require_callback(codec, :encode_request, 2) do
      codec.encode_request(request, config)
    end
  end

  @doc "Decodes one provider response term into a canonical response."
  @spec decode_response(module(), LlmCall.wire_value(), Config.t()) ::
          {:ok, LlmCall.Response.t()} | {:error, Error.t()}
  def decode_response(codec, term, config \\ Config.new()) do
    with :ok <- require_callback(codec, :decode_response, 2) do
      codec.decode_response(term, config)
    end
  end

  @doc "Normalizes a provider error payload."
  @spec decode_error(module(), LlmCall.wire_value(), Config.t()) :: Error.t()
  def decode_error(codec, term, config \\ Config.new()) do
    codec.decode_error(term, config)
  end

  @doc "Checks a request against the fields a codec can represent."
  @spec validate_request(module(), LlmCall.Request.t(), Config.t()) ::
          :ok | {:error, Error.t()}
  def validate_request(codec, %LlmCall.Request{} = request, config \\ Config.new()) do
    with :ok <- require_callback(codec, :encode_request, 2) do
      codec.validate_request(request, config)
    end
  end

  @doc """
  Describes what a completion codec supports.

  Capabilities are protocol-level, not model-level; see
  `LlmCall.Capabilities`. Returns a typed error when the module implements the
  media behaviour instead.
  """
  @spec capabilities(module(), LlmCall.Request.t(), Config.t()) ::
          {:ok, LlmCall.Capabilities.t()} | {:error, Error.t()}
  def capabilities(codec, %LlmCall.Request{} = request, config \\ Config.new()) do
    with :ok <- require_callback(codec, :encode_request, 2) do
      {:ok, codec.capabilities(request, config)}
    end
  end

  @doc "Starts a stream, or returns a typed error when the codec has no streaming."
  @spec init_stream(module(), LlmCall.Request.t(), Config.t()) ::
          {:ok, StreamState.t()} | {:error, Error.t()}
  def init_stream(codec, %LlmCall.Request{} = request, config \\ Config.new()) do
    with :ok <- require_callback(codec, :init_stream, 2) do
      codec.init_stream(request, config)
    end
  end

  @doc "Decodes one provider stream event into zero or more normalized events."
  @spec decode_stream_event(module(), LlmCall.wire_value(), Config.t(), StreamState.t()) ::
          {:ok, [LlmCall.StreamEvent.t()], StreamState.t()}
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
          {:ok, [LlmCall.StreamEvent.t()], StreamState.t()} | {:error, Error.t()}
  def finish_stream(codec, %StreamState{} = state, config \\ Config.new()) do
    with :ok <- require_owner(codec, state),
         :ok <- require_callback(codec, :finish_stream, 2) do
      codec.finish_stream(state, config)
    end
  end

  @doc """
  Encodes a media generation request, or starts a long-running job.

  The codec validates first; a knob it cannot express is a typed error.
  """
  @spec encode_media(module(), LlmCall.Media.Request.t(), Config.t()) ::
          {:ok, LlmCall.EncodedRequest.t()} | {:error, Error.t()}
  def encode_media(codec, %LlmCall.Media.Request{} = request, config \\ Config.new()) do
    with :ok <- require_callback(codec, :encode_submit, 2) do
      codec.encode_submit(request, config)
    end
  end

  @doc "Decodes a media generation response, sync assets or an operation."
  @spec decode_media(module(), LlmCall.wire_value(), Config.t()) ::
          {:ok, LlmCall.Media.Response.t()} | {:error, Error.t()}
  def decode_media(codec, term, config \\ Config.new()) do
    with :ok <- require_callback(codec, :decode_submit, 2) do
      codec.decode_submit(term, config)
    end
  end

  @doc """
  Decodes the next state of a long-running job.

  Returns a typed `:validation` error when the codec has no
  `decode_operation/2`.
  """
  @spec decode_operation(module(), LlmCall.wire_value(), Config.t()) ::
          {:ok, LlmCall.Operation.t()} | {:error, Error.t()}
  def decode_operation(codec, term, config \\ Config.new()) do
    with :ok <- require_callback(codec, :decode_operation, 2) do
      codec.decode_operation(term, config)
    end
  end

  @doc "Checks a media request against the fields a codec can represent."
  @spec validate_media(module(), LlmCall.Media.Request.t(), Config.t()) ::
          :ok | {:error, Error.t()}
  def validate_media(codec, %LlmCall.Media.Request{} = request, config \\ Config.new()) do
    with :ok <- require_callback(codec, :encode_submit, 2) do
      codec.validate_request(request, config)
    end
  end

  @doc """
  Describes the media surface a codec declares.

  Returns a typed error when the module implements the completion behaviour
  instead.
  """
  @spec media_capabilities(module(), LlmCall.Media.Request.t(), Config.t()) ::
          {:ok, LlmCall.Media.Capabilities.t()} | {:error, Error.t()}
  def media_capabilities(codec, %LlmCall.Media.Request{} = request, config \\ Config.new()) do
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

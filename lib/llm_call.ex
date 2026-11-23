defmodule LlmCall do
  @moduledoc """
  Wire-protocol codec for LLM APIs.

  `LlmCall` turns a provider-neutral request into the request body, path, and
  protocol headers a provider expects, and turns provider response terms into a
  provider-neutral response.

  It ships a one-call client (`complete/3`, `stream/3`, `generate/3`, `poll/3`) on
  top of Finch and a replaceable JSON layer, and keeps the encode/decode functions
  for callers that already own a transport.

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

  alias LlmCall.{Client, Config, EncodedRequest, Error, Operation, StreamState, Tools}
  alias LlmCall.HTTP

  @default_codec :chat

  @call_options [:codec, :headers]

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
  def complete(client, request, opts \\ [])

  def complete(%Client{} = client, %LlmCall.Request{} = request, opts) do
    with :ok <- validate_call_options(opts, @call_options),
         :ok <- validate_headers(opts[:headers]),
         :ok <- reject_streaming(request),
         {:ok, codec} <- fetch_codec(client, opts),
         :ok <- require_callback(codec, :encode_request, 2),
         :ok <- require_callback(codec, :decode_response, 2),
         :ok <- require_callback(codec, :decode_error, 2),
         {:ok, request} <- Tools.normalize_request(request, codec),
         {:ok, encoded} <- call_encode(codec, :encode_request, request, client.config) do
      client
      |> call_and_decode(
        encoded,
        codec,
        &codec.decode_response(&1, client.config),
        opts[:headers]
      )
      |> check_decoded(LlmCall.Response, "decode_response/2")
    end
  end

  def complete(client, request, _opts),
    do:
      {:error,
       not_a_client_and_request(client, request, "%LlmCall.Client{}", "%LlmCall.Request{}")}

  @doc """
  Starts a streaming call.

  Encodes the request with `stream: true` and starts the codec's stream state
  eagerly, so an invalid request is a tagged error; the HTTP request itself starts
  when the returned `%LlmCall.Stream{}` is reduced.

  `codec:` names an entry in the provider's `codecs` map (`:chat` by default).
  Events are yielded as `LlmCall.StreamEvent` structs; a failure while reading the
  body raises `LlmCall.HTTP.Error`, because an `Enumerable` cannot return a tuple.

  `on_event:` takes a 1-arity function called for every event before the reducer
  sees it, including events flushed by `finish_stream/2`. It observes only: the
  return value is ignored, it cannot filter or replace events, and it is not
  called after the reducer halts.
  """
  @spec stream(Client.t(), LlmCall.Request.t(), keyword()) ::
          {:ok, LlmCall.Stream.t()} | {:error, Error.t()}
  def stream(client, request, opts \\ [])

  def stream(%Client{} = client, %LlmCall.Request{} = request, opts) do
    request = %{request | stream: true}

    with :ok <- validate_call_options(opts, [:on_event | @call_options]),
         :ok <- validate_headers(opts[:headers]),
         :ok <- validate_on_event(opts[:on_event]),
         {:ok, codec} <- fetch_codec(client, opts),
         :ok <- require_callback(codec, :init_stream, 2),
         :ok <- require_callback(codec, :decode_stream_event, 3),
         :ok <- require_callback(codec, :finish_stream, 2),
         :ok <- require_callback(codec, :decode_error, 2),
         {:ok, request} <- Tools.normalize_request(request, codec),
         {:ok, encoded} <- call_encode(codec, :encode_request, request, client.config),
         {:ok, http_request} <- build_http_request(client, encoded, opts[:headers]),
         {:ok, state} <- start_stream_state(codec, request, client.config) do
      {:ok,
       %LlmCall.Stream{
         client: client,
         codec: codec,
         http_request: http_request,
         state: state,
         on_event: opts[:on_event]
       }}
    end
  end

  def stream(client, request, _opts),
    do:
      {:error,
       not_a_client_and_request(client, request, "%LlmCall.Client{}", "%LlmCall.Request{}")}

  @doc """
  Submits a media generation request.

  `codec:` is required and names an entry in the provider's `codecs` map (for
  example `:images`, `:predict`, `:video`). The codec validates and encodes the
  submit, and decodes the response into `%LlmCall.Media.Response{}` — assets, or a
  queued `%LlmCall.Operation{}` whose `next` is the request to run with `poll/3`.
  """
  @spec generate(Client.t(), LlmCall.Media.Request.t(), keyword()) ::
          {:ok, LlmCall.Media.Response.t()} | {:error, Error.t()}
  def generate(client, request, opts \\ [])

  def generate(%Client{} = client, %LlmCall.Media.Request{} = request, opts) do
    with :ok <- validate_call_options(opts, @call_options),
         :ok <- validate_headers(opts[:headers]),
         {:ok, codec} <- fetch_media_codec(client, opts),
         :ok <- require_callback(codec, :encode_submit, 2),
         :ok <- require_callback(codec, :decode_submit, 2),
         :ok <- require_callback(codec, :decode_error, 2),
         {:ok, encoded} <- call_encode(codec, :encode_submit, request, client.config) do
      client
      |> call_and_decode(
        encoded,
        codec,
        &codec.decode_submit(&1, client.config),
        opts[:headers]
      )
      |> check_decoded(LlmCall.Media.Response, "decode_submit/2")
    end
  end

  def generate(client, request, _opts),
    do:
      {:error,
       not_a_client_and_request(client, request, "%LlmCall.Client{}", "%LlmCall.Media.Request{}")}

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

  def poll(%Client{}, %LlmCall.Operation{next_kind: :asset}, _opts) do
    {:error,
     invalid(
       "this operation's next request returns media bytes; use fetch/2",
       :validation
     )}
  end

  def poll(%Client{} = client, %LlmCall.Operation{} = operation, opts) do
    case operation.next do
      %EncodedRequest{} = encoded ->
        poll(client, encoded, opts)

      nil ->
        {:error, invalid("the operation has no next request", :validation)}

      other ->
        {:error, not_a_request(other, "%LlmCall.EncodedRequest{}")}
    end
  end

  def poll(%Client{} = client, %EncodedRequest{} = encoded, opts) do
    with :ok <- validate_call_options(opts, @call_options),
         :ok <- validate_headers(opts[:headers]),
         {:ok, codec} <- fetch_media_codec(client, opts),
         :ok <- require_callback(codec, :decode_operation, 2),
         :ok <- require_callback(codec, :decode_error, 2) do
      client
      |> call_and_decode(
        encoded,
        codec,
        &codec.decode_operation(&1, client.config),
        opts[:headers]
      )
      |> check_decoded(LlmCall.Operation, "decode_operation/2")
    end
  end

  def poll(_client, operation_or_encoded, _opts),
    do:
      {:error,
       not_a_request(operation_or_encoded, "%LlmCall.Operation{} or %LlmCall.EncodedRequest{}")}

  @doc """
  Performs a request the caller already encoded.

  Transport-level: a `2xx` body is JSON-decoded into `body`, anything else is
  `:transport` with the status. Use `complete/3` when you want the codec to decode
  a provider error envelope.
  """
  @spec execute(Client.t(), EncodedRequest.t()) ::
          {:ok, %{status: non_neg_integer(), headers: list(), body: term()}}
          | {:error, Error.t()}
  def execute(%Client{} = client, %EncodedRequest{} = encoded) do
    case perform(client, encoded) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        decode_json_body(client, response)

      {:ok, %{status: status, headers: headers}} ->
        {:error, transport_error("HTTP #{status}", status, HTTP.retry_after_ms(headers))}

      {:error, %Error{}} = error ->
        error
    end
  end

  def execute(_client, encoded),
    do: {:error, not_a_request(encoded, "%LlmCall.EncodedRequest{}")}

  @doc """
  Performs a request and returns the body bytes, without JSON decoding.

  For `Operation.next_kind: :asset`, where the body is media.

  A non-`2xx` status is a `:transport` error carrying the status. Redirects are
  never followed, and `%LlmCall.Error{}` has no header field, so a `3xx` hides
  its `Location`. When you need it — a CDN or pre-signed asset URL that answers
  `302` — build an `%LlmCall.HTTP.Request{}` for the same URL and use
  `LlmCall.HTTP.request/2`, which returns the whole response with headers.
  """
  @spec fetch(Client.t(), EncodedRequest.t() | LlmCall.Operation.t()) ::
          {:ok, %{status: non_neg_integer(), headers: list(), body: binary()}}
          | {:error, Error.t()}
  def fetch(%Client{}, %Operation{next: nil}) do
    {:error, invalid("the operation has no next request", :validation)}
  end

  def fetch(%Client{}, %Operation{next_kind: :poll}) do
    {:error,
     invalid(
       "this operation's next request is a poll; use poll/3",
       :validation
     )}
  end

  def fetch(%Client{} = client, %LlmCall.Operation{next: %EncodedRequest{} = encoded}) do
    fetch(client, encoded)
  end

  def fetch(%Client{} = client, %EncodedRequest{} = encoded) do
    case perform(client, encoded) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %{status: status, headers: headers}} ->
        {:error, transport_error("HTTP #{status}", status, HTTP.retry_after_ms(headers))}

      {:error, %Error{}} = error ->
        error
    end
  end

  def fetch(_client, encoded),
    do: {:error, not_a_request(encoded, "%LlmCall.EncodedRequest{}")}

  defp perform(%Client{} = client, %EncodedRequest{} = encoded, call_headers \\ []) do
    with {:ok, request} <- build_http_request(client, encoded, call_headers) do
      normalize(client, HTTP.request(request, client.http_opts))
    end
  end

  defp build_http_request(
         %Client{} = client,
         %EncodedRequest{method: :get} = encoded,
         call_headers
       ) do
    with {:ok, url} <- url(client, encoded),
         {:ok, headers} <- headers(client, encoded, call_headers) do
      {:ok, HTTP.Request.get(url, headers, client.timeout)}
    end
  end

  defp build_http_request(
         %Client{} = client,
         %EncodedRequest{method: :post} = encoded,
         call_headers
       ) do
    with {:ok, body} <- encode_body(client, encoded.body),
         {:ok, url} <- url(client, encoded),
         {:ok, headers} <- headers(client, encoded, call_headers) do
      {:ok, HTTP.Request.post(url, headers, body, client.timeout)}
    end
  end

  defp build_http_request(_client, %EncodedRequest{method: method}, _call_headers) do
    {:error, invalid("unsupported request method #{inspect(method)}", :validation)}
  end

  defp url(%Client{} = client, %EncodedRequest{} = encoded) do
    with :ok <- validate_path(encoded.path),
         {:ok, query} <- encode_query(Map.merge(client.query, encoded.query)) do
      {:ok, HTTP.build_url(client.base_url, encoded.path, query)}
    end
  end

  defp validate_path(path) when is_binary(path), do: :ok

  defp validate_path(path) do
    {:error, invalid("request path must be a string, got: #{inspect(path)}", :validation)}
  end

  defp headers(%Client{} = client, %EncodedRequest{} = encoded, call_headers) do
    headers = [client.headers, call_headers || [], encoded.headers]

    if Enum.all?(headers, &LlmCall.HTTP.valid_headers?/1) do
      {:ok, HTTP.merge_headers(headers)}
    else
      {:error, invalid("headers: must be a list of {name, value} string tuples", :validation)}
    end
  end

  defp encode_body(_client, nil), do: {:ok, ""}

  defp encode_body(%Client{config: %Config{json: json}}, body) do
    case LlmCall.JSON.encode(json, body) do
      {:ok, encoded} ->
        {:ok, encoded}

      {:error, {:missing_json_encoder, module}} ->
        {:error, invalid(json_module_error(module, "encode"), :validation)}

      {:error, reason} ->
        {:error,
         invalid("request body is not JSON-encodable" <> decoder_reason(reason), :validation)}
    end
  end

  defp json_module_error(module, verb) do
    "the configured JSON module #{inspect(module)} cannot #{verb}; " <>
      "set config :llm_call, json_library: Mod or a client json_library: Mod"
  end

  defp normalize(_client, {:ok, %{status: status, headers: headers, body: body}}) do
    {:ok, %{status: status, headers: headers, body: body}}
  end

  defp normalize(_client, {:error, reason}) do
    {:error, Error.from_transport(reason)}
  end

  defp call_and_decode(%Client{} = client, encoded, codec, decode_fun, call_headers) do
    case perform(client, encoded, call_headers) do
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

  defp decode_failure(%Client{} = client, codec, %{status: status, headers: headers, body: raw}) do
    retry_after = HTTP.retry_after_ms(headers)

    payload =
      case LlmCall.JSON.decode(client.config.json, raw) do
        {:ok, term} -> term
        {:error, _reason} -> nil
      end

    case payload do
      %{} = payload ->
        case codec.decode_error(payload, client.config) do
          %Error{} = error ->
            {:error, with_status(error, status, retry_after)}

          other ->
            {:error,
             invalid(
               "#{inspect(codec)}.decode_error/2 must return a %LlmCall.Error{}, " <>
                 "got: #{inspect(other)}",
               :invalid_response
             )}
        end

      _not_an_object ->
        {:error,
         transport_error("HTTP #{status}: body is not a JSON object", status, retry_after)}
    end
  end

  defp decode_json_body(%Client{config: %Config{json: json}}, %{body: raw} = response) do
    case LlmCall.JSON.decode(json, raw) do
      {:ok, term} ->
        {:ok, %{response | body: term}}

      {:error, {:missing_json_decoder, module}} ->
        {:error, invalid(json_module_error(module, "decode"), :invalid_response)}

      {:error, reason} ->
        {:error,
         invalid(
           "response body is not JSON" <> LlmCall.Excerpt.of(raw) <> decoder_reason(reason),
           :invalid_response
         )}
    end
  end

  defp decoder_reason(%{__exception__: true} = reason), do: " (#{Exception.message(reason)})"
  defp decoder_reason(reason), do: " (#{inspect(reason)})"

  defp validate_headers(headers) do
    if HTTP.valid_headers?(headers) do
      :ok
    else
      {:error, invalid("headers: must be a list of {name, value} string tuples", :validation)}
    end
  end

  defp validate_call_options(opts, allowed) do
    cond do
      not Keyword.keyword?(opts) ->
        {:error, invalid("call options must be a keyword list", :validation)}

      (unknown = Keyword.keys(opts) -- allowed) != [] ->
        {:error,
         invalid(
           "unknown option #{inspect(hd(unknown))}; accepted: #{inspect(allowed)}",
           :validation
         )}

      true ->
        :ok
    end
  end

  defp validate_on_event(nil), do: :ok
  defp validate_on_event(fun) when is_function(fun, 1), do: :ok

  defp validate_on_event(other) do
    {:error, invalid("on_event: must be a 1-arity function, got: #{inspect(other)}", :validation)}
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

  defp encode_query(query) when query == %{}, do: {:ok, nil}

  defp encode_query(query) when is_map(query) do
    {:ok, URI.encode_query(query)}
  rescue
    _error ->
      {:error, invalid("request query must be string-encodable", :validation)}
  end

  defp invalid(message, kind), do: %Error{kind: kind, message: message}

  defp call_encode(codec, function, request, config) do
    case apply(codec, function, [request, config]) do
      {:ok, %EncodedRequest{}} = ok ->
        ok

      {:error, %Error{}} = error ->
        error

      other ->
        {:error,
         invalid(
           "#{inspect(codec)}.#{function}/2 returned #{inspect(other)}, " <>
             "expected {:ok, %LlmCall.EncodedRequest{}} or {:error, %LlmCall.Error{}}",
           :validation
         )}
    end
  end

  defp start_stream_state(codec, request, config) do
    case codec.init_stream(request, config) do
      {:ok, %StreamState{}} = ok ->
        ok

      {:error, %Error{}} = error ->
        error

      other ->
        {:error,
         invalid(
           "#{inspect(codec)}.init_stream/2 returned #{inspect(other)}, " <>
             "expected {:ok, %LlmCall.StreamState{}} or {:error, %LlmCall.Error{}}",
           :validation
         )}
    end
  end

  defp check_decoded({:ok, value}, module, _label) when is_struct(value, module), do: {:ok, value}
  defp check_decoded({:error, %Error{}} = error, _module, _label), do: error

  defp check_decoded(other, module, label) do
    {:error,
     invalid(
       "#{label} returned #{inspect(other)}, expected {:ok, %#{inspect(module)}{}} or " <>
         "{:error, %LlmCall.Error{}}",
       :invalid_response
     )}
  end

  # A non-`2xx` whose body is not the provider's error envelope has no code to
  # classify, so the HTTP status is the only signal. Without this a real 429 or
  # 503 answered by a gateway as HTML or an empty body reported
  # `retryable?: false`, and a caller that follows the hint stops retrying.
  defp transport_error(message, status, retry_after_ms) do
    %Error{
      kind: :transport,
      message: message,
      status: status,
      retryable?: Error.retryable_status?(status),
      retry_after_ms: retry_after_ms
    }
  end

  # The codec decided from the provider's own code, but a code it does not list
  # is not evidence against retrying: a `429` is a `429`. The status is a second
  # signal, so the hint is the union rather than the codec's verdict alone.
  defp with_status(%Error{} = error, status, retry_after_ms) do
    %{
      error
      | status: status,
        retry_after_ms: retry_after_ms,
        retryable?: error.retryable? or Error.retryable_status?(status)
    }
  end

  @doc "Encodes a canonical request into one protocol's wire request."
  @spec encode(module(), LlmCall.Request.t(), Config.t()) ::
          {:ok, LlmCall.EncodedRequest.t()} | {:error, Error.t()}
  def encode(codec, request, config \\ Config.new())

  def encode(codec, %LlmCall.Request{} = request, config) do
    with :ok <- require_callback(codec, :encode_request, 2),
         {:ok, request} <- Tools.normalize_request(request, codec) do
      codec.encode_request(request, config)
    end
  end

  def encode(_codec, request, _config), do: {:error, not_a_request(request, "%LlmCall.Request{}")}

  @doc "Decodes one provider response term into a canonical response."
  @spec decode_response(module(), LlmCall.wire_value(), Config.t()) ::
          {:ok, LlmCall.Response.t()} | {:error, Error.t()}
  def decode_response(codec, term, config \\ Config.new()) do
    with :ok <- require_callback(codec, :decode_response, 2) do
      codec.decode_response(term, config)
    end
  end

  @doc "Normalizes a provider error payload."
  @spec decode_error(module(), LlmCall.wire_value(), Config.t()) ::
          Error.t() | {:error, Error.t()}
  def decode_error(codec, term, config \\ Config.new()) do
    with :ok <- require_callback(codec, :decode_error, 2) do
      codec.decode_error(term, config)
    end
  end

  @doc "Checks a request against the fields a codec can represent."
  @spec validate_request(module(), LlmCall.Request.t(), Config.t()) ::
          :ok | {:error, Error.t()}
  def validate_request(codec, request, config \\ Config.new())

  def validate_request(codec, %LlmCall.Request{} = request, config) do
    with :ok <- require_callback(codec, :encode_request, 2),
         :ok <- require_callback(codec, :validate_request, 2),
         {:ok, request} <- Tools.normalize_request(request, codec) do
      codec.validate_request(request, config)
    end
  end

  def validate_request(_codec, request, _config),
    do: {:error, not_a_request(request, "%LlmCall.Request{}")}

  @doc """
  Describes what a completion codec supports.

  Capabilities are protocol-level, not model-level; see
  `LlmCall.Capabilities`. Returns a typed error when the module implements the
  media behaviour instead.
  """
  @spec capabilities(module(), LlmCall.Request.t(), Config.t()) ::
          {:ok, LlmCall.Capabilities.t()} | {:error, Error.t()}
  def capabilities(codec, request, config \\ Config.new())

  def capabilities(codec, %LlmCall.Request{} = request, config) do
    with :ok <- require_callback(codec, :encode_request, 2),
         :ok <- require_callback(codec, :capabilities, 2) do
      {:ok, codec.capabilities(request, config)}
    end
  end

  def capabilities(_codec, request, _config),
    do: {:error, not_a_request(request, "%LlmCall.Request{}")}

  @doc "Starts a stream, or returns a typed error when the codec has no streaming."
  @spec init_stream(module(), LlmCall.Request.t(), Config.t()) ::
          {:ok, StreamState.t()} | {:error, Error.t()}
  def init_stream(codec, request, config \\ Config.new())

  def init_stream(codec, %LlmCall.Request{} = request, config) do
    with :ok <- require_callback(codec, :init_stream, 2),
         {:ok, request} <- Tools.normalize_request(request, codec) do
      codec.init_stream(request, config)
    end
  end

  def init_stream(_codec, request, _config),
    do: {:error, not_a_request(request, "%LlmCall.Request{}")}

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

  def decode_stream_event(_codec, _term, _config, state),
    do: {:error, not_a_request(state, "%LlmCall.StreamState{}")}

  @doc """
  Flushes whatever the protocol does not emit itself when the stream ends.

  Gemini has no stream terminator, so its accumulated usage and `:message_stop`
  arrive only here. Calling it more than once is safe.
  """
  @spec finish_stream(module(), StreamState.t(), Config.t()) ::
          {:ok, [LlmCall.StreamEvent.t()], StreamState.t()} | {:error, Error.t()}
  def finish_stream(codec, state, config \\ Config.new())

  def finish_stream(codec, %StreamState{} = state, config) do
    with :ok <- require_owner(codec, state),
         :ok <- require_callback(codec, :finish_stream, 2) do
      codec.finish_stream(state, config)
    end
  end

  def finish_stream(_codec, state, _config),
    do: {:error, not_a_request(state, "%LlmCall.StreamState{}")}

  @doc """
  Encodes a media generation request, or starts a long-running job.

  The codec validates first; a knob it cannot express is a typed error.
  """
  @spec encode_media(module(), LlmCall.Media.Request.t(), Config.t()) ::
          {:ok, LlmCall.EncodedRequest.t()} | {:error, Error.t()}
  def encode_media(codec, request, config \\ Config.new())

  def encode_media(codec, %LlmCall.Media.Request{} = request, config) do
    with :ok <- require_callback(codec, :encode_submit, 2) do
      codec.encode_submit(request, config)
    end
  end

  def encode_media(_codec, request, _config),
    do: {:error, not_a_request(request, "%LlmCall.Media.Request{}")}

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
  def validate_media(codec, request, config \\ Config.new())

  def validate_media(codec, %LlmCall.Media.Request{} = request, config) do
    with :ok <- require_callback(codec, :encode_submit, 2),
         :ok <- require_callback(codec, :validate_request, 2) do
      codec.validate_request(request, config)
    end
  end

  def validate_media(_codec, request, _config),
    do: {:error, not_a_request(request, "%LlmCall.Media.Request{}")}

  @doc """
  Describes the media surface a codec declares.

  Returns a typed error when the module implements the completion behaviour
  instead.
  """
  @spec media_capabilities(module(), LlmCall.Media.Request.t(), Config.t()) ::
          {:ok, LlmCall.Media.Capabilities.t()} | {:error, Error.t()}
  def media_capabilities(codec, request, config \\ Config.new())

  def media_capabilities(codec, %LlmCall.Media.Request{} = request, config) do
    with :ok <- require_callback(codec, :encode_submit, 2),
         :ok <- require_callback(codec, :capabilities, 2) do
      {:ok, codec.capabilities(request, config)}
    end
  end

  def media_capabilities(_codec, request, _config),
    do: {:error, not_a_request(request, "%LlmCall.Media.Request{}")}

  defp require_owner(codec, %StreamState{codec: codec}), do: :ok

  defp require_owner(codec, %StreamState{codec: owner}) do
    {:error,
     %Error{
       kind: :validation,
       message: "stream state belongs to #{inspect(owner)}, not #{inspect(codec)}"
     }}
  end

  # The `@spec` promises a tagged error, so a wrong request shape is reported the
  # same way a missing callback is: a caller that builds a request from data does
  # not get a `FunctionClauseError` it cannot handle.
  defp not_a_request(request, expected) do
    %Error{
      kind: :validation,
      message: "expected #{expected}, got: #{inspect(request)}"
    }
  end

  # The top-level calls take a client and a request, so the error has to say which
  # one did not match; naming the request for a bad client would be misleading.
  defp not_a_client_and_request(client, request, client_type, request_type) do
    if is_struct(client, Client),
      do: not_a_request(request, request_type),
      else: not_a_request(client, client_type)
  end

  defp require_callback(codec, function, arity) do
    if Code.ensure_loaded?(codec) and function_exported?(codec, function, arity) do
      :ok
    else
      {:error,
       %Error{
         kind: :validation,
         message: "#{inspect(codec)} does not export #{function}/#{arity}"
       }}
    end
  end
end

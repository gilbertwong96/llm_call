defmodule LlmCall.Stream do
  @moduledoc """
  A lazy `Enumerable` over a streaming call.

  Built by `LlmCall.stream/3`, which has already encoded the request and started
  the codec's stream state, so an invalid request is a tagged error. The HTTP
  request starts when the stream is reduced.

  The struct is an immutable description, not a cursor: reducing it twice issues
  the request twice. Build it once and pass it to one consumer.

  Refer to it as `LlmCall.Stream` rather than `alias`-ing it as `Stream`, which
  would shadow Elixir's `Stream` module for the rest of that module.

  ## Errors

  A `2xx` body's events are yielded as they decode. Everything that fails while
  the body is being read raises `LlmCall.HTTP.Error`: a non-`2xx` status (after the
  error body is decoded by the codec), a payload the JSON module cannot parse, or a
  `{:error, %LlmCall.Error{}}` from `decode_stream_event/3`. An `Enumerable` cannot
  return a tuple at that point.

  A codec that breaks the `LlmCall.Codec` contract is reported the same way, as
  `:invalid_response`: an exception raised from `decode_stream_event/3` or
  `finish_stream/2`, or a return value outside `{:ok, events, state}`,
  `{:done, state}`, and `{:error, %LlmCall.Error{}}`.

  `{:halt, acc}` from the reducer stops the request and closes the connection;
  `finish_stream/2` is not called for a halted consumer. Suspension
  (`{:suspend, acc}`) is not supported and raises.

  ## Telemetry

  Reducing the stream emits `[:llm_call, :stream, :start]`, one `:first_event`, and
  then `:stop` (`outcome: :done | :halted`) or `:exception`; see `LlmCall.Telemetry`.

  ## `on_event`

  `LlmCall.stream/3` accepts `on_event: fun` with `fun :: (StreamEvent.t() -> any())`.
  It runs for every event before the reducer sees it, including events flushed by
  `finish_stream/2`. The return value is ignored: it observes, it cannot filter or
  replace events, and it is not called after the reducer halts. If it raises, an
  `ArgumentError` or `RuntimeError` is reported as a `LlmCall.HTTP.Error` with
  `kind: :transport` and `reason: :exception`, because the hook runs inside the
  transport's own protection; any other exception propagates.
  """

  alias LlmCall.{Error, HTTP, SSE, Telemetry}

  # The client and its resolved request both carry the credential, so `inspect` shows
  # neither: a stream in a log line or a crash report must not print the key.
  @derive {Inspect, except: [:client, :http_request]}
  defstruct [:client, :codec, :model, :http_request, :state, :on_event]

  @type on_event :: (LlmCall.StreamEvent.t() -> any()) | nil

  @type t :: %__MODULE__{
          client: LlmCall.Client.t(),
          codec: module(),
          model: String.t() | nil,
          http_request: HTTP.Request.t(),
          state: LlmCall.StreamState.t(),
          on_event: on_event()
        }

  @doc false
  @spec reduce(t(), term(), (term(), term() -> {:cont, term()} | {:halt, term()})) ::
          {:done, term()} | {:halted, term()}
  def reduce(%__MODULE__{} = stream, acc, fun) when is_function(fun, 2) do
    metadata = Telemetry.metadata(:stream, stream.client.provider, stream.codec, stream.model)
    started = Telemetry.stream_start(metadata)

    state = %{
      client: stream.client,
      codec: stream.codec,
      downstream: tag(acc),
      fun: fun,
      sse: SSE.new(),
      stream_state: stream.state,
      on_event: stream.on_event,
      telemetry: metadata,
      started: started,
      first_event?: false,
      events: 0,
      status: nil,
      headers: [],
      error_body: "",
      error_body_full?: false,
      done?: false,
      halted?: false
    }

    try do
      case HTTP.stream(
             stream.http_request,
             state,
             &handle_event/2,
             stream.client.http_opts
           ) do
        {:ok, state} ->
          finish(state)

        # The reducer's accumulator survived the failure, so a status and the headers of
        # an error response are still there: report them instead of losing a `429` and its
        # `Retry-After` to a connection that died while the error body was being read.
        {:error, _reason, %{status: status} = state}
        when is_integer(status) and status not in 200..299 ->
          raise_http_error(state)

        {:error, reason, _state} ->
          raise HTTP.Error, error: Error.from_transport(reason)

        {:error, reason} ->
          raise HTTP.Error, error: Error.from_transport(reason)
      end
    catch
      kind, reason ->
        Telemetry.stream_exception(metadata, started, kind, reason, __STACKTRACE__)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp handle_event({:status, status}, state), do: {:cont, %{state | status: status}}
  defp handle_event({:headers, headers}, state), do: {:cont, %{state | headers: headers}}

  # The error envelope is a short JSON object; a 5xx answered by a large HTML page
  # should not be buffered in the caller's process.
  @max_error_body 64 * 1024

  defp handle_event({:data, chunk}, %{status: status} = state)
       when is_integer(status) and status not in 200..299 do
    state = %{state | error_body: append_error_body(state.error_body, chunk)}

    # Nothing past the cap can change the outcome, so stop reading rather than
    # waiting for a trickling or endless error body to finish. The outcome is
    # identical either way — the halt bounds how long the caller waits for it, which
    # the test server cannot express (it always terminates the body).
    if byte_size(state.error_body) >= @max_error_body,
      do: {:halt, %{state | error_body_full?: true}},
      else: {:cont, state}
  end

  defp handle_event({:data, chunk}, state) do
    {payloads, sse} = safe_parse_sse(state.sse, chunk)
    state = %{state | sse: sse}

    state =
      Enum.reduce_while(payloads, state, fn payload, state ->
        state = decode_payload(state, payload)

        if state.halted? or state.done?,
          do: {:halt, state},
          else: {:cont, state}
      end)

    if state.halted? or state.done?, do: {:halt, state}, else: {:cont, state}
  end

  defp decode_payload(state, "[DONE]"), do: decode_event(state, "[DONE]")

  defp decode_payload(state, payload) do
    case LlmCall.JSON.decode(state.client.config.json, payload) do
      {:ok, term} ->
        decode_event(state, term)

      {:error, reason} ->
        raise HTTP.Error,
          error:
            invalid_response(
              "stream payload is not JSON" <>
                LlmCall.Excerpt.of(payload) <> decoder_reason(reason)
            )
    end
  end

  # The decoder's own message says why (a truncated fragment, a trailing comma,
  # an unexpected byte), which is what tells a caller whether the stream was cut
  # or the peer answered with something that is not the protocol at all.
  defp decoder_reason({:missing_json_decoder, module}),
    do: " (#{inspect(module)} cannot decode; set config :llm_call, json_library: Mod)"

  defp decoder_reason(%{__exception__: true} = reason), do: " (#{Exception.message(reason)})"
  defp decoder_reason(reason), do: " (#{inspect(reason)})"

  # A framing failure is reported as the stream's own canonical error: a caller of
  # `stream/3` handles `LlmCall.HTTP.Error`, not the parser's internal exception.
  defp append_error_body(body, _chunk) when byte_size(body) >= @max_error_body, do: body

  defp append_error_body(body, chunk) do
    room = @max_error_body - byte_size(body)
    body <> binary_part(chunk, 0, min(byte_size(chunk), room))
  end

  defp safe_parse_sse(sse, chunk) do
    case parse_sse(sse, chunk) do
      {:ok, result} -> result
      {:error, message} -> raise HTTP.Error, error: invalid_response(message)
    end
  end

  defp parse_sse(sse, chunk) do
    {:ok, SSE.parse(sse, chunk)}
  rescue
    error in LlmCall.SSE.Error -> {:error, Exception.message(error)}
  end

  defp decode_event(state, term) do
    case safe_decode_event(state, term) do
      {:ok, events, stream_state} when is_list(events) ->
        state = %{state | stream_state: stream_state}
        yield_all(events, state)

      {:done, stream_state} ->
        state = %{state | stream_state: stream_state}
        state = finish_stream(state)
        %{state | done?: true}

      {:error, %Error{} = error} ->
        raise HTTP.Error, error: error

      other ->
        raise HTTP.Error,
          error: invalid_response("decode_stream_event/3 returned #{inspect(other)}")
    end
  end

  defp safe_decode_event(state, term) do
    state.codec.decode_stream_event(term, state.client.config, state.stream_state)
  rescue
    error ->
      {:error, invalid_response("stream codec raised: #{Exception.message(error)}")}
  end

  defp finish_stream(state) do
    case safe_finish_stream(state) do
      {:ok, events, stream_state} when is_list(events) ->
        state = %{state | stream_state: stream_state}
        yield_all(events, state)

      {:error, %Error{} = error} ->
        raise HTTP.Error, error: error

      other ->
        raise HTTP.Error,
          error: invalid_response("finish_stream/2 returned #{inspect(other)}")
    end
  end

  defp safe_finish_stream(state) do
    state.codec.finish_stream(state.stream_state, state.client.config)
  rescue
    error ->
      {:error, invalid_response("stream finish raised: #{Exception.message(error)}")}
  end

  defp yield_all(_events, %{halted?: true} = state), do: state

  defp yield_all(events, state) do
    Enum.reduce_while(events, state, fn event, state ->
      state = track(state, event)

      case apply_downstream(state.fun, event, state.downstream) do
        {:cont, downstream} -> {:cont, %{state | downstream: downstream}}
        {:halt, downstream} -> {:halt, %{state | downstream: downstream, halted?: true}}
      end
    end)
  end

  defp track(state, event) do
    state = announce_first(%{state | events: state.events + 1})
    observe(state, event)
    state
  end

  defp announce_first(%{first_event?: false} = state) do
    Telemetry.stream_first_event(state.telemetry, state.started)
    %{state | first_event?: true}
  end

  defp announce_first(state), do: state

  defp observe(%{on_event: nil}, _event), do: :ok
  defp observe(%{on_event: fun}, event), do: fun.(event)

  defp apply_downstream(fun, event, {:cont, acc}) do
    case fun.(event, acc) do
      {:cont, acc} -> {:cont, {:cont, acc}}
      {:halt, acc} -> {:halt, {:halt, acc}}
      {:suspend, _acc} -> raise ArgumentError, "suspending a stream is not supported"
    end
  end

  defp apply_downstream(_fun, _event, {:halt, acc}), do: {:halt, {:halt, acc}}

  defp apply_downstream(_fun, _event, {:suspend, _acc}) do
    raise ArgumentError, "suspending a stream is not supported"
  end

  defp tag({:cont, _acc} = tagged), do: tagged
  defp tag({:halt, _acc} = tagged), do: tagged
  defp tag({:suspend, _acc}), do: raise(ArgumentError, "suspending a stream is not supported")
  defp tag(acc), do: {:cont, acc}

  defp untag({:cont, acc}), do: acc
  defp untag({:halt, acc}), do: acc

  # A capped body is truncated by construction, so it can never decode. Say that
  # rather than reporting a body the provider never sent.
  defp error_body_message(status, body) when byte_size(body) >= @max_error_body do
    "HTTP #{status}: error body exceeded #{@max_error_body} bytes and was truncated"
  end

  defp error_body_message(status, _body), do: "HTTP #{status}: body is not a JSON object"

  # `:stop` is emitted around the terminal decision, so a raise — an error status, a codec
  # that breaks the contract — leaves no `:stop` behind: the catch in `reduce/3` reports
  # it as `:exception` instead.
  defp finish(state) do
    {outcome, acc} = finish_result(state)
    Telemetry.stream_stop(state.telemetry, state.started, outcome, state.status, state.events)
    {outcome, acc}
  end

  # The cap halted the read, but the response is still a non-2xx whose error the
  # caller needs, so it is built before the caller-halt case.
  defp finish_result(%{error_body_full?: true} = state), do: raise_http_error(state)

  defp finish_result(%{halted?: true} = state), do: {:halted, untag(state.downstream)}

  defp finish_result(%{status: status} = state)
       when is_integer(status) and status not in 200..299 do
    raise_http_error(state)
  end

  defp finish_result(%{done?: true} = state), do: {:done, untag(state.downstream)}

  defp finish_result(state) do
    {payloads, sse} = SSE.flush(state.sse)
    state = %{state | sse: sse}

    state =
      Enum.reduce_while(payloads, state, fn payload, state ->
        state = decode_payload(state, payload)

        if state.halted? or state.done?,
          do: {:halt, state},
          else: {:cont, state}
      end)

    cond do
      state.halted? -> {:halted, untag(state.downstream)}
      state.done? -> {:done, untag(state.downstream)}
      true -> finish_after_flush(state)
    end
  end

  defp finish_after_flush(state) do
    state = finish_stream(state)

    if state.halted?,
      do: {:halted, untag(state.downstream)},
      else: {:done, untag(state.downstream)}
  end

  defp raise_http_error(%{status: status} = state) do
    error =
      case LlmCall.JSON.decode(state.client.config.json, state.error_body) do
        {:ok, %{} = payload} ->
          stream_error(state.codec.decode_error(payload, state.client.config))

        _other ->
          %Error{kind: :transport, message: error_body_message(status, state.error_body)}
      end

    retry_after = HTTP.retry_after_ms(state.headers)

    # Same union as the non-streaming path: a code the codec does not list is not
    # evidence against retrying, so the status is a second signal.
    raise HTTP.Error,
      error: %{
        error
        | status: status,
          retry_after_ms: retry_after,
          retryable?: error.retryable? or LlmCall.Error.retryable_status?(status)
      }
  end

  defp stream_error(%Error{} = error), do: error

  defp stream_error(other) do
    invalid_response("decode_error/2 must return a %LlmCall.Error{}, got: #{inspect(other)}")
  end

  defp invalid_response(message), do: %Error{kind: :invalid_response, message: message}
end

defimpl Enumerable, for: LlmCall.Stream do
  def reduce(stream, acc, fun), do: LlmCall.Stream.reduce(stream, acc, fun)
  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _element), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}
end

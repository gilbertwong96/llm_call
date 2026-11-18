defmodule LlmCall.Stream do
  @moduledoc """
  A lazy `Enumerable` over a streaming call.

  Built by `LlmCall.stream/3`, which has already encoded the request and started
  the codec's stream state, so an invalid request is a tagged error. The HTTP
  request starts when the stream is reduced.

  The struct is an immutable description, not a cursor: reducing it twice issues
  the request twice. Build it once and pass it to one consumer.

  ## Errors

  A `2xx` body's events are yielded as they decode. Everything that fails while
  the body is being read raises `LlmCall.HTTP.Error`: a non-`2xx` status (after the
  error body is decoded by the codec), a payload the JSON module cannot parse, or a
  `{:error, %LlmCall.Error{}}` from `decode_stream_event/3`. An `Enumerable` cannot
  return a tuple at that point.

  `{:halt, acc}` from the reducer stops the request and closes the connection;
  `finish_stream/2` is not called for a halted consumer. Suspension
  (`{:suspend, acc}`) is not supported and raises.

  ## `on_event`

  `LlmCall.stream/3` accepts `on_event: fun` with `fun :: (StreamEvent.t() -> any())`.
  It runs for every event before the reducer sees it, including events flushed by
  `finish_stream/2`. The return value is ignored: it observes, it cannot filter or
  replace events, and it is not called after the reducer halts. If it raises, the
  exception propagates and the reducer does not see that event.
  """

  alias LlmCall.{Error, HTTP, SSE}

  defstruct [:client, :codec, :http_request, :state, :on_event]

  @type on_event :: (LlmCall.StreamEvent.t() -> any()) | nil

  @type t :: %__MODULE__{
          client: LlmCall.Client.t(),
          codec: module(),
          http_request: HTTP.Request.t(),
          state: LlmCall.StreamState.t(),
          on_event: on_event()
        }

  @doc false
  @spec reduce(t(), term(), (term(), term() -> {:cont, term()} | {:halt, term()})) ::
          {:done, term()} | {:halted, term()}
  def reduce(%__MODULE__{} = stream, acc, fun) when is_function(fun, 2) do
    state = %{
      client: stream.client,
      codec: stream.codec,
      downstream: tag(acc),
      fun: fun,
      sse: SSE.new(),
      stream_state: stream.state,
      on_event: stream.on_event,
      status: nil,
      error_body: "",
      done?: false,
      halted?: false
    }

    case HTTP.stream(
           stream.http_request,
           state,
           &handle_event/2,
           stream.client.http_opts
         ) do
      {:ok, state} -> finish(state)
      {:error, reason} -> raise HTTP.Error, error: transport_error(reason)
    end
  end

  defp handle_event({:status, status}, state), do: {:cont, %{state | status: status}}
  defp handle_event({:headers, _headers}, state), do: {:cont, state}

  defp handle_event({:data, chunk}, %{status: status} = state)
       when is_integer(status) and status not in 200..299 do
    {:cont, %{state | error_body: state.error_body <> chunk}}
  end

  defp handle_event({:data, chunk}, state) do
    {payloads, sse} = SSE.parse(state.sse, chunk)
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
    case state.client.config.json.decode(payload) do
      {:ok, term} -> decode_event(state, term)
      {:error, _reason} -> raise HTTP.Error, error: invalid_response("stream payload is not JSON")
    end
  end

  defp decode_event(state, term) do
    case state.codec.decode_stream_event(term, state.client.config, state.stream_state) do
      {:ok, events, stream_state} ->
        state = %{state | stream_state: stream_state}
        yield_all(events, state)

      {:done, stream_state} ->
        state = %{state | stream_state: stream_state}
        state = finish_stream(state)
        %{state | done?: true}

      {:error, %Error{} = error} ->
        raise HTTP.Error, error: error
    end
  end

  defp finish_stream(state) do
    case state.codec.finish_stream(state.stream_state, state.client.config) do
      {:ok, events, stream_state} ->
        state = %{state | stream_state: stream_state}
        yield_all(events, state)

      {:error, %Error{} = error} ->
        raise HTTP.Error, error: error
    end
  end

  defp yield_all(_events, %{halted?: true} = state), do: state

  defp yield_all(events, state) do
    Enum.reduce_while(events, state, fn event, state ->
      observe(state, event)

      case apply_downstream(state.fun, event, state.downstream) do
        {:cont, downstream} -> {:cont, %{state | downstream: downstream}}
        {:halt, downstream} -> {:halt, %{state | downstream: downstream, halted?: true}}
      end
    end)
  end

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

  defp finish(%{halted?: true} = state), do: {:halted, untag(state.downstream)}

  defp finish(%{status: status} = state) when is_integer(status) and status not in 200..299 do
    error =
      case state.client.config.json.decode(state.error_body) do
        {:ok, %{} = payload} ->
          stream_error(state.codec.decode_error(payload, state.client.config))

        _other ->
          transport_error("HTTP #{status}: body is not a JSON object")
      end

    raise HTTP.Error, error: %{error | status: status}
  end

  defp finish(%{done?: true} = state), do: {:done, untag(state.downstream)}

  defp finish(state) do
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

  defp stream_error(%Error{} = error), do: error

  defp stream_error(other) do
    invalid_response("decode_error/2 must return a %LlmCall.Error{}, got: #{inspect(other)}")
  end

  defp invalid_response(message), do: %Error{kind: :invalid_response, message: message}

  defp transport_error(reason) do
    %Error{kind: :transport, message: "transport error: #{inspect(reason)}"}
  end
end

defimpl Enumerable, for: LlmCall.Stream do
  def reduce(stream, acc, fun), do: LlmCall.Stream.reduce(stream, acc, fun)
  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _element), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}
end

defmodule LlmCall.Telemetry do
  @moduledoc """
  The telemetry events `LlmCall` emits.

  The library emits and attaches no handler: there is no reporter, no metrics
  backend and no default `Logger` output, so the cost is zero until a host calls
  `:telemetry.attach_many/4`.

  Events cover the calls that decode a provider response — `LlmCall.complete/3`,
  `stream/3`, `generate/3` and `poll/3`. A call that fails before the request is
  built (a `:validation` error from `validate_request/2` or `encode_request/2`)
  emits nothing: no request was made, and the caller already holds the error.
  `LlmCall.execute/2` and `fetch/2` emit nothing here either: they are Finch
  requests with a JSON body, already covered by
  `[:finch, :request, :start | :stop | :exception]`.

  Every event carries the same four metadata keys: `operation` (`:complete`,
  `:stream`, `:generate`, `:poll`), `provider`, `codec`, and `model` (`nil` for a
  call that has no `%LlmCall.Request{}`, such as `poll/3`).

  ## `[:llm_call, :request, ...]`

    * `:start` — metadata as above, measurements `%{system_time: integer}`.
    * `:stop` — measurements `%{duration: :native}` plus the `LlmCall.Usage` token
      counts the provider reported. A count that is `nil` is **omitted**, never
      zero: "not reported" and "reported zero" are different facts. Metadata adds
      `outcome: :ok` and `stop_reason`, or `outcome: :error` and `error_kind`,
      `status`, `retryable`, `retry_after_ms`.
    * `:exception` — measurements `%{duration: :native}`; metadata adds `kind`,
      `reason` and `stacktrace`. Emitted instead of `:stop` when the call raises,
      and the raise still reaches the caller.

  ## `[:llm_call, :stream, ...]`

    * `:start` — emitted when the stream is **reduced**, not when it is built:
      building a stream issues no request.
    * `:first_event` — measurements `%{duration: :native}`, the time to the first
      event. Emitted once, on the first event yielded; a stream that yields none
      does not emit it.
    * `:first_text` — the same measurements, on the first `:text_delta` instead.
      This is the time to the first token a caller can see: a `:message_start` or
      a `:thinking_delta` does not count, so a stream that only emits those has no
      `:first_text`. `first_text - first_event` is the provider's skeleton-frame
      overhead, which is what separates "the provider is slow" from "the network
      is slow".
    * `:stop` — measurements `%{duration: :native}`; metadata adds
      `outcome: :done | :halted`, `status` and `events` (the count yielded).
    * `:exception` — as for a request.

  A stream that is built and never reduced emits nothing, and one whose consumer
  dies mid-read emits `:start` with no terminal event.

  ## What metadata never carries

  No header, no request or response body, no message and no delta. See
  `docs/design.md` §26.2: an `Inspect` exception can stay in a log, and telemetry
  metadata ends up in a third-party tracing backend.
  """

  alias LlmCall.{Error, Response, Usage}

  @request [:llm_call, :request]
  @stream [:llm_call, :stream]

  @usage_fields [
    :input_tokens,
    :output_tokens,
    :total_tokens,
    :cache_read_tokens,
    :cache_write_tokens,
    :reasoning_tokens
  ]

  @type operation :: :complete | :stream | :generate | :poll

  @type metadata :: %{
          operation: operation(),
          provider: module(),
          codec: module() | nil,
          model: String.t() | nil
        }

  @type result :: {:ok, term()} | {:error, Error.t()}

  @doc false
  # The only place the metadata whitelist is built, so a call site cannot add a
  # key by accident.
  @spec metadata(operation(), module(), module() | nil, String.t() | nil) :: metadata()
  def metadata(operation, provider, codec, model) do
    %{operation: operation, provider: provider, codec: codec, model: model}
  end

  @doc false
  @spec span(metadata(), (-> result())) :: result()
  def span(%{} = metadata, fun) when is_function(fun, 0) do
    started = System.monotonic_time()
    :telemetry.execute(@request ++ [:start], %{system_time: System.system_time()}, metadata)

    try do
      result = fun.()
      {measurements, outcome} = stop_metadata(result)

      :telemetry.execute(
        @request ++ [:stop],
        Map.put(measurements, :duration, elapsed(started)),
        Map.merge(metadata, outcome)
      )

      result
    catch
      kind, reason ->
        emit_exception(@request, metadata, started, kind, reason, __STACKTRACE__)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc false
  @spec stream_start(metadata()) :: integer()
  def stream_start(%{} = metadata) do
    started = System.monotonic_time()
    :telemetry.execute(@stream ++ [:start], %{system_time: System.system_time()}, metadata)
    started
  end

  @doc false
  @spec stream_first_event(metadata(), integer()) :: :ok
  def stream_first_event(%{} = metadata, started) do
    :telemetry.execute(@stream ++ [:first_event], %{duration: elapsed(started)}, metadata)
  end

  @doc false
  @spec stream_first_text(metadata(), integer()) :: :ok
  def stream_first_text(%{} = metadata, started) do
    :telemetry.execute(@stream ++ [:first_text], %{duration: elapsed(started)}, metadata)
  end

  @doc false
  @spec stream_stop(
          metadata(),
          integer(),
          :done | :halted,
          non_neg_integer() | nil,
          non_neg_integer()
        ) ::
          :ok
  def stream_stop(%{} = metadata, started, outcome, status, events) do
    :telemetry.execute(
      @stream ++ [:stop],
      %{duration: elapsed(started)},
      Map.merge(metadata, %{outcome: outcome, status: status, events: events})
    )
  end

  @doc false
  @spec stream_exception(metadata(), integer(), atom(), term(), Exception.stacktrace()) :: :ok
  def stream_exception(%{} = metadata, started, kind, reason, stacktrace) do
    emit_exception(@stream, metadata, started, kind, reason, stacktrace)
  end

  defp emit_exception(prefix, metadata, started, kind, reason, stacktrace) do
    :telemetry.execute(
      prefix ++ [:exception],
      %{duration: elapsed(started)},
      Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})
    )
  end

  defp stop_metadata({:ok, %Response{usage: usage, stop_reason: stop_reason}}) do
    {usage_measurements(usage), %{outcome: :ok, stop_reason: stop_reason}}
  end

  defp stop_metadata({:ok, _result}), do: {%{}, %{outcome: :ok}}

  defp stop_metadata({:error, %Error{} = error}) do
    {%{},
     %{
       outcome: :error,
       error_kind: error.kind,
       status: error.status,
       retryable: error.retryable?,
       retry_after_ms: error.retry_after_ms
     }}
  end

  defp usage_measurements(%Usage{} = usage) do
    Enum.reduce(@usage_fields, %{}, fn field, acc ->
      case Map.get(usage, field) do
        nil -> acc
        count -> Map.put(acc, field, count)
      end
    end)
  end

  defp usage_measurements(nil), do: %{}

  defp elapsed(started), do: System.monotonic_time() - started
end

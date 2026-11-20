defmodule LlmCall.Protocol.OpenAI.Responses.Connection.Stream do
  @moduledoc """
  The lazy `Enumerable` over one Responses WebSocket lane.

  Returned by `LlmCall.Protocol.OpenAI.Responses.Connection.create/3`. Events are
  `LlmCall.StreamEvent` structs, decoded by the Responses codec. A connection
  failure raises `LlmCall.WS.Error`; `{:halt, acc}` stops receiving
  and unsubscribes the lane.
  """

  defstruct [:connection, :stream_id, :ref, :subscriber]

  @type t :: %__MODULE__{
          connection: GenServer.server(),
          stream_id: String.t(),
          ref: reference(),
          subscriber: pid()
        }
end

defimpl Enumerable, for: LlmCall.Protocol.OpenAI.Responses.Connection.Stream do
  alias LlmCall.{Error, WS}

  def reduce(stream, acc, fun) do
    if self() != stream.subscriber do
      raise ArgumentError,
            "a Responses connection stream must be reduced by the process that created it"
    end

    monitor = Process.monitor(stream.connection)

    try do
      do_reduce(stream, monitor, untag(acc), fun)
    after
      Process.demonitor(monitor, [:flush])
    end
  end

  def count(_stream), do: {:error, __MODULE__}
  def member?(_stream, _element), do: {:error, __MODULE__}
  def slice(_stream), do: {:error, __MODULE__}

  defp do_reduce(stream, monitor, acc, fun) do
    receive do
      {:responses_ws, ref, {:event, event}} when ref == stream.ref ->
        case fun.(event, acc) do
          {:cont, acc} ->
            do_reduce(stream, monitor, acc, fun)

          {:halt, acc} ->
            GenServer.cast(stream.connection, {:unsubscribe, stream.ref})
            {:halted, acc}

          {:suspend, _acc} ->
            raise ArgumentError, "suspending a stream is not supported"
        end

      {:responses_ws, ref, :done} when ref == stream.ref ->
        {:done, acc}

      {:responses_ws, ref, {:error, error}} when ref == stream.ref ->
        raise WS.Error, error: error

      {:DOWN, ^monitor, :process, _pid, reason} ->
        raise WS.Error, error: connection_error(reason)
    end
  end

  defp untag({:cont, acc}), do: acc
  defp untag({:halt, acc}), do: acc
  defp untag({:suspend, _acc}), do: raise(ArgumentError, "suspending a stream is not supported")
  defp untag(acc), do: acc

  defp connection_error(:normal) do
    %Error{kind: :transport, message: "responses connection closed", reason: :disconnected}
  end

  defp connection_error(reason) do
    %Error{
      kind: :transport,
      message: "responses connection exited: #{inspect(reason)}",
      reason: {:connection_exited, reason}
    }
  end
end

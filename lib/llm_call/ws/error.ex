defmodule LlmCall.WS.Error do
  @moduledoc """
  Raised by a WebSocket stream when the session or the connection fails.

  An `Enumerable` cannot return a tuple, so the canonical error is carried on the
  exception and read back with `error/1`.
  """

  defexception [:error]

  @type t :: %__MODULE__{error: term()}

  @impl true
  def message(%{error: %LlmCall.Error{message: message}}), do: message
  def message(%{error: reason}), do: "WebSocket error: #{inspect(reason)}"

  @doc "The wrapped value, usually a `%LlmCall.Error{}`."
  @spec error(t()) :: term()
  def error(%__MODULE__{error: error}), do: error
end

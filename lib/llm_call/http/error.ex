defmodule LlmCall.HTTP.Error do
  @moduledoc """
  Raised when a streaming call fails after `LlmCall.stream/3` has returned.

  An `Enumerable` cannot return a tagged tuple, so a non-`2xx` response, an
  unparseable payload, or a provider error event raises this exception with the
  decoded `%LlmCall.Error{}` in `:error`.

  Use `LlmCall.complete/3` for a tuple-returning call, or rescue this exception
  and read `error/1`.
  """

  defexception [:error]

  @type t :: %__MODULE__{error: LlmCall.Error.t()}

  @impl true
  def message(%__MODULE__{error: %LlmCall.Error{message: message}}), do: message
  def message(%__MODULE__{}), do: "streaming call failed"

  @doc "The canonical error carried by the exception."
  @spec error(t()) :: LlmCall.Error.t()
  def error(%__MODULE__{error: error}), do: error
end

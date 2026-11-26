defmodule LlmCall.EventStream.Error do
  @moduledoc """
  Raised when an event-stream body cannot be framed.

  `LlmCall.EventStream.parse/2` returns messages rather than a result tuple, so a
  frame with a bad checksum, an impossible length or an unknown header type raises
  instead of returning an error. `LlmCall.Stream` turns this into an
  `LlmCall.HTTP.Error` carrying an `:invalid_response` canonical error.
  """

  defexception [:message]

  @type t :: %__MODULE__{message: String.t()}
end

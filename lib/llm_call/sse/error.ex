defmodule LlmCall.SSE.Error do
  @moduledoc """
  Raised when an SSE stream cannot be framed.

  `LlmCall.SSE.parse/2` returns payloads rather than a result tuple, so a stream
  whose pending event exceeds the buffer cap raises instead of returning an
  error. `LlmCall.Stream` turns this into an `LlmCall.HTTP.Error` carrying a
  `:invalid_response` canonical error.
  """

  defexception [:message]

  @type t :: %__MODULE__{message: String.t()}
end

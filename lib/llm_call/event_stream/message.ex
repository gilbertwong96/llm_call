defmodule LlmCall.EventStream.Message do
  @moduledoc """
  One framed message: its decoded headers and its payload bytes.

  The payload is not decoded: framing does not know whether it holds JSON, a nested
  event stream, or bytes a provider asked to keep raw.

  ## Header values

  `headers` maps a header name to the value its type carries:

    * `boolean`, `byte`, `short`, `integer`, `long`, `timestamp` — `true`, `false`,
      or an integer. A timestamp is milliseconds since the epoch, as the wire has
      it; this module does not turn it into a `DateTime`.
    * `string` — a UTF-8 `String.t()`; an invalid encoding is a framed-body error,
      not a binary handed out as a string.
    * `binary`, `uuid` — bytes, verbatim. A UUID stays its 16 bytes rather than a
      formatted string, because the type is the only thing that distinguishes it
      from a `binary` header, and no LLM protocol here uses one.
  """

  @type header_value :: boolean() | integer() | String.t() | binary()

  @type t :: %__MODULE__{
          headers: %{optional(String.t()) => header_value()},
          payload: binary()
        }

  defstruct headers: %{}, payload: ""
end

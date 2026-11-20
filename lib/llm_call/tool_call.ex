defmodule LlmCall.ToolCall do
  @moduledoc """
  A call the model asked for.

  `raw_arguments` is the lossless wire projection. When it is present,
  `arguments` is its decoded value; when decoding fails, `arguments` is `nil` and
  `arguments_error` explains why. `id` is `nil` for providers that identify a
  call by name only.
  """

  @type arguments :: map() | nil

  @typedoc """
  Why `arguments` is `nil`.

  `raw_arguments` always carries the payload itself, so this field only says
  what went wrong: `{:invalid_json, reason}` when the payload is not decodable
  JSON (or not an object), and `:no_json_decoder` when
  `LlmCall.StreamAssembler` was built without a `json_decoder:`.
  """
  @type arguments_error :: nil | {:invalid_json, String.t()} | :no_json_decoder

  @type t :: %__MODULE__{
          id: String.t() | nil,
          name: String.t() | nil,
          arguments: arguments(),
          raw_arguments: String.t() | nil,
          arguments_error: arguments_error(),
          index: non_neg_integer() | nil
        }

  defstruct id: nil,
            name: nil,
            arguments: nil,
            raw_arguments: nil,
            arguments_error: nil,
            index: nil
end

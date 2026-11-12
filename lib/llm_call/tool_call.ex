defmodule LlmCall.ToolCall do
  @moduledoc """
  A call the model asked for.

  `raw_arguments` is the lossless wire projection. When it is present,
  `arguments` is its decoded value; when decoding fails, `arguments` is `nil` and
  `arguments_error` explains why. `id` is `nil` for providers that identify a
  call by name only.
  """

  @type arguments :: map() | nil

  @type arguments_error :: nil | {:invalid_json, String.t()}

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

defmodule LlmCall.ToolSpec do
  @moduledoc """
  A tool the model may call.

  `parameters` is a JSON Schema object, not a JSON string. `kind: :builtin` is
  for provider-defined tools such as web search or code interpreter, whose
  native definition lives in `provider_options`.
  """

  @type kind :: :function | :builtin

  @type t :: %__MODULE__{
          kind: kind(),
          name: String.t() | nil,
          description: String.t() | nil,
          parameters: map() | nil,
          strict: boolean() | nil,
          provider_options: map()
        }

  defstruct kind: :function,
            name: nil,
            description: nil,
            parameters: nil,
            strict: nil,
            provider_options: %{}
end

defmodule LlmCall.ToolSpec do
  @moduledoc """
  A tool the model may call.

  `parameters` is a JSON Schema object, not a JSON string, and must already be
  in the selected codec's dialect. The Gemini codec validates its OpenAPI subset
  and returns a `:validation` error for constructs it cannot send, such as a
  lowercase `type`, `additionalProperties`, `$ref`/`$defs`, `prefixItems`,
  `oneOf`, `const`, `allOf` or `not`. `kind: :builtin` is for provider-defined
  tools such as web search or code interpreter, whose native definition lives in
  `provider_options`.

  `strict` is optional and codec-specific. OpenAI's requirement that a strict
  schema be closed cannot be checked from the rendered map, so a mismatch remains
  a provider error; Gemini rejects `strict` because it has no per-tool flag.
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

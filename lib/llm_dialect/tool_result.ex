defmodule LlmDialect.ToolResult do
  @moduledoc """
  The result of a tool call, ready to send back to the model.

  Adapters validate the identifier they need: some protocols require `call_id`,
  others (`Gemini`) require `name`. Content is text-only — no protocol carries a
  non-text tool result — so a wider type would promise what validation refuses.
  """

  @type content :: [LlmDialect.Content.Text.t()] | String.t()

  @type t :: %__MODULE__{
          call_id: String.t() | nil,
          name: String.t() | nil,
          content: content(),
          is_error: boolean()
        }

  defstruct call_id: nil, name: nil, content: [], is_error: false
end

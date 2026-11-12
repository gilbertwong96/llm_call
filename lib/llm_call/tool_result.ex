defmodule LlmCall.ToolResult do
  @moduledoc """
  The result of a tool call, ready to send back to the model.

  Adapters validate the identifier they need: some protocols require `call_id`,
  others (`Gemini`) require `name`.
  """

  @type content :: [LlmCall.Content.part()] | String.t()

  @type t :: %__MODULE__{
          call_id: String.t() | nil,
          name: String.t() | nil,
          content: content(),
          is_error: boolean()
        }

  defstruct call_id: nil, name: nil, content: [], is_error: false
end

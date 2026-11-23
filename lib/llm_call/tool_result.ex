defmodule LlmCall.ToolResult do
  @moduledoc """
  The result of a tool call, ready to send back to the model.

  Adapters validate the identifier they need: some protocols require `call_id`,
  others (`Gemini`) require `name`. Content is text-only — no protocol carries a
  non-text tool result — so a wider type would promise what validation refuses.

  `is_error` is carried where the protocol has a field for it: Anthropic's
  `is_error` and Gemini's `error` key. OpenAI Chat and Responses have no error flag
  on a tool result, so they send the content and drop the flag; that is the one
  drop `docs/design.md` §8.1 records for this struct. Put the failure in the
  content text on those two codecs.
  """

  @type content :: [LlmCall.Content.Text.t()] | String.t()

  @type t :: %__MODULE__{
          call_id: String.t() | nil,
          name: String.t() | nil,
          content: content(),
          is_error: boolean()
        }

  defstruct call_id: nil, name: nil, content: [], is_error: false
end

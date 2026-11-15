defmodule LlmDialect.Message do
  @moduledoc """
  One user or assistant turn.

  Tool results are content parts inside a user turn, not a `:tool` role; adapters
  translate them into the provider's own tool-result form.
  """

  @type role :: :user | :assistant

  @type t :: %__MODULE__{role: role(), content: [LlmDialect.Content.part()]}

  defstruct role: :user, content: []
end

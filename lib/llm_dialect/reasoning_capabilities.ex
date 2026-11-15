defmodule LlmDialect.ReasoningCapabilities do
  @moduledoc """
  The reasoning surface a codec and model accept.
  """

  @type t :: %__MODULE__{
          supported: boolean(),
          efforts: [LlmDialect.Reasoning.level()],
          default_effort: LlmDialect.Reasoning.level() | nil,
          budget_tokens: boolean(),
          adaptive: boolean(),
          summary: [:none | :auto | :concise | :detailed]
        }

  defstruct supported: false,
            efforts: [],
            default_effort: nil,
            budget_tokens: false,
            adaptive: false,
            summary: []
end

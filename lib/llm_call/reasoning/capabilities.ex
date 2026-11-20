defmodule LlmCall.Reasoning.Capabilities do
  @moduledoc """
  The reasoning surface a codec and model accept.
  """

  @type t :: %__MODULE__{
          supported: boolean(),
          efforts: [LlmCall.Reasoning.level()],
          default_effort: LlmCall.Reasoning.level() | nil,
          budget_tokens: boolean(),
          adaptive: boolean(),
          summary: [:auto | :concise | :detailed]
        }

  defstruct supported: false,
            efforts: [],
            default_effort: nil,
            budget_tokens: false,
            adaptive: false,
            summary: []
end

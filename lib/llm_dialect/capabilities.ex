defmodule LlmDialect.Capabilities do
  @moduledoc """
  What a completion protocol supports.

  Capabilities are explicit so unsupported canonical fields can be rejected
  before a transport sends anything, instead of being dropped silently.

  They are **protocol-level**: `capabilities/2` takes the request for signature
  symmetry but does not inspect the model. A model-specific limit surfaces as a
  provider error, not a fabricated local guess.
  """

  @type t :: %__MODULE__{
          tools: boolean(),
          parallel_tool_calls: boolean(),
          tool_choice: boolean(),
          structured_output: :none | :json_object | :json_schema,
          modalities: [LlmDialect.modality()],
          image_input: boolean(),
          file_input: boolean(),
          reasoning: LlmDialect.ReasoningCapabilities.t() | nil,
          streaming_tool_calls: boolean(),
          prompt_cache: boolean(),
          stateful: boolean(),
          streaming: boolean()
        }

  defstruct tools: false,
            parallel_tool_calls: false,
            tool_choice: false,
            structured_output: :none,
            modalities: [:text],
            image_input: false,
            file_input: false,
            reasoning: nil,
            streaming_tool_calls: false,
            prompt_cache: false,
            stateful: false,
            streaming: false
end

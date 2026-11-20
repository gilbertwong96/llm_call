defmodule LlmCall.Capabilities do
  @moduledoc """
  What a completion protocol supports.

  Capabilities are explicit so unsupported canonical fields can be rejected
  before a transport sends anything, instead of being dropped silently.

  `builtin_tools` declares provider-hosted tools (web search, grounding, server
  tools): `false` rejects them, `:passthrough` forwards any name the caller
  supplies, and a list forwards only those names. The library never interprets a
  hosted tool's name; it is the provider's own identifier.

  They are **protocol-level**: `capabilities/2` takes the request for signature
  symmetry but does not inspect the model. A model-specific limit surfaces as a
  provider error, not a fabricated local guess.
  """

  @type t :: %__MODULE__{
          tools: boolean(),
          builtin_tools: false | :passthrough | [String.t()],
          parallel_tool_calls: boolean(),
          tool_choice: boolean(),
          structured_output: :none | :json_object | :json_schema,
          modalities: [LlmCall.modality()],
          image_input: boolean(),
          file_input: boolean(),
          reasoning: LlmCall.Reasoning.Capabilities.t() | nil,
          streaming_tool_calls: boolean(),
          prompt_cache: boolean(),
          stateful: boolean(),
          streaming: boolean()
        }

  defstruct tools: false,
            builtin_tools: false,
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

defmodule LlmCall.Capabilities do
  @moduledoc """
  What a codec supports for the model in the request.

  Capabilities are explicit so unsupported canonical fields can be rejected
  before a transport sends anything, instead of being dropped silently.
  """

  @type t :: %__MODULE__{
          tools: boolean(),
          parallel_tool_calls: boolean(),
          tool_choice: boolean(),
          structured_output: :none | :json_object | :json_schema,
          image_input: boolean(),
          file_input: boolean(),
          reasoning: LlmCall.ReasoningCapabilities.t() | nil,
          streaming_tool_calls: boolean(),
          prompt_cache: boolean(),
          stateful: boolean(),
          streaming: boolean()
        }

  defstruct tools: false,
            parallel_tool_calls: false,
            tool_choice: false,
            structured_output: :none,
            image_input: false,
            file_input: false,
            reasoning: nil,
            streaming_tool_calls: false,
            prompt_cache: false,
            stateful: false,
            streaming: false
end

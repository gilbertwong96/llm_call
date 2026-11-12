defmodule LlmCall.Request do
  @moduledoc """
  A provider-neutral completion request.

  `system` stays here rather than becoming a message because providers place it
  differently (leading message, top-level field, or instruction field).

  `provider_options` is keyed by provider namespace and is for features the
  canonical layer cannot express. `params` covers the sampling and length
  controls providers share.
  """

  @type system :: nil | String.t() | [LlmCall.Content.part()]

  @type tool_choice ::
          :auto
          | :none
          | :required
          | {:tool, String.t()}
          | {:allowed, [String.t()]}

  @type output ::
          :text
          | :json_object
          | {:json_schema, String.t(), map(), boolean() | nil}

  @type params :: %{
          optional(atom()) => nil | boolean() | number() | String.t() | [String.t()]
        }

  @type t :: %__MODULE__{
          model: String.t(),
          system: system(),
          messages: [LlmCall.Message.t()],
          tools: [LlmCall.ToolSpec.t()],
          tool_choice: tool_choice(),
          output: output(),
          reasoning: LlmCall.Reasoning.t() | nil,
          params: params(),
          provider_options: map(),
          stream: boolean()
        }

  defstruct model: nil,
            system: nil,
            messages: [],
            tools: [],
            tool_choice: :auto,
            output: :text,
            reasoning: nil,
            params: %{},
            provider_options: %{},
            stream: false
end

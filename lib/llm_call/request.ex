defmodule LlmCall.Request do
  @moduledoc """
  A provider-neutral completion request.

  `system` stays here rather than becoming a message because providers place it
  differently (leading message, top-level field, or instruction field). It is
  text-only: no protocol accepts a non-text system block, so a wider type would
  promise what validation refuses.

  `provider_options` is keyed by provider namespace and is for features the
  canonical layer cannot express. `params` covers the sampling and length
  controls providers share.
  """

  @type system :: nil | String.t() | [LlmCall.Content.Text.t()]

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

  @type modalities :: [LlmCall.modality()]

  @typedoc """
  A tool entry: a canonical spec, a `ToolCall` module, or `{module, opts}`.

  A module expands to one `LlmCall.ToolSpec` per declared tool when the request
  is encoded, with the schema projected for the codec's protocol. Callers that
  already hold specs pass them unchanged.
  """
  @type tool_entry :: LlmCall.ToolSpec.t() | module() | {module(), keyword()}

  @type params :: %{
          optional(atom()) => nil | boolean() | number() | String.t() | [String.t()]
        }

  @type t :: %__MODULE__{
          model: String.t(),
          system: system(),
          messages: [LlmCall.Message.t()],
          tools: [tool_entry()],
          tool_choice: tool_choice(),
          output: output(),
          modalities: modalities(),
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
            modalities: [:text],
            reasoning: nil,
            params: %{},
            provider_options: %{},
            stream: false
end

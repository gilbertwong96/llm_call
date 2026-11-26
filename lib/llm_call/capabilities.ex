defmodule LlmCall.Capabilities do
  @moduledoc """
  What a completion protocol supports.

  Capabilities are explicit so unsupported canonical fields can be rejected
  before a transport sends anything, instead of being dropped silently.

  `builtin_tools` declares provider-hosted tools (web search, grounding, server
  tools): `false` rejects them, `:passthrough` forwards any name the caller
  supplies, and a list forwards only those names. The library does not validate a hosted
  tool against a local schema; the identifier stays the provider's. A codec still
  maps it into its own tool shape — Anthropic sends the name as `type` and derives a
  callable `name` from a `_YYYYMMDD` suffix — so "verbatim" is not a promise.

  They are **protocol-level**: `capabilities/2` takes the request for signature
  symmetry but does not inspect the model. A model-specific limit surfaces as a
  provider error, not a fabricated local guess.

  ## Reporting versus controlling

  `prompt_cache` says the protocol **reports** cache accounting: `Usage` carries
  `cache_read_tokens` and `cache_write_tokens`. It does not say the canonical IR
  can **place** a cache breakpoint, because it cannot; there is no request field
  for one. All four reference codecs report the read counter; OpenAI Chat,
  OpenAI Responses and Anthropic also report writes, and Gemini does not, so
  `cache_write_tokens` stays `nil` there. Every one declares this `true`.

  The same distinction applies to `stateful`: it says the protocol can continue a
  conversation server-side, which reaches a provider that offers it through
  `provider_options` (`previous_response_id`, `store`), not through a canonical
  field.
  """

  @typedoc """
  What a protocol supports.

  `prompt_cache` is a reporting capability, not a request one: see the
  "Reporting versus controlling" section.

  `image_input` and `file_input` name the source kinds the codec accepts — see
  `LlmCall.Capabilities.Input`.
  """
  @type t :: %__MODULE__{
          tools: boolean(),
          builtin_tools: false | :passthrough | [String.t()],
          parallel_tool_calls: boolean(),
          tool_choice: boolean(),
          structured_output: :none | :json_object | :json_schema,
          modalities: [LlmCall.modality()],
          image_input: LlmCall.Capabilities.Input.t(),
          file_input: LlmCall.Capabilities.Input.t(),
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
            image_input: %LlmCall.Capabilities.Input{},
            file_input: %LlmCall.Capabilities.Input{},
            reasoning: nil,
            streaming_tool_calls: false,
            prompt_cache: false,
            stateful: false,
            streaming: false
end

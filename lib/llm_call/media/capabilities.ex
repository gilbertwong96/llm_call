defmodule LlmCall.Media.Capabilities do
  @moduledoc """
  The media surface a codec declares.

  List-valued fields enumerate accepted values: `sizes: []` means no `size` is
  accepted, and `max_n: :unsupported` means no `n` is accepted. A request knob
  left `nil` means "provider default" and is always accepted.

  `max_references: nil` means no reference is accepted; an integer is the number
  the endpoint takes (Seedance's first/last frame pair is `2`, MiniMax's first
  frame is `1`). Declarations are static per codec, because the core has no model
  catalog; a model-specific limit the codec cannot know surfaces as a provider
  error.
  """

  @type t :: %__MODULE__{
          modalities: [LlmCall.Media.Request.modality()],
          async: boolean(),
          max_n: pos_integer() | :unsupported,
          sizes: [String.t()],
          aspect_ratios: [String.t()],
          durations_s: [pos_integer()],
          max_references: non_neg_integer() | nil,
          seed: boolean(),
          negative_prompt: boolean()
        }

  defstruct modalities: [],
            async: false,
            max_n: :unsupported,
            sizes: [],
            aspect_ratios: [],
            durations_s: [],
            max_references: nil,
            seed: false,
            negative_prompt: false
end

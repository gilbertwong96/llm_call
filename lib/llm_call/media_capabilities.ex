defmodule LlmCall.MediaCapabilities do
  @moduledoc """
  The media surface a codec declares.

  List-valued fields enumerate accepted values: `sizes: []` means no `size` is
  accepted. A request knob left `nil` means "provider default" and is always
  accepted. Declarations are static per codec, because the core has no model
  catalog; a model-specific limit the codec cannot know surfaces as a provider
  error.
  """

  @type t :: %__MODULE__{
          modalities: [:image] | [:video],
          async: boolean(),
          max_n: pos_integer() | nil,
          sizes: [String.t()],
          aspect_ratios: [String.t()],
          durations_s: [pos_integer()],
          references: boolean(),
          seed: boolean(),
          negative_prompt: boolean()
        }

  defstruct modalities: [],
            async: false,
            max_n: nil,
            sizes: [],
            aspect_ratios: [],
            durations_s: [],
            references: false,
            seed: false,
            negative_prompt: false
end

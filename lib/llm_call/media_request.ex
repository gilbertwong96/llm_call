defmodule LlmCall.MediaRequest do
  @moduledoc """
  A provider-neutral image or video generation request.

  This is a separate request from `LlmCall.Request` on purpose: dedicated media
  endpoints take a prompt and media parameters, not messages, a system prompt, or
  tools. Flattening a completion request into `{prompt, n, size}` would be a hidden
  convention.

  `references` are images or videos the generation is conditioned on. Only
  content a JSON body can carry is allowed; a codec that would need a multipart
  upload rejects them.
  """

  @type modality :: :image | :video

  @type params :: %{
          optional(:n) => pos_integer() | nil,
          optional(:size) => String.t() | nil,
          optional(:aspect_ratio) => String.t() | nil,
          optional(:duration_s) => pos_integer() | nil,
          optional(:seed) => non_neg_integer() | nil,
          optional(:negative_prompt) => String.t() | nil
        }

  @type t :: %__MODULE__{
          modality: modality(),
          model: String.t(),
          prompt: String.t(),
          references: [LlmCall.Content.part()],
          params: params(),
          provider_options: map()
        }

  defstruct modality: nil,
            model: nil,
            prompt: nil,
            references: [],
            params: %{},
            provider_options: %{}
end

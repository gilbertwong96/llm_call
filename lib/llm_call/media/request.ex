defmodule LlmCall.Media.Request do
  @moduledoc """
  A provider-neutral image or video generation request.

  This is a separate request from `LlmCall.Request` on purpose: dedicated media
  endpoints take a prompt and media parameters, not messages, a system prompt, or
  tools. Flattening a completion request into `{prompt, n, size}` would be a hidden
  convention.

  `references` are images or videos the generation is conditioned on. An
  adapter may still refuse a source it cannot carry (a `{:base64, _}` image
  without a media type, a video reference to an image-only endpoint); those are
  validation errors, not silent drops.
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
          references: nil | [LlmCall.Content.Image.t() | LlmCall.Content.Video.t()],
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

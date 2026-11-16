defmodule LlmDialect.Media.Adapter do
  @moduledoc """
  `use` for a media adapter.

  Injects the behaviour, the canonical aliases, the codec's name and modality,
  and the shared validation pipeline. The codec supplies `validate_params/1`,
  `validate_references/1`, and `validate_provider_options/2`:

      use LlmDialect.Media.Adapter, codec: :openai_images, modality: :image
  """

  defmacro __using__(opts) do
    codec = Keyword.fetch!(opts, :codec)
    modality = Keyword.fetch!(opts, :modality)

    model_fun =
      Keyword.get(opts, :model_fun, quote(do: &LlmDialect.Protocol.Helpers.validate_model/2))

    quote do
      @behaviour LlmDialect.Media.Codec

      alias LlmDialect.{Codec, Config, Content, EncodedRequest, Error, Operation, Usage}
      alias LlmDialect.Media.{Capabilities, Request, Response}
      alias LlmDialect.Protocol.Helpers

      @codec unquote(codec)
      @modality unquote(modality)

      @impl true
      def validate_request(%Request{} = request, %Config{} = config) do
        Helpers.validate_media_request(
          request,
          config,
          @codec,
          @modality,
          unquote(model_fun),
          &validate_params/1,
          &validate_references/1,
          &validate_provider_options/2
        )
      end
    end
  end
end

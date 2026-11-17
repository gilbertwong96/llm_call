defmodule LlmDialect.Media.Adapter do
  @moduledoc """
  `use` for a media adapter.

  Injects the behaviour, the canonical aliases, the codec's name and modality,
  and the shared `validate_request/2` pipeline:

      use LlmDialect.Media.Adapter, codec: :openai_images, modality: :image

  The codec supplies `info/0`, `capabilities/0`, `encode_submit/2`,
  `decode_submit/2`, `validate_params/1`, `validate_references/1`, and
  `validate_provider_options/2`.

  `namespaces:` names the `provider_options` namespaces this codec reads. It is
  required: a namespace outside the list is a validation error, so a typo cannot
  silently drop the caller's options.

  `model_fun:` replaces the model check for protocols that constrain the model id
  itself (Gemini's predict path rejects bare ids containing `/` or `:`).
  """

  defmacro __using__(opts) do
    codec = Keyword.fetch!(opts, :codec)
    modality = Keyword.fetch!(opts, :modality)
    namespaces = Keyword.fetch!(opts, :namespaces)

    model_fun =
      Keyword.get(opts, :model_fun, quote(do: &LlmDialect.Protocol.Helpers.validate_model/2))

    quote do
      @behaviour LlmDialect.Media.Codec

      alias LlmDialect.{Codec, Config, Content, EncodedRequest, Error, Operation, Usage}
      alias LlmDialect.Media.{Capabilities, Request, Response}
      alias LlmDialect.Protocol.Helpers

      @codec unquote(codec)
      @modality unquote(modality)
      @namespaces unquote(namespaces)

      @doc """
      Runs the shared media validation pipeline with the codec's own checks.
      """
      @impl true
      @spec validate_request(Request.t(), Config.t()) :: :ok | {:error, Error.t()}
      def validate_request(%Request{} = request, %Config{} = config) do
        with :ok <-
               Helpers.validate_option_map(
                 request.provider_options,
                 @codec,
                 "provider_options",
                 @namespaces
               ),
             :ok <-
               Helpers.validate_option_map(
                 config.default_provider_options,
                 @codec,
                 "default_provider_options",
                 @namespaces
               ) do
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
end

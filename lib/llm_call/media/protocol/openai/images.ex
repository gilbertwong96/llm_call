defmodule LlmCall.Media.Protocol.OpenAI.Images do
  @moduledoc """
  OpenAI image generation (`POST /v1/images/generations`).

  Dedicated image endpoints take a prompt and media parameters, so this codec
  implements `LlmCall.MediaCodec` rather than the completion behaviour.

  `references` are rejected: image edits and variations require a multipart
  upload, which the transport owns. `response_format` is forced to `b64_json` so
  assets do not expire; `provider_options.openai` may override it.

  `sizes` declares the union across OpenAI image models. The core has no model
  catalog, so a size a specific model rejects surfaces as a provider error.
  """

  alias LlmCall.{
    Codec,
    Config,
    Content,
    EncodedRequest,
    Error,
    MediaCapabilities,
    MediaRequest,
    MediaResponse,
    Usage
  }

  alias LlmCall.Protocol.Helpers

  @behaviour LlmCall.MediaCodec

  @codec :openai_images
  @path "/v1/images/generations"
  @headers [{"content-type", "application/json"}]
  @reserved_keys ~w(model prompt instances parameters modality)
  @param_keys [:n, :size]
  @sizes [
    "256x256",
    "512x512",
    "1024x1024",
    "1792x1024",
    "1024x1792",
    "1536x1024",
    "1024x1536",
    "auto"
  ]
  @max_n 10
  @retryable_codes ~w(rate_limit_exceeded server_error timeout)

  @impl true
  @spec info() :: Codec.Info.t()
  def info do
    %Codec.Info{name: @codec, protocol: @codec, version: nil, ir_version: 1}
  end

  @impl true
  @spec capabilities(MediaRequest.t(), Config.t()) :: MediaCapabilities.t()
  def capabilities(%MediaRequest{}, %Config{}) do
    %MediaCapabilities{
      modalities: [:image],
      async: false,
      max_n: @max_n,
      sizes: @sizes,
      aspect_ratios: [],
      durations_s: [],
      references: false,
      seed: false,
      negative_prompt: false
    }
  end

  @impl true
  @spec validate_request(MediaRequest.t(), Config.t()) :: :ok | {:error, Error.t()}
  def validate_request(%MediaRequest{} = request, %Config{} = config) do
    with :ok <- validate_modality(request.modality),
         :ok <- validate_model(request.model),
         :ok <- validate_prompt(request.prompt),
         :ok <- validate_params(request.params),
         :ok <- validate_references(request.references),
         :ok <- validate_provider_options(request, config) do
      :ok
    end
  end

  @impl true
  @spec encode_submit(MediaRequest.t(), Config.t()) ::
          {:ok, EncodedRequest.t()} | {:error, Error.t()}
  def encode_submit(%MediaRequest{} = request, %Config{} = config) do
    with :ok <- validate_request(request, config) do
      body =
        %{"model" => request.model, "prompt" => request.prompt}
        |> put_response_format(request.model)
        |> Helpers.maybe_put("n", request.params[:n])
        |> Helpers.maybe_put("size", request.params[:size])
        |> Config.deep_merge(provider_options(request, config))

      {:ok,
       %EncodedRequest{
         method: :post,
         path: @path,
         query: %{},
         headers: @headers,
         body: body
       }}
    end
  end

  @impl true
  @spec decode_submit(LlmCall.wire_value(), Config.t()) ::
          {:ok, MediaResponse.t()} | {:error, Error.t()}
  def decode_submit(%{"data" => [_ | _] = items} = payload, %Config{} = config)
      when is_list(items) do
    with {:ok, assets, revised_prompts} <- decode_items(items) do
      {:ok,
       %MediaResponse{
         assets: assets,
         revised_prompt: Enum.find(revised_prompts, &is_binary/1),
         usage: decode_usage(payload["usage"]),
         operation: nil,
         raw: capture_response(config, payload)
       }}
    end
  end

  def decode_submit(_term, _config) do
    {:error, invalid_response("response has no image data")}
  end

  @impl true
  @spec decode_error(LlmCall.wire_value(), Config.t()) :: Error.t()
  def decode_error(%{"error" => %{"message" => message} = error} = payload, %Config{}) do
    code = error["code"] || error["type"]

    %Error{
      kind: :provider,
      message: message,
      code: code,
      status: nil,
      retryable?: code in @retryable_codes,
      raw: payload
    }
  end

  def decode_error(_term, _config) do
    %Error{
      kind: :invalid_response,
      message: "openai_images: unrecognized error payload",
      raw: nil
    }
  end

  defp decode_items(items) do
    case Enum.find(items, &(not valid_item?(&1))) do
      nil ->
        {:ok, Enum.map(items, &decode_asset/1), Enum.map(items, & &1["revised_prompt"])}

      _invalid ->
        {:error, invalid_response("image item has neither b64_json nor url")}
    end
  end

  defp valid_item?(%{"b64_json" => data}) when is_binary(data), do: true
  defp valid_item?(%{"url" => url}) when is_binary(url), do: true
  defp valid_item?(_item), do: false

  defp decode_asset(%{"b64_json" => data} = item) do
    %Content.Image{source: {:base64, data}, media_type: item["mime_type"] || "image/png"}
  end

  defp decode_asset(%{"url" => url}) when is_binary(url) do
    %Content.Image{source: {:url, url}, media_type: nil}
  end

  defp decode_usage(nil), do: nil

  defp decode_usage(%{} = usage) do
    %Usage{
      input_tokens: usage["input_tokens"],
      output_tokens: usage["output_tokens"],
      total_tokens: usage["total_tokens"],
      cache_read_tokens: nil,
      cache_write_tokens: nil,
      reasoning_tokens: nil
    }
  end

  defp decode_usage(_usage), do: nil

  defp validate_modality(:image), do: :ok

  defp validate_modality(modality) do
    Helpers.error(@codec, "modality must be :image, got: #{inspect(modality)}")
  end

  defp validate_model(model) when is_binary(model) and model != "", do: :ok
  defp validate_model(_model), do: Helpers.error(@codec, "model is required")

  defp validate_prompt(prompt) when is_binary(prompt) and prompt != "", do: :ok
  defp validate_prompt(_prompt), do: Helpers.error(@codec, "prompt is required")

  defp validate_params(params) when is_map(params) do
    present = for {key, value} <- params, not is_nil(value), do: key

    with :ok <-
           Helpers.first_error(present, fn key ->
             if key in @param_keys,
               do: :ok,
               else: Helpers.error(@codec, "params key #{inspect(key)} is not supported")
           end),
         :ok <- validate_n(params[:n]),
         :ok <- validate_size(params[:size]) do
      :ok
    end
  end

  defp validate_params(_params), do: Helpers.error(@codec, "params must be a map")

  defp validate_n(nil), do: :ok

  defp validate_n(n) when is_integer(n) and n > 0 and n <= @max_n, do: :ok

  defp validate_n(_n), do: Helpers.error(@codec, "params.n must be between 1 and #{@max_n}")

  defp validate_size(nil), do: :ok
  defp validate_size(size) when size in @sizes, do: :ok

  defp validate_size(_size),
    do: Helpers.error(@codec, "params.size must be one of #{inspect(@sizes)}")

  defp validate_references(nil), do: :ok
  defp validate_references([]), do: :ok

  defp validate_references(_references) do
    Helpers.error(@codec, "references require a multipart upload and are not supported")
  end

  defp validate_provider_options(request, config) do
    case provider_options(request, config) do
      options when is_map(options) ->
        Helpers.first_error(Map.keys(options), fn key ->
          if Helpers.reserved_key?(key, @reserved_keys) do
            Helpers.error(
              @codec,
              "provider option #{inspect(key)} would replace a canonical field"
            )
          else
            :ok
          end
        end)

      _options ->
        Helpers.error(@codec, "provider_options.openai must be a map")
    end
  end

  defp provider_options(request, config) do
    Config.provider_options(request, config) |> Map.get(:openai, %{})
  end

  # dall-e models accept response_format; gpt-image-1 does not and returns base64 anyway.
  defp put_response_format(body, "dall-e-" <> _model) do
    Map.put(body, "response_format", "b64_json")
  end

  defp put_response_format(body, _model), do: body

  defp capture_response(%Config{capture_raw: raw}, term) when raw in [:response, :all], do: term
  defp capture_response(_config, _term), do: nil

  defp invalid_response(message) do
    %Error{kind: :invalid_response, message: "openai_images: " <> message}
  end
end
